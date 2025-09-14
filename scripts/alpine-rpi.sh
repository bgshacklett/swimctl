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

# -------- Tunables --------
IMG="${IMG:-dist/alpine-rpi.img}"
IMG_MOUNT_PATH="${IMG_MOUNT_PATH:-/mnt/alpine-boot}"
SIZE_GB="${SIZE_GB:-2}"              # Single FAT32 partition size
BOARD="${BOARD:-pi4}"                 # pi4 | pi3
ARCH="${ARCH:-aarch64}"
BRANCH="${BRANCH:-latest-stable}"     # latest-stable | edge
REPO_BASE="${REPO_BASE:-https://dl-cdn.alpinelinux.org/alpine}"

SSH_PORT="${SSH_PORT:-5022}"
RAM_MB="${RAM_MB:-2048}"
SMP="${SMP:-4}"
BOOT_LABEL="${BOOT_LABEL:-APLNBOOT}"

OVERLAY_SRC="${OVERLAY_SRC:-"https://raw.githubusercontent.com/macmpi/alpine-linux-headless-bootstrap/refs/heads/main/headless.apkovl.tar.gz"}"
UNATTEND_SRC="${UNATTEND_SRC:-"etc/unattended.sh"}"
UNATTEND_LIB_SRC="${UNATTEND_LIB_SRC:-"etc/unattended.lib.sh"}"
AUTH_KEYS_SRC="${AUTH_KEYS_SRC:-"etc/authorized_keys"}"
ANSWERS_SRC="${ANSWERS_SRC:-"etc/answers.txt"}"
WPA_SUPPLICANT_SRC="${WPA_SUPPLICANT_SRC:-"etc/wpa_supplicant.conf"}"

typeset -a EXTRA_FILES
EXTRA_FILES=( "${EXTRA_FILES[@]:-()}" )


# Pull from ENV or set to empty string
WIFI_SSID=${WIFI_SSID:-""}
WIFI_PASSWORD=${WIFI_PASSWORD:-""}

# -------- Board mapping --------
case "$BOARD" in
  pi4)
    DTB_FILE="${DTB_FILE:-bcm2711-rpi-4-b.dtb}"
    QEMU_MACHINE="raspi4b"
    QEMU_CPU="cortex-a72"
    EARLYCON="${EARLYCON:-earlycon=pl011,mmio32,0xfe201000 keep_bootcon}"
    ;;
  pi3)
    DTB_FILE="${DTB_FILE:-bcm2710-rpi-3-b-plus.dtb}"
    QEMU_MACHINE="raspi3b"
    QEMU_CPU="cortex-a53"
    EARLYCON="${EARLYCON:-earlycon=pl011,mmio32,0x3f201000 keep_bootcon}"
    ;;
  *) echo "Unsupported BOARD=$BOARD (use pi4 or pi3)"; exit 2;;
esac

REL_DIR="${REPO_BASE}/${BRANCH}/releases/${ARCH}/"
DTB_URL_DEFAULT="https://raw.githubusercontent.com/raspberrypi/firmware/master/boot/${DTB_FILE}"

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
  sudo kpartx -dv "$loop" >/dev/null
  sudo losetup -d "$loop"
}

with_p1() { # with_p1 IMG cmd...
  # Provides LOOP_MOUNT environment variable which can be used to find the
  # appropriate mount point dynamically, rather than assuming a specific path.
  local img="$1"; shift
  local loop base p1 mount_path
  need mount; need umount
  loop="$(loop_map "$img")"
  base="$(basename "$loop")"
  p1="/dev/mapper/${base}p1"
  mount_path="${IMG_MOUNT_PATH:-"/mnt/alpine-boot"}"
  sudo mkdir -p "$mount_path"
  sudo mount "$p1" "$mount_path"
  LOOP_BASENAME="$base" LOOP_MOUNT="$mount_path" "$@"
  local rc=$?
  sudo umount "$mount_path" || true
  loop_unmap "$loop"
  return $rc
}

