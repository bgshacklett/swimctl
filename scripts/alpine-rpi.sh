#!/usr/bin/env bash
# alpine-rpi.sh — Alpine RPi in QEMU
#
# Usage:
#   ./scripts/alpine-rpi.sh make-image       # create alpine-rpi.img (single FAT32)
#   ./scripts/alpine-rpi.sh populate-boot    # fetch tarball, extract to p1, add DTB, write cmdline
#   ./scripts/alpine-rpi.sh populate-config  # add the headless alpine apkovl and all relevant configs
#   ./scripts/alpine-rpi.sh verify           #
#   ./scripts/alpine-rpi.sh launch           # boot QEMU into diskless Alpine (live/installer)
#   ./scripts/alpine-rpi.sh sdcard           #
#   ./scripts/alpine-rpi.sh clean            #
#
# Examples:
#   BOARD=pi3 ./scripts/alpine-rpi.sh all # do everything for Pi 3 model
#
# Notes:
# - QEMU does not emulate Pi firmware, so we pass -kernel/-initrd/-dtb.

set -euo pipefail

FETCH_CACHE_APP=swimctl-builder
export FETCH_CACHE_APP

# -------- Lock file --------
# Sourced before tunables so locked values become defaults that env vars can
# still override. Refresh via `./scripts/alpine-rpi.sh refresh-lock`.
LOCK_FILE="${LOCK_FILE:-etc/alpine.lock}"
if [[ -r "$LOCK_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$LOCK_FILE"
fi

# -------- Tunables --------
IMG="${IMG:-dist/alpine-rpi.img}"
IMG_MOUNT_PATH="${IMG_MOUNT_PATH:-/mnt/alpine-boot}"
SIZE_GB="${SIZE_GB:-2}"              # Single FAT32 partition size
BOARD="${BOARD:-pi3}"                 # pi4 | pi3
ARCH="${ARCH:-aarch64}"
BRANCH="${BRANCH:-${ALPINE_BRANCH:-latest-stable}}"  # env > lock > latest-stable
REPO_BASE="${REPO_BASE:-https://dl-cdn.alpinelinux.org/alpine}"

SSH_PORT="${SSH_PORT:-5022}"
# RAM_MB="${RAM_MB:-2048}"
SMP="${SMP:-4}"
BOOT_LABEL="${BOOT_LABEL:-APLNBOOT}"

OVERLAY_SRC="${OVERLAY_SRC:-"https://raw.githubusercontent.com/macmpi/alpine-linux-headless-bootstrap/refs/heads/main/headless.apkovl.tar.gz"}"
UNATTEND_SRC="${UNATTEND_SRC:-"etc/unattended.sh"}"
UNATTEND_LIB_SRC="${UNATTEND_LIB_SRC:-"etc/unattended.lib.sh"}"
PRE_NETWORK_SRC="${PRE_NETWORK_SRC:-"etc/pre-network.d/"}"
AUTH_KEYS_SRC="${AUTH_KEYS_SRC:-"etc/authorized_keys"}"
WPA_SUPPLICANT_SRC="${WPA_SUPPLICANT_SRC:-"etc/wpa_supplicant.conf"}"

WIFI_SSID=${WIFI_SSID:-""}
WIFI_PASSWORD=${WIFI_PASSWORD:-""}

typeset -a EXTRA_FILES
EXTRA_FILES=( ${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"} )

# TARGET controls which file variants are copied, and to what kind of media:
#   export TARGET=qemu  # for emulation (default)
#   export TARGET=rpi   # for real hardware
# Files are matched as: *.any.* and *.<TARGET>.*
TARGET="${TARGET:=qemu}"  # Assume qemu unless overridden


# -------- Board mapping --------
case "$BOARD" in
  pi4)
    DTB_FILE="${DTB_FILE:-bcm2711-rpi-4-b.dtb}"
    QEMU_MACHINE="raspi4b"
    QEMU_CPU="cortex-a72"
    RAM_MB="${RAM_MB:-2048}"
    EARLYCON="${EARLYCON:-earlycon=pl011,mmio32,0xfe201000 keep_bootcon}"
    ;;
  pi3)
    DTB_FILE="${DTB_FILE:-bcm2710-rpi-3-b-plus.dtb}"
    QEMU_MACHINE="raspi3b"
    QEMU_CPU="cortex-a53"
    RAM_MB="${RAM_MB:-1024}"
    EARLYCON="${EARLYCON:-earlycon=pl011,mmio32,0x3f201000 keep_bootcon}"
    ;;
  *) echo "Unsupported BOARD=$BOARD (use pi4 or pi3)"; exit 2;;
esac

REL_DIR="${REPO_BASE}/${BRANCH}/releases/${ARCH}/"
# raw.githubusercontent.com is deterministic per commit sha, so pinning the
# commit (via the lock file) is the integrity guarantee — no separate sha
# needed on the DTB itself.
DTB_URL_DEFAULT="https://raw.githubusercontent.com/raspberrypi/firmware/${RPI_FW_COMMIT:-master}/boot/${DTB_FILE}"

# -------- Helpers --------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1"; exit 1; }; }

loop_map() {
  local img="$1" loop
  need losetup; need partprobe; need kpartx
  loop="$(sudo losetup --find --show "$img")"
  sudo partprobe "$loop"
  sudo kpartx -av "$loop" >/dev/null
  echo "$loop"
}
loop_unmap() {
  local loop="$1"
  sudo kpartx -vd "$loop" >/dev/null
  sudo losetup -vd "$loop"
}


with_p1_qemu() { # with_p1_qemu IMG cmd...
  # Provides LOOP_MOUNT environment variable which can be used to find the
  # appropriate mount point dynamically, rather than assuming a specific path.
  local img="$1"; shift
  local loop base p1 mount_path
  need mount; need umount
  loop="$(loop_map "$img")"
  mount_path="${IMG_MOUNT_PATH:-"/mnt/alpine-boot"}"

  # shellcheck disable=SC2064
  trap "sudo umount -v $mount_path; loop_unmap $loop" EXIT

  base="$(basename "$loop")"
  p1="/dev/mapper/${base}p1"
  sudo mkdir -p "$mount_path"
  sudo mount "$p1" "$mount_path"
  LOOP_BASENAME="$base" LOOP_MOUNT="$mount_path" "$@"
  return $?
}

# SD card adapter (simple mount)
with_p1_sd() {
  local disk="$1"; shift
  # derive partitions safely
  local part1

  if [[ "$disk" =~ nvme ]]; then
    >&2 echo "Cowardly refusing to operate on NVME storage."; exit 1
  fi

  set -x

  if [[ "$disk" =~ (mmcblk|nvme) ]]; then
    part1="${disk}p1"; else part1="${disk}1"
  fi

  mkdir -vp /mnt/alpine-boot
  mount -t vfat "/dev/$part1" /mnt/alpine-boot
  trap 'sync; umount /mnt/alpine-boot' EXIT
  "$@"
  set +x
}


_verify_sha256() { # _verify_sha256 PATH EXPECTED_SHA256
  local path="$1" expected="$2" actual
  actual="$(sha256sum -- "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "sha256 mismatch for $path" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

fetch_atomically() { # fetch_atomically URL OUTFILE [EXPECTED_SHA256]
  local url="$1" out="$2" expected_sha="${3:-}"
  local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/${FETCH_CACHE_APP:-fetch-cache}"
  local key cache_path tmp tmp2

  need wget
  [[ -z "$expected_sha" ]] || need sha256sum

  mkdir -p "$cache_root" || { echo "Cannot create cache dir: $cache_root" >&2; return 1; }
  key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  cache_path="$cache_root/$key"

  # If cached and non-empty, verify (if requested) then copy out atomically.
  if [[ -s "$cache_path" ]]; then
    if [[ -n "$expected_sha" ]] && ! _verify_sha256 "$cache_path" "$expected_sha"; then
      # Cached copy is bad — drop it and fall through to re-download.
      echo "Cache poisoned for $url; refetching" >&2
      rm -f -- "$cache_path"
    else
      tmp2="$(mktemp "${out}.XXXXXX")" || return 1
      if ! cp -f -- "$cache_path" "$tmp2"; then
        rm -f -- "$tmp2"; echo "Cache copy failed: $url" >&2; return 1
      fi
      mv -f -- "$tmp2" "$out"
      return 0
    fi
  fi

  # Not cached (or empty) — fetch to a temp file.
  tmp="$(mktemp "${cache_path}.XXXXXX")" || return 1
  if ! wget -S --progress=dot:giga -O "$tmp" -- "$url"; then
    rm -f -- "$tmp"; echo "Download failed: $url" >&2; return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f -- "$tmp"; echo "Empty download: $url" >&2; return 1
  fi

  # Verify before promoting into the cache.
  if [[ -n "$expected_sha" ]] && ! _verify_sha256 "$tmp" "$expected_sha"; then
    rm -f -- "$tmp"; return 1
  fi

  # Try to install into cache atomically. If another process beat us, just use theirs.
  if mv -f -- "$tmp" "$cache_path"; then
    : # cached successfully
  else
    # Fallback: if move failed for some reason, just ensure we don't leak the temp
    rm -f -- "$tmp"
  fi

  # Write the final outfile atomically from the (now present) cache.
  if [[ ! -s "$cache_path" ]]; then
    echo "Cache missing after fetch: $url" >&2; return 1
  fi
  tmp2="$(mktemp "${out}.XXXXXX")" || return 1
  if ! cp -f -- "$cache_path" "$tmp2"; then
    rm -f -- "$tmp2"; echo "Cache copy failed: $url" >&2; return 1
  fi
  mv -f -- "$tmp2" "$out"
}

resolve_tarball_url() {
  # Prefer the locked tarball name; otherwise scrape the release index.
  if [[ -n "${ALPINE_TARBALL_NAME:-}" ]]; then
    echo "${REL_DIR}${ALPINE_TARBALL_NAME}"
    return 0
  fi
  need wget
  local idx url
  idx="$(wget -vO- "${REL_DIR}")" || return 1
  url="$(printf "%s\n" "$idx" | grep -Eo 'alpine-rpi-[^"]*-aarch64\.tar\.gz' | head -n1)"
  [[ -n "$url" ]] || { echo "Could not find alpine-rpi-*-aarch64.tar.gz in ${REL_DIR}"; return 1; }
  echo "${REL_DIR}${url}"
}


make_image() {
  need parted
  need mkfs.vfat
  need kpartx
  if [[ -e "$IMG" ]]; then echo "Image exists: $IMG"; return 0; fi
  echo ">> Creating ${SIZE_GB}G image with single FAT32 partition…"
  truncate -s "${SIZE_GB}G" "$IMG"
  parted -s "$IMG" mklabel msdos \
    mkpart primary fat32 1MiB 100% set 1 lba on
  local loop base p1
  loop="$(loop_map "$IMG")"; base="$(basename "$loop")"; p1="/dev/mapper/${base}p1"
  sudo mkfs.vfat -n "${BOOT_LABEL}" "$p1"
  loop_unmap "$loop"
  echo ">> Image prepared: $IMG"
}


# Options (via env):
#   TARBALL       : path to alpine RPi tarball
#   ADD_DTB       : "1" to fetch DTB (QEMU only), else empty
#   DTB_URL       : url to fetch DTB when ADD_DTB=1
#   DTB_FILE      : destination path (relative to /mnt/alpine-boot) for DTB
#   CMDLINE       : full contents for cmdline.txt
#   CONFIG_TXT    : full contents for config.txt
_populate_boot_common() (
  set -o pipefail
  : "${TARBALL:?TARBALL required}"
  cd /mnt/alpine-boot
  tar -xpf "$TARBALL"

  for f in boot/vmlinuz-rpi boot/initramfs-rpi boot/modloop-rpi; do
    [[ -s "$f" ]] || { echo "Missing or empty after extract: $f"; exit 3; }
  done

  if [[ "${ADD_DTB:-}" == "1" ]]; then
    : "${DTB_URL:?}"; : "${DTB_FILE:?}"
    echo "DTB: $DTB_URL"
    fetch_atomically "$DTB_URL" "$DTB_FILE"
    [[ -s "$DTB_FILE" ]] || { echo "Failed to fetch DTB"; exit 4; }
  fi

  printf '%s\n' "${CONFIG_TXT:-[all]
arm_64bit=1
initramfs boot/initramfs-rpi followkernel}" > config.txt

  printf '%s\n' "${CMDLINE:-rw rootwait modules=loop,squashfs,sd-mod,usb-storage console=tty1}" > cmdline.txt

  sync
  echo "✓ Boot partition populated."
)


