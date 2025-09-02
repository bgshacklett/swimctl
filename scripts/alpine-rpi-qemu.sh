#!/usr/bin/env bash
# alpine-rpi-qemu.sh — Alpine RPi in QEMU (DISKLESS, single FAT32 partition)
#
# Usage:
#   ./scripts/alpine-rpi-qemu.sh make-image    # create alpine-rpi.img (single FAT32)
#   ./scripts/alpine-rpi-qemu.sh populate      # fetch tarball, extract to p1, add DTB, write cmdline
#   ./scripts/alpine-rpi-qemu.sh launch        # boot QEMU into diskless Alpine (live/installer)
#   BOARD=pi3 ./scripts/alpine-rpi-qemu.sh all # do everything for Pi 3 model
#
# Inside the guest:
#   setup-alpine
#   lbu commit -d   # persist config to apkovl on p1
#
# Notes:
# - Diskless mode (RAM root). Single FAT32 partition, no root= on cmdline.
# - QEMU does not emulate Pi firmware, so we pass -kernel/-initrd/-dtb.

set -euo pipefail

# -------- Tunables --------
IMG="${IMG:-alpine-rpi.img}"
SIZE_GB="${SIZE_GB:-2}"              # Single FAT32 partition size
BOARD="${BOARD:-pi4}"                 # pi4 | pi3
ARCH="${ARCH:-aarch64}"
BRANCH="${BRANCH:-latest-stable}"     # latest-stable | edge
REPO_BASE="${REPO_BASE:-https://dl-cdn.alpinelinux.org/alpine}"

SSH_PORT="${SSH_PORT:-5022}"
RAM_MB="${RAM_MB:-2048}"
SMP="${SMP:-4}"
BOOT_LABEL="${BOOT_LABEL:-APLNBOOT}"

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
  local img="$1"; shift
  local loop base p1
  need mount; need umount
  loop="$(loop_map "$img")"
  base="$(basename "$loop")"
  p1="/dev/mapper/${base}p1"
  sudo mkdir -p /mnt/alpine-boot
  sudo mount "$p1" /mnt/alpine-boot
  LOOP_BASENAME="$base" "$@"
  local rc=$?
  sudo umount /mnt/alpine-boot || true
  loop_unmap "$loop"
  return $rc
}

fetch_atomically() { # fetch_atomically URL OUTFILE
  local url="$1" out="$2" tmp
  need wget
  tmp="$(mktemp "${out}.XXXXXX")"
  if ! wget -S --progress=dot:giga -O "$tmp" "$url"; then
    rm -f "$tmp"; echo "Download failed: $url"; return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"; echo "Empty download: $url"; return 1
  fi
  mv -f "$tmp" "$out"
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
# Usage:
#   populate_headless_config <IMG> \
#     [--overlay <path|url>] \
#     [--unattend <path>] \
#     [--auth-keys <path>] \
#     [--answers <path>] \
#     [--extra <path> ...]
#
# Notes:
# - If --overlay is omitted, downloads macmpi's headless.apkovl.tar.gz.
# - If --unattend is provided, it is copied to /unattended.sh and chmod +x.
# - If --auth-keys is provided, it is copied to /authorized_keys.
# - If --answers is provided, it is copied to /answers.txt.
# - You can repeat --extra to copy additional files to the boot root.
# - Requires helpers: need, with_p1, loop_map, loop_unmap (you already have).
_populate_headless_config() (
  local overlay_src="$1"
  local unattend_src="$2"
  local auth_keys_src="$3"
  local answers_src="$4"
  local -a extra_files=("$@")

  local boot="/mnt/alpine-boot"
  [[ -d "$boot" ]] || { echo "boot mountpoint missing: $boot" >&2; return 1; }

  echo "→ Populating $boot with unattended configuration"

  # 1) headless.apkovl.tar.gz
  if [[ "$overlay_src" =~ ^https?:// ]]; then
    echo "  - downloading overlay from URL"
    curl -L --fail --retry 3 -o "$boot/headless.apkovl.tar.gz" "$overlay_src"
  else
    echo "  - copying overlay from file"
    install -m 0644 "$overlay_src" "$boot/headless.apkovl.tar.gz"
  fi

  # 2) unattend.sh -> /unattended.sh (executable)
  if [[ -n "$unattend_src" ]]; then
    echo "  - installing unattended.sh"
    install -m 0755 "$unattend_src" "$boot/unattended.sh"
  fi

  # 3) authorized_keys (optional)
  if [[ -n "$auth_keys_src" ]]; then
    echo "  - installing authorized_keys"
    install -m 0644 "$auth_keys_src" "$boot/authorized_keys"
  fi

  # 4) answers.txt (optional)
  if [[ -n "$answers_src" ]]; then
    echo "  - installing answers.txt"
    install -m 0644 "$answers_src" "$boot/answers.txt"
  fi

  # 5) any extra files (optional)
  if [[ ${#extra_files[@]} -gt 0 ]]; then
    echo "  - copying extra file(s)"
    for f in "${extra_files[@]}"; do
      [[ -f "$f" ]] || { echo "    ! not a file: $f" >&2; continue; }
      echo "    · $(basename "$f")"
      install -m 0644 "$f" "$boot/$(basename "$f")"
    done
  fi

  sync
  echo "✓ Boot partition populated."
  echo "  Contents:"
  (cd "$boot" && ls -lah)
)


populate_headless_config() {
  need curl
  need install
  need awk
  need grep

  local overlay_src=       # file path or URL
  local unattend_src=      # file path
  local auth_keys_src=     # file path
  local answers_src=       # file path
  local -a extra_files=()  # array of paths to copy to / (boot root)

  local default_overlay_url="https://raw.githubusercontent.com/macmpi/alpine-linux-headless-bootstrap/refs/heads/main/headless.apkovl.tar.gz"

  # --- parse args ---
  if [[ $# -lt 1 ]]; then
    echo "Usage: populate_headless_boot <IMG> [--overlay <path|url>] [--unattend <path>] [--auth-keys <path>] [--answers <path>] [--extra <path> ...]" >&2
    return 2
  fi

  shift 1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --overlay) overlay_src="$2"; shift 2 ;;
      --unattend) unattend_src="$2}"; shift 2 ;;
      --auth-keys) auth_keys_src="$2"; shift 2 ;;
      --answers) answers_src="$2"; shift 2 ;;
      --extra) extra_files+=("$2"); shift 2 ;;
      --) shift; break ;;
      *) echo "populate_headless_config: unknown arg: $1" >&2; return 2 ;;
    esac
  done

  # mount p1, run the commands to populate the file system, unmount
  with_p1 "$IMG" _populate_headless_config \
    "${overlay_src:-"$default_overlay_url"}" \
    "${unattend_src:-"unattended.sh"}" \
    "${auth_keys_src:-"authorized_keys"}" \
    "${answers_src:-"answers.txt"}" \
    "${extra_files[@]}"
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


all() { make-image; populate; populate_headless_config "$@"; launch; }


case "${1:-help}" in
  make-image)                 make-image ;;
  populate-boot)              populate_boot ;;
  populate-headless-config)   populate_headless_config "$@" ;;
  verify)                     verify ;;
  launch)                     launch ;;
  all)                        all "$@" ;;

  # Provide help
  help|-h|--help)
    sed -n '1,200p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) echo "Unknown target: $1"; exit 2 ;;
esac