fetch_atomically() { # fetch_atomically URL OUTFILE
  local url="$1" out="$2"
  local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/${FETCH_CACHE_APP:-fetch-cache}"
  local key cache_path tmp tmp2

  need wget

  mkdir -p "$cache_root" || { echo "Cannot create cache dir: $cache_root" >&2; return 1; }
  key="$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
  cache_path="$cache_root/$key"

  # If cached and non-empty, copy it out atomically.
  if [[ -s "$cache_path" ]]; then
    tmp2="$(mktemp "${out}.XXXXXX")" || return 1
    if ! cp -f -- "$cache_path" "$tmp2"; then
      rm -f -- "$tmp2"; echo "Cache copy failed: $url" >&2; return 1
    fi
    mv -f -- "$tmp2" "$out"
    return 0
  fi

  # Not cached (or empty) — fetch to a temp file.
  tmp="$(mktemp "${cache_path}.XXXXXX")" || return 1
  if ! wget -S --progress=dot:giga -O "$tmp" -- "$url"; then
    rm -f -- "$tmp"; echo "Download failed: $url" >&2; return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f -- "$tmp"; echo "Empty download: $url" >&2; return 1
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
  # Find alpine-rpi-*-aarch64.tar.gz in the release directory index
  need wget
  local idx url
  idx="$(wget -qO- "${REL_DIR}")" || return 1
  url="$(printf "%s\n" "$idx" | grep -Eo 'alpine-rpi-[^"]*-aarch64\.tar\.gz' | head -n1)"
  [[ -n "$url" ]] || { echo "Could not find alpine-rpi-*-aarch64.tar.gz in ${REL_DIR}"; return 1; }
  echo "${REL_DIR}${url}"
}