mk_config_txt() {
  cat <<'CFG'
[all]
arm_64bit=1
initramfs boot/initramfs-rpi followkernel
CFG
}

mk_cmdline_qemu() {
  echo 'rw rootwait modules=loop,squashfs,sd-mod,usb-storage console=ttyAMA1,115200'
}

mk_cmdline_rpi() {
  # serial-only headless + apkovl
  echo 'rw rootwait modules=loop,squashfs,sd-mod,usb-storage console=serial0,115200 apkovl=headless.apkovl.tar.gz'
}


populate_boot_qemu() {
  need tar
  local url tmp
  url="$(resolve_tarball_url)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  TARBALL="$tmp/alpine-rpi.tar.gz"
  fetch_atomically "$url" "$TARBALL" "${ALPINE_TARBALL_SHA256:-}"

  CONFIG_TXT="$(mk_config_txt)"
  CMDLINE="$(mk_cmdline_qemu)"
  ADD_DTB=1
  DTB_URL="${DTB_URL_DEFAULT:?}"
  DTB_FILE="boot/qemu-rpi4.dtb"

  with_p1_qemu "$IMG" _populate_boot_common
}


populate_boot_sd() {
  need tar
  local url tmp
  url="$(resolve_tarball_url)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  TARBALL="$tmp/alpine-rpi.tar.gz"
  fetch_atomically "$url" "$TARBALL" "${ALPINE_TARBALL_SHA256:-}"

  CONFIG_TXT="$(mk_config_txt)"
  CMDLINE="$(mk_cmdline_rpi)"
  ADD_DTB=              # <- do NOT add a QEMU DTB on real hardware

  if [ -z "${SD_DEV:-}" ]; then >&2 echo "SD_DEV must be set."; exit 1; fi
  >&2 echo "Running populate_boot_sd against $SD_DEV..."
  with_p1_sd "$SD_DEV" _populate_boot_common
}


