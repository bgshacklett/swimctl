#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail

# shellcheck source=etc/unattended.lib.sh
. "$BOOT/unattended.lib.sh"


# ============================================================
# Configuration (override with env vars before running)
# ============================================================
: "${SSH_PORT:=22}"                # change if you want a non-standard port
: "${DISABLE_ROOT:=yes}"           # yes|no (locks root & forbids root SSH)
: "${RANDOMIZE_ROOT_PW:=no}"       # yes|no (ignored if DISABLE_ROOT=yes)
: "${EXTRA_PACKAGES:=}"            # space-separated list, optional


_die() { >&2 echo "FATAL: $1"; exit 1; }

need() {
  # Install packages if missing; works in install mode too.
  # Avoids --no-cache so we can benefit from local/persistent cache if
  # configured.
  >&2 echo "Ensuring package installation for: $*"
  apk add -v --update "$@" || _die "Could not install required package."
}

file_has() { [ -f "$1" ] && grep -q "$2" "$1"; }

harden_sshd() {
  need openssh
  # Ensure service enabled
  rc-update add sshd default >/dev/null 2>&1 || true

  # Basic hardening and custom port (idempotent edits)
  ss="/etc/ssh/sshd_config"
  [ -f "$ss" ] || touch "$ss"

  # Replace or add settings:
  set_kv() {
    key="$1"; val="$2"
    if grep -qi "^\\s*${key}\\b" "$ss"; then
      sed -i "s|^[#[:space:]]*${key}.*|${key} ${val}|I" "$ss"
    else
      printf '%s %s\n' "$key" "$val" >> "$ss"
    fi
  }

  set_kv Port "$SSH_PORT"
  set_kv PasswordAuthentication no
  set_kv ChallengeResponseAuthentication no
  set_kv KbdInteractiveAuthentication no
  set_kv PermitRootLogin prohibit-password

  if [ "$DISABLE_ROOT" = "yes" ]; then
    set_kv PermitRootLogin no
    passwd -l root >/dev/null 2>&1 || true
  elif [ "$RANDOMIZE_ROOT_PW" = "yes" ]; then
    # Random 24 bytes, base64—strip slashes to avoid any surprises
    pw="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | base64 | tr -d '/=[:space:]' | cut -c1-32)"
    echo "root:$pw" | chpasswd
    _logger "Random root password set."
  fi

  # Start if possible (may be harmless in install mode if not running yet)
  rc-service sshd restart >/dev/null 2>&1 || true
}



setup_alpine() {
  need envsubst

  SETUP_OPTS="-e"  # Setting root password fails in unattended setup.

  LBUOPTS="$(find /media \
             -maxdepth 3 \
             -type d \
             -path '*/.*' \
             -prune -o \
             -type f \
             -name '.boot_repository' \
             -exec dirname {} \; \
             | head -1 \
             | xargs dirname)"

  export LBUOPTS

  envsubst < "${BOOT}/answers.txt"  > /tmp/ANSWERFILE

  SSH_CONNECTION="FAKE" setup-alpine "$SETUP_OPTS" -f /tmp/ANSWERFILE
}


install_extras() {
  [ -n "$EXTRA_PACKAGES" ] || return 0

  # shellcheck disable=2086  # We rely on splitting here
  need $EXTRA_PACKAGES
}

main() {
  _logger "Setting-up Alpine for Persistent Use"

  # Retrieve WiFi config from wpa_supplicant.conf
  INTERFACESOPTS_SSID="$(grep '^\sssid=' "$BOOT/wpa_supplicant.conf" \
                         | cut -d = -f 2 \
                         | tr -d '"')"
  export INTERFACESOPTS_SSID

  INTERFACESOPTS_PSK="$(grep '^\spsk=' "$BOOT/wpa_supplicant.conf" \
                        | cut -d = -f 2)"
  export INTERFACESOPTS_PSK

  setup_alpine
  harden_sshd
  install_extras

  _logger "Unattended finish: done."
}

main "$@"
