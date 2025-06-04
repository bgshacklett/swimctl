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

die() {
  echo "❌  $*" >&2
  exit 1
}

###############################################################################
# 1. Locate the BOOT (FAT) partition
###############################################################################
ARG=${1:-}
[[ -z $ARG ]] && die "Usage: $0 /path/to/BOOT"

if [[ -d $ARG ]]; then # user passed a mount‑path
  BOOT_MNT=$ARG
else
  die "Argument must be block device or mounted BOOT directory"
fi

echo "► Using BOOT at: $BOOT_MNT"

###############################################################################
# 2. Download headless.apkovl.tar.gz (3‑stage fallback)
###############################################################################
SMART_URL="https://github.com/macmpi/alpine-linux-headless-bootstrap/releases/latest/download/headless.apkovl.tar.gz"
TMP_FILE="$BOOT_MNT/headless.apkovl.tar.gz"

echo "► Downloading headless.apkovl.tar.gz …"

# Stage 1 – direct release smart‑link
if curl -fsSL -L "$SMART_URL" -o "$TMP_FILE"; then
  echo "  • Overlay saved as $(basename "$TMP_FILE") (via release smart‑link)"
else
  echo "  • smart‑link 404 – querying GitHub API via jq …"
  command -v jq >/dev/null 2>&1 || die "jq required (apk/apt/brew install jq)"
  API_URL=$(curl -fsSL https://api.github.com/repos/macmpi/alpine-linux-headless-bootstrap/releases/latest |
    jq -r '.assets[]? | select(.name | endswith("apkovl.tar.gz")) | .browser_download_url' |
    head -n1)
  if [[ -n $API_URL ]] && curl -fsSL -L "$API_URL" -o "$TMP_FILE"; then
    echo "  • Overlay saved as $(basename "$TMP_FILE") (via release asset)"
  else
    echo "  • release has no asset – fetching raw file from main branch …"
    RAW_URL="https://raw.githubusercontent.com/macmpi/alpine-linux-headless-bootstrap/main/headless.apkovl.tar.gz"
    curl -fsSL -L "$RAW_URL" -o "$TMP_FILE" ||
      die "Failed to download overlay via all methods (raw URL attempted: $RAW_URL)"
    echo "  • Overlay saved as $(basename "$TMP_FILE") (via repository raw file)"
  fi
fi

###############################################################################
# 3. Build wpa_supplicant.conf (optional)
###############################################################################
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

###############################################################################
# 4. Interactive pick of SSH public keys
###############################################################################
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

###############################################################################
# 5. unattended.sh (executed once by overlay)
###############################################################################
cp ./unattended.sh "$BOOT_MNT/"
chmod +x "$BOOT_MNT/unattended.sh"
echo "  • unattended.sh ready."

sync
echo "✔  SD card prepared – you may now eject and boot the Pi."