make-image() {
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


_populate_boot() (
  set -o pipefail
  cd /mnt/alpine-boot
  tar -xpf "$TARBALL"

  # Sanity: these should now exist on p1 for diskless boot
  for f in boot/vmlinuz-rpi boot/initramfs-rpi boot/modloop-rpi; do
    [[ -s "$f" ]] || { echo "Missing or empty after extract: $f"; exit 3; }
  done

  # Add DTB matching QEMU raspi board
  DTB_URL="${DTB_URL_DEFAULT}"
  echo "DTB: $DTB_URL"
  wget -S --progress=dot:giga -O "$DTB_FILE" "$DTB_URL"
  [[ -s "$DTB_FILE" ]] || { echo "Failed to fetch DTB"; exit 4; }

  # Minimal config.txt (ignored by QEMU; useful on real HW)
  printf "[all]\narm_64bit=1\n" > config.txt

  # Diskless cmdline (NO root=). Force boot media to p1; DHCP; repo + modloop.
  cat > cmdline.txt <<CMD
rw earlyprintk loglevel=8 console=ttyAMA1,115200 panic=1 debug "${EARLYCON}"
CMD
)
populate_boot() {
  need wget
  need tar
  need kpartx
  echo ">> Resolving latest Alpine RPi tarball for ${BRANCH}/${ARCH}…"
  TARBALL_URL="$(resolve_tarball_url)"
  echo "TARBALL: ${TARBALL_URL}"

  echo ">> Downloading tarball…"
  TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
  TARBALL="${TMPDIR}/alpine-rpi.tar.gz"
  fetch_atomically "${TARBALL_URL}" "${TARBALL}"

  echo ">> Populating FAT partition from tarball…"
  with_p1 "$IMG" _populate_boot
  echo ">> Boot partition populated."
}


# Populate the Alpine Pi headless installer files on the boot (FAT) partition.
# Uses: with_p1 IMG cmd...
#
# Notes:
# - If --overlay is omitted, downloads macmpi's headless.apkovl.tar.gz.
# - If --unattend is provided, it is copied to /unattended.sh and chmod +x.
# - If --auth-keys is provided, it is copied to /authorized_keys.
# - If --answers is provided, it is copied to /answers.txt.
# - You can repeat --extra to copy additional files to the boot root.
# - Requires helpers: need, with_p1, loop_map, loop_unmap (you already have).
_populate_config() (
  local overlay_src="$1"
  local unattend_src="$2"
  local unattend_lib_src="$3"
  local auth_keys_src="$4"
  local answers_src="$5"
  local wpa_supplicant_src="$6"
  local -a extra_files=("$@")

  local boot="/mnt/alpine-boot"
  [[ -d "$boot" ]] || { echo "boot mountpoint missing: $boot" >&2; return 1; }

  echo "→ Populating $boot with unattended configuration"

  # 1) headless.apkovl.tar.gz
  if [[ "$overlay_src" =~ ^https?:// ]]; then
    echo "- downloading overlay from URL"
    # curl -L --fail --retry 3 -o "$boot/headless.apkovl.tar.gz" "$overlay_src"
    fetch_atomically "$overlay_src" "$boot/headless.apkovl.tar.gz"

  else
    echo "- copying overlay from file"
    install -vm 0644 "$overlay_src" "$boot/headless.apkovl.tar.gz"
  fi

  # 2) unattend.sh -> /unattended.sh (executable)
  if [[ -n "$unattend_src" ]]; then
    echo "- installing unattended.sh"
    install -vm 0755 "$unattend_src" "$boot/unattended.sh"
  fi
  if [[ -n "$unattend_lib_src" ]]; then
    echo "- installing $unattend_lib_src"
    install -vm 0755 "$unattend_lib_src" "$boot/unattended.lib.sh"
  fi

  # 3) authorized_keys (optional)
  if [[ -n "$auth_keys_src" ]]; then
    echo "- installing authorized_keys"
    install -vm 0644 "$auth_keys_src" "$boot/authorized_keys"
  fi

  # 4) answers.txt (optional)
  if [[ -n "$answers_src" ]]; then
    echo "- installing answers.txt"
    install -vm 0644 "$answers_src" "$boot/answers.txt"
  fi

  # 4) answers.txt (optional)
  if [[ -n "$wpa_supplicant_src" ]]; then
    echo "- installing $wpa_supplicant_src"
    install -vm 0600 "$wpa_supplicant_src" "$boot/wpa_supplicant.conf"
  fi

  # 5) *.conf.d and *.exec.d directories
  echo "- copying unattended config files..."
  mkdir -p "$boot/unattended.conf.d"
  find "etc/unattended.conf.d" \
    -type f \
    \( -name '*.any.conf' -o -name '*.qemu.conf' \) \
    -exec install -vm 0600 {} "$boot/unattended.conf.d/" \;

  echo "- copying unattended script parts..."
  mkdir -p "$boot/unattended.exec.d"
  find "etc/unattended.exec.d" \
    -type f \
    \( -name '*.any.sh' -o -name '*.qemu.sh' \) \
    -exec install -vm 0755 {} "$boot/unattended.exec.d/" \;

  # 6) any extra files (optional)
  if [[ ${#extra_files[@]} -gt 0 ]]; then
    echo "- copying extra file(s)"
    for f in "${extra_files[@]}"; do
      [[ -f "$f" ]] || { echo "    ! not a file: $f" >&2; continue; }
      echo "    · $(basename "$f")"
      install -m 0644 "$f" "$boot/$(basename "$f")"
    done
  fi

  sync
  echo "✓ Boot partition populated."
  echo "  Contents:"
  (cd "$boot" && ls -lahR)
)
populate_config() {
  need curl
  need install
  need awk
  need grep
  need losetup

  if [ -z "$WIFI_SSID" ]; then read -p "Enter WiFi SSID:" WIFI_SSID; fi
  if [ -z "$WIFI_PASSWORD" ]; then read -p "Enter WiFi Password:" WIFI_PASSWORD; fi

  export WIFI_SSID WIFI_PASSWORD
  envsubst < ./extras/wpa_supplicant.conf.example > ./etc/wpa_supplicant.conf

  # Mount p1, run the commands to populate the file system, unmount
  with_p1 "$IMG" _populate_config \
    "$OVERLAY_SRC" \
    "$UNATTEND_SRC" \
    "$UNATTEND_LIB_SRC" \
    "$AUTH_KEYS_SRC" \
    "$ANSWERS_SRC" \
    "$WPA_SUPPLICANT_SRC" \
    "${EXTRA_FILES[@]}"
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
  with_p1 "$IMG" _verify
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
  with_p1 "$IMG" _copy_launch_files "$TMP" "$DTB_FILE"
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
    -drive "if=sd,file=$IMG,index=0,format=raw" \
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
  # TODO: Implement
  with_p1 "$IMG" _test_qemu
}


# Main entry point
case "${1:-help}" in
  make-image)        make-image ;;
  populate-boot)     populate_boot ;;
  populate-config)   populate_config ;;
  verify)            verify ;;
  launch)            launch ;;
  test)              test_qemu ;;
  sdcard)            sdcard ;;
  clean)             clean ;;

  # Provide help
  help|-h|--help)
    sed -n '1,200p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) echo "Unknown target: $1"; exit 2 ;;
esac