_populate_config_common() (
  local target="$1"
  local overlay_src="$2"
  local unattend_src="$3"
  local unattend_lib_src="$4"
  local pre_network_src="$5"
  local auth_keys_src="$6"
  local answers_src="$7"
  local wpa_supplicant_src="$8"
  local -a extra_files=("${@:9}")

  local boot="/mnt/alpine-boot"
  [[ -d "$boot" ]] || { echo "boot mountpoint missing: $boot" >&2; return 1; }

  : "${target:=rpi}"
  echo "→ Populating $boot with unattended configuration (target=$target)"

  # 1) headless.apkovl.tar.gz
  if [[ "$overlay_src" =~ ^https?:// ]]; then
    echo "- downloading overlay from URL"
    fetch_atomically "$overlay_src" "$boot/headless.apkovl.tar.gz"
  else
    echo "- copying overlay from file"
    install -vm 0644 "$overlay_src" "$boot/headless.apkovl.tar.gz"
  fi

  # 2) pre-network hooks
  echo "- copying pre-network hooks..."
  mkdir -p "$boot/pre-network.d"
  find "$pre_network_src" -type f \
    \( -name '*.any.sh' -o -name "*.${target}.sh" \) \
    -exec install -vm 0755 {} "$boot/pre-network.d/" \;

  # 3) /unattended.sh and library
  if [[ -n "$unattend_src" ]]; then
    echo "- installing unattended.sh"
    install -vm 0755 "$unattend_src" "$boot/unattended.sh"
  fi
  if [[ -n "$unattend_lib_src" ]]; then
    echo "- installing $(basename "$unattend_lib_src")"
    install -vm 0755 "$unattend_lib_src" "$boot/unattended.lib.sh"
  fi

  # 4) authorized_keys (optional)
  if [[ -n "$auth_keys_src" ]]; then
    echo "- installing authorized_keys"
    install -vm 0644 "$auth_keys_src" "$boot/authorized_keys"
  fi

  # 5) answers.txt (optional)
  if [[ -n "$answers_src" ]]; then
    if [[ ! -f "$answers_src" ]]; then
      echo "Missing $answers_src — run: make init-config" >&2
      return 1
    fi
    echo "- installing answers.txt"
    install -vm 0644 "$answers_src" "$boot/answers.txt"
  fi

  # 6) wpa_supplicant.conf (optional)
  if [[ -n "$wpa_supplicant_src" ]]; then
    echo "- installing $(basename "$wpa_supplicant_src")"
    install -vm 0600 "$wpa_supplicant_src" "$boot/wpa_supplicant.conf"
  fi

  # 7) unattended.conf.d and unattended.exec.d
  echo "- copying unattended config files..."
  mkdir -p "$boot/unattended.conf.d"
  find "etc/unattended.conf.d" -type f \
    \( -name '*.any.conf' -o -name "*.${target}.conf" \) \
    -exec install -vm 0600 {} "$boot/unattended.conf.d/" \;

  echo "- copying unattended script parts..."
  mkdir -p "$boot/unattended.exec.d"
  find "etc/unattended.exec.d" -type f \
    \( -name '*.any.sh' -o -name "*.${target}.sh" \) \
    -exec install -vm 0755 {} "$boot/unattended.exec.d/" \;

  # 8) any extra files (optional)
  if [[ ${#extra_files[@]} -gt 0 ]]; then
    echo "- copying extra file(s)"
    for f in "${extra_files[@]}"; do
      [[ -f "$f" ]] || { echo "    ! not a file: $f" >&2; continue; }
      echo "    · $(basename "$f")"
      install -vm 0644 "$f" "$boot/$(basename "$f")"
    done
  fi

  # 9) Place _tst_version opt-out file.
  touch "$boot/opt-out"

  sync
  echo "✓ Boot partition populated."
  echo "  Contents:"
  (cd "$boot" && ls -lahR)
)


setup_wifi_config() {
  if [ -z "$WIFI_SSID" ]; then
    [ -t 0 ] || { >&2 echo "WIFI_SSID required (no tty for interactive prompt)"; exit 1; }
    read -rp "Enter WiFi SSID:" WIFI_SSID
  fi
  if [ -z "$WIFI_PASSWORD" ]; then
    [ -t 0 ] || { >&2 echo "WIFI_PASSWORD required (no tty for interactive prompt)"; exit 1; }
    read -rp "Enter WiFi Password:" WIFI_PASSWORD
  fi

  if [[ ${#WIFI_PASSWORD} -lt 8 ]]; then
    echo "WIFI Password must be at least 8 characters long."
    exit 1
  fi

  export WIFI_SSID WIFI_PASSWORD
  envsubst < ./extras/wpa_supplicant.conf.example > ./etc/wpa_supplicant.conf
}


populate_config_qemu() {
  setup_wifi_config

  config_spec=(
    "qemu"  # TARGET
    "$OVERLAY_SRC"
    "$UNATTEND_SRC"
    "$UNATTEND_LIB_SRC"
    "$PRE_NETWORK_SRC"
    "$AUTH_KEYS_SRC"
    "${ANSWERS_SRC:-"etc/answers-qemu.txt"}"
    "$WPA_SUPPLICANT_SRC"
    "${EXTRA_FILES[@]}"
  )

  with_p1_qemu "$IMG" _populate_config_common "${config_spec[@]}"
}

populate_config_sd() {
  setup_wifi_config

  config_spec=(
    "rpi"  # TARGET
    "$OVERLAY_SRC"
    "$UNATTEND_SRC"
    "$UNATTEND_LIB_SRC"
    "$PRE_NETWORK_SRC"
    "$AUTH_KEYS_SRC"
    "${ANSWERS_SRC:-"etc/answers.txt"}"
    "$WPA_SUPPLICANT_SRC"
    "${EXTRA_FILES[@]}"
  )

  if [ -z "${SD_DEV:-}" ]; then >&2 echo "SD_DEV must be set."; exit 1; fi
  >&2 echo "Running populate_config_sd against $SD_DEV..."
  with_p1_sd "$SD_DEV" _populate_config_common "${config_spec[@]}"
}


_verify() (
  cd /mnt/alpine-boot
  for f in boot/vmlinuz-rpi boot/initramfs-rpi boot/modloop-rpi "$DTB_FILE"; do
    [[ -s "$f" ]] || { echo "Missing or empty: $f"; exit 3; }
  done
  echo "cmdline:"
  sed -n "1p" cmdline.txt || true
)

verify() {
  >&2 echo
  >&2 echo "Verifying image layout..."
  with_p1_qemu "$IMG" _verify
}


_copy_launch_files() (
  local TMP="$1"
  local DTB_FILE="$2"

  cp /mnt/alpine-boot/boot/vmlinuz-rpi "$TMP/kernel"
  cp /mnt/alpine-boot/boot/initramfs-rpi "$TMP/initrd"
  cp "/mnt/alpine-boot/$DTB_FILE" "$TMP/dtb"
  tr "\n" " " < /mnt/alpine-boot/cmdline.txt > "$TMP/cmdline"
)
launch() {
  need qemu-system-aarch64
  need kpartx
  verify

  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  with_p1_qemu "$IMG" _copy_launch_files "$TMP" "$DTB_FILE"
  CMDLINE="$(cat "$TMP/cmdline")"

  echo ">> Booting Alpine in Install mode. SSH forward: localhost:${SSH_PORT} -> guest:22"
  echo ">> Quit QEMU: Ctrl-a then x"

  exec qemu-system-aarch64 \
    -machine "$QEMU_MACHINE" \
    -cpu "$QEMU_CPU" \
    -smp "$SMP" -m "$RAM_MB" \
    -kernel "$TMP/kernel" \
    -initrd "$TMP/initrd" \
    -dtb "$TMP/dtb" \
    -drive "if=sd,file=$IMG,index=0,cache=directsync" \
    -append "$CMDLINE" \
    -usb \
    -device "usb-net,netdev=net0" \
    -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22" \
    -serial  mon:stdio \
    -display none \
    -no-reboot
}


sdcard() {
  # TODO: Implement
  :
}


clean() {
  rm -vrf ./dist/*
  echo "...done"
}


# init-config: scaffold a fresh checkout's etc/ tree from the extras/
# templates. Idempotent — existing files are never overwritten, so it's safe
# to re-run after editing.
init_config() {
  local -a pairs=(
    "extras/answers.txt.example|etc/answers.txt"
    "extras/answers.txt.example|etc/answers-qemu.txt"
    "extras/alpine-setup.any.conf.example|etc/unattended.conf.d/alpine-setup.any.conf"
  )

  local pair src dst
  local installed=0 kept=0
  for pair in "${pairs[@]}"; do
    src="${pair%%|*}"
    dst="${pair##*|}"
    if [[ ! -f "$src" ]]; then
      echo "! template missing: $src (skipping)" >&2
      continue
    fi
    if [[ -e "$dst" ]]; then
      echo "= keep:    $dst"
      kept=$((kept + 1))
    else
      mkdir -p "$(dirname "$dst")"
      install -m 0644 "$src" "$dst"
      echo "+ install: $dst (from $src)"
      installed=$((installed + 1))
    fi
  done

  echo
  echo "init-config: $installed installed, $kept kept (existing untouched)"
  echo "Edit etc/answers*.txt and etc/unattended.conf.d/*.conf for your deployment."
}


refresh_lock() {
  need curl

  # Each curl response is buffered into a variable, then parsed with a single
  # awk pass that uses `exit` after the first match. Multi-stage pipes with
  # `head -n1` / `grep -m1` cause SIGPIPE-on-pipefail failures (exit 23/141)
  # depending on relative timing.

  # Always start from latest-stable so refresh-lock pulls forward, regardless
  # of what the existing lock pinned to.
  local rel_dir index_html tarball_name
  rel_dir="${REPO_BASE}/latest-stable/releases/${ARCH}/"
  echo ">> Querying release index: $rel_dir"
  index_html="$(curl -fsSL "$rel_dir")"
  tarball_name="$(awk 'match($0, /alpine-rpi-[^"]*-aarch64\.tar\.gz/) {
    print substr($0, RSTART, RLENGTH); exit
  }' <<< "$index_html")"
  [[ -n "$tarball_name" ]] || { echo "Could not find alpine-rpi-*-aarch64.tar.gz"; exit 1; }

  # Derive vMAJOR.MINOR branch from the tarball version so future runs target
  # the same series even when latest-stable advances.
  local version v_branch
  version="$(echo "$tarball_name" \
    | sed -E 's/^alpine-rpi-([0-9]+\.[0-9]+)\.[0-9]+.*$/\1/')"
  v_branch="v${version}"

  local sha_url sha_body tarball_sha
  sha_url="${rel_dir}${tarball_name}.sha256"
  echo ">> Fetching sha256 sidecar: $sha_url"
  sha_body="$(curl -fsSL "$sha_url")"
  tarball_sha="$(awk '{print $1; exit}' <<< "$sha_body")"
  [[ ${#tarball_sha} -eq 64 ]] || { echo "Invalid sha256 from $sha_url: $tarball_sha"; exit 1; }

  echo ">> Resolving raspberrypi/firmware master HEAD"
  local fw_response fw_commit
  fw_response="$(curl -fsSL "https://api.github.com/repos/raspberrypi/firmware/commits/master")"
  fw_commit="$(awk 'match($0, /"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]+"/) {
    # Split the matched substring "sha": "<HASH>" on the quote char.
    # Fields end up as: ["", "sha", ": ", "<HASH>", ""]
    line = substr($0, RSTART, RLENGTH);
    split(line, parts, "\"");
    print parts[4]; exit
  }' <<< "$fw_response")"
  [[ ${#fw_commit} -eq 40 ]] || { echo "Could not resolve firmware commit: $fw_commit"; exit 1; }

  local lock="${LOCK_FILE:-etc/alpine.lock}"
  cat > "$lock" <<EOF
# etc/alpine.lock — pinned Alpine RPi build inputs.
# Generated by: ./scripts/alpine-rpi.sh refresh-lock
# Regenerate to pull in newer Alpine releases or firmware.

ALPINE_BRANCH=${v_branch}
ALPINE_TARBALL_NAME=${tarball_name}
ALPINE_TARBALL_SHA256=${tarball_sha}

# raspberrypi/firmware is fetched via raw.githubusercontent.com, which is
# byte-deterministic per commit sha — the commit itself is the integrity
# guarantee, so no separate sha256 is recorded for the DTB.
RPI_FW_COMMIT=${fw_commit}
EOF
  echo ">> Wrote $lock:"
  cat "$lock"
}


_check_files_exist() {
  status=0

  for file in "$@"; do
    if [[ ! -e "$file" ]]; then
      echo "❌ Missing: $file"
      status=1
    elif [[ ! -s "$file" ]]; then
      echo "❌ Empty: $file"
      status=1
    else
      echo "✅ $file"
    fi
  done

  return "$status"
}

_test_qemu() (
  pushd "${LOOP_MOUNT}" > /dev/null

  _check_files_exist \
    wpa_supplicant.conf

  ls -alhR

  popd > /dev/null
)
test_qemu() {
  with_p1_qemu "$IMG" _test_qemu
}


# Main entry point
case "${1:-help}" in
  make-image)             make_image ;;
  populate-boot-qemu)     populate_boot_qemu ;;
  populate-config-qemu)   populate_config_qemu ;;
  populate-boot-sd)       populate_boot_sd ;;
  populate-config-sd)     populate_config_sd ;;
  verify)                 verify ;;
  launch)                 launch ;;
  test)                   test_qemu ;;
  sdcard)                 sdcard ;;
  refresh-lock)           refresh_lock ;;
  init-config)            init_config ;;
  clean)                  clean ;;

  # Provide help
  help|-h|--help)
    sed -n '1,200p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) echo "Unknown target: $1"; exit 2 ;;
esac
