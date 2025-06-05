#!/usr/bin/env bash
# prep-alpine-headless.sh — helper to customise a freshly‑flashed Alpine SD card
# for head‑less Raspberry Pi boot using macmpi/alpine-linux-headless-bootstrap.
#
#  ➤ Downloads **latest** headless‑*.apkovl.tar.gz asset (any architecture)
#  ➤ Prompts for Wi‑Fi creds → writes wpa_supplicant.conf (hashed PSK when given)
#  ➤ Lets you **pick** which ~/.ssh/*.pub keys populate authorized_keys
#  ➤ Drops unattended.sh that, on first boot:
#       – Enables I²C (usercfg + modules‑load)
#       – Adds cgroup v1 memory flags to cmdline.txt
#       – Optionally converts /dev/sda to “data” mode and sets K3S_DATA_DIR
#       – Shreds Wi‑Fi file & removes itself, then reboots
#
# Usage:
#   ./prep-alpine-headless.sh /path/to/BOOT  # or already‑mounted BOOT dir
set -euo pipefail
shopt -s nullglob


###############################################################################
# Utility functions
###############################################################################
die() {
  echo "❌  $*" >&2
  exit 1
}


###############################################################################
# Print usage instructions
###############################################################################
usage() {
  echo "Usage: $0 -b /path/to/BOOT"
}


###############################################################################
# Locate the BOOT (FAT) partition
###############################################################################
locate_boot() {
  ARG=${1:-}
  if [[ -d $ARG ]]; then  # user passed a mount‑path
    BOOT_MNT=$ARG
  else
    die "Argument must be block device or mounted BOOT directory"
  fi

  echo "► Using BOOT at: $BOOT_MNT"
}


###############################################################################
# Download headless.apkovl.tar.gz (3‑stage fallback)
###############################################################################
download_headless_bootstrap() {
  DEST="$BOOT_MNT/headless.apkovl.tar.gz"

  echo "► Downloading headless.apkovl.tar.gz …"

  command -v jq >/dev/null 2>&1 || die "jq required (apk/apt/brew install jq)"
  API_URL=$(
    curl -fsSL 'https://api.github.com/repos/macmpi/alpine-linux-headless-bootstrap/releases/latest' \
    | jq -r '.body' \
    | grep -oP '(?<=\]\().*?(?=\))' \
    | sed 's|/blob/|/raw/|'
  )

  [[ -n $API_URL ]] && curl -fsSL -L "$API_URL" -o "$DEST"
  [[ -f "$DEST" ]] || die "Download of headless.apkovl.tar.gz failed."
}


###############################################################################
# Build wpa_supplicant.conf (optional)
###############################################################################
setup_wpa_supplicant() {
  read -rp "Wi‑Fi SSID (blank = skip Wi‑Fi): " SSID
  if [[ -n $SSID ]]; then
    read -srp "Wi‑Fi pass‑phrase (blank = open AP): " PASS
    echo
    {
      echo "country=US"
      wpa_passphrase "$SSID" "$PASS"
    } >"$BOOT_MNT/wpa_supplicant.conf"
    chmod 600 "$BOOT_MNT/wpa_supplicant.conf"
    echo "  • wpa_supplicant.conf written."
  else
    echo "  • Wi‑Fi setup skipped."
  fi
}

###############################################################################
# Interactive pick of SSH public keys
###############################################################################
setup_ssh_keys() {
  PUBS=("$HOME/.ssh/*.pub")
  if ((${#PUBS[@]})); then
    echo "Found SSH public keys:"
    for i in "${!PUBS[@]}"; do printf "  [%d] %s\n" "$i" "${PUBS[$i]}"; done
    read -rp "Enter numbers to include (space/comma separated, empty = all): " SEL
    SEL=${SEL//,/ }
    if [[ -z $SEL ]]; then
      SELECTED=("${PUBS[@]}")
    else
      SELECTED=()
      for idx in $SEL; do
        [[ $idx =~ ^[0-9]+$ ]] && ((idx < ${#PUBS[@]})) && SELECTED+=("${PUBS[$idx]}")
      done
    fi
    if ((${#SELECTED[@]})); then
      cat ${SELECTED[@]} >"$BOOT_MNT/authorized_keys"
      chmod 600 "$BOOT_MNT/authorized_keys"
      echo "  • ${#SELECTED[@]} key(s) saved to authorized_keys."
    else
      echo "  • No valid selection – authorized_keys omitted."
    fi
  else
    echo "  • No ~/.ssh/*.pub keys found."
  fi
}


###############################################################################
# Configure kernel command line settings
###############################################################################
setup_cmdline() {
  if ! grep -q 'cgroup_memory=1' "$BOOT_MNT/cmdline.txt"; then
    sudo sed -i 's#$# cgroup_memory=1 cgroup_enable=memory#' "$BOOT_MNT/cmdline.txt"
  fi
}


###############################################################################
# Add settings to usercfg.txt
###############################################################################
setup_usercfg() {
  if ! grep -q 'i2c_arm' "$BOOT_MNT/usercfg.txt"; then
  echo 'dtparam=i2c_arm=on' > "$BOOT_MNT/usercfg.txt"
}


###############################################################################
# unattended.sh (executed once by overlay)
###############################################################################
setup_unattended_script() {
  cp ./unattended.sh "$BOOT_MNT/"
  chmod +x "$BOOT_MNT/unattended.sh"
  echo "  • unattended.sh ready."

  sync
}


###############################################################################
# main script
###############################################################################
main() {
  OPTIND=1  # Reset in case getopts has been used previously in the shell.

  verbose=0

  while getopts "h?b:v" opt; do
    case "$opt" in
      h|\?)
        usage
        exit 0
        ;;
      b)  boot_dir=$OPTARG
        ;;
      v)  verbose=1
        ;;
    esac

    if [[ "$verbose" == 1 ]]; then
      echo "\$opt: -$opt ${OPTARG:-}"
    fi
  done

  shift $((OPTIND-1))

  [ "${1:-}" = "--" ] && shift


  [[ -z ${boot_dir:-} ]] && die "$(usage)"

  echo "preparing SD card for alpine-linux on raspberry pi"

  locate_boot "$boot_dir"
  download_headless_bootstrap
  setup_cmdline
  setup_usercfg
  setup_wpa_supplicant
  setup_ssh_keys
  setup_unattended_script

  echo "✔  SD card prepared – you may now eject and boot the Pi."
}

main "$@"
