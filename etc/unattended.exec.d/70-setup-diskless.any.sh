#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail

# shellcheck source=etc/unattended.lib.sh
. "$BOOT/unattended.lib.sh"


# ============================================================
# Configuration (override with env vars before running)
# ============================================================
: "${ADMIN_USER:=admin}"           # username to create
: "${ADMIN_SSH_PUBKEY:=}"          # either the full key string OR path to file
: "${TIMEZONE:=UTC}"               # e.g. America/New_York
: "${SSH_PORT:=22}"                # change if you want a non-standard port
: "${DISABLE_ROOT:=yes}"           # yes|no (locks root & forbids root SSH)
: "${RANDOMIZE_ROOT_PW:=no}"       # yes|no (ignored if DISABLE_ROOT=yes)
: "${ADD_SUDO:=yes}"               # yes|no (install sudo, add admin to wheel)
: "${NTP_IMPL:=chrony}"            # chrony|openntpd (chrony recommended)
: "${APK_CACHE_DIR:=}"             # e.g. /media/mmcblk0p1/apkcache  (optional)
: "${LBU_MEDIA:=}"                 # e.g. mmcblk0p1 (boot media name, optional)
: "${ENABLE_COMMUNITY_REPO:=yes}"  # yes|no ("yes" required if ADD_SUDO=yes)
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

ensure_user() {
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    _logger "User '$ADMIN_USER' already exists."
  else
    if ! getent group "$ADMIN_USER" >/dev/null; then
      addgroup -S "$ADMIN_USER"
    fi
    # -D => no password prompt, create home; -s => shell; -G => wheel for sudo (if enabled)
    if [ "$ADD_SUDO" = "yes" ]; then
      need sudo
      # make sure wheel group exists
      getent group wheel >/dev/null 2>&1 || addgroup wheel
      adduser -D -s /bin/ash -g "$ADMIN_USER" -G wheel "$ADMIN_USER"
    else
      adduser -D -s /bin/ash -g "$ADMIN_USER" "$ADMIN_USER"
    fi
    # lock admin password by default (we use key auth)
    passwd -l "$ADMIN_USER" >/dev/null 2>&1 || true
  fi

  # SSH key
  if [ -n "$ADMIN_SSH_PUBKEY" ]; then
    key_data="$ADMIN_SSH_PUBKEY"
    if [ -f "$ADMIN_SSH_PUBKEY" ]; then
      key_data="$(cat "$ADMIN_SSH_PUBKEY")"
    fi
    home_dir="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [ -n "$home_dir" ] || home_dir="/home/$ADMIN_USER"
    mkdir -p "$home_dir/.ssh"
    chmod 700 "$home_dir/.ssh"
    auth="$home_dir/.ssh/authorized_keys"
    touch "$auth"
    chmod 600 "$auth"
    # add key if not already present
    if ! file_has "$auth" "$(printf '%s' "$key_data" | awk '{print $2}')" ; then
      printf '%s\n' "$key_data" >> "$auth"
    fi
    chown -R "$ADMIN_USER:$ADMIN_USER" "$home_dir/.ssh"
  else
    _logger "WARNING: ADMIN_SSH_PUBKEY not provided; admin won't have key access."
  fi
}

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

setup_timezone() {
  # Prefer setup-timezone if available; otherwise do the simple link/write
  if command -v setup-timezone >/dev/null 2>&1; then
    setup-timezone -z "$TIMEZONE"
  else
    echo "$TIMEZONE" > /etc/timezone
    ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  fi
}

enable_ntp() {
  case "$NTP_IMPL" in
    chrony|chronyd)
      need chrony
      rc-update add chronyd default >/dev/null 2>&1 || true
      rc-service chronyd restart >/dev/null 2>&1 || true
      ;;
    openntpd|ntpd)
      need openntpd
      rc-update add ntpd default >/dev/null 2>&1 || true
      rc-service ntpd restart >/dev/null 2>&1 || true
      ;;
    *)
      _logger "Unknown NTP_IMPL='$NTP_IMPL' (use 'chrony' or 'openntpd')."
      ;;
  esac
}

setup_alpine_quick() {
  need envsubst

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

  SSH_CONNECTION="FAKE" setup-alpine -q -f /tmp/ANSWERFILE
}

configure_community_repository() {
  if [ "$ENABLE_COMMUNITY_REPO" != "yes" ]; then return; fi

  sed -i 's/#\(.*\/community\)/\1/' /etc/apk/repositories
  apk update
}

configure_apk_cache() {
  # If you specify APK_CACHE_DIR on persistent media, we’ll point /etc/apk/cache there.
  # Otherwise we at least ensure /etc/apk/cache exists locally.
  if [ -n "$APK_CACHE_DIR" ]; then
    mkdir -p "$APK_CACHE_DIR"
    # setup-apkcache is available in alpine-conf; fall back to manual link if missing
    if command -v setup-apkcache >/dev/null 2>&1; then
      setup-apkcache -q "$APK_CACHE_DIR"
    else
      mkdir -p /etc/apk
      rm -rf /etc/apk/cache
      ln -s "$APK_CACHE_DIR" /etc/apk/cache
    fi
    _logger "apk cache -> $APK_CACHE_DIR"
  else
    mkdir -p /etc/apk/cache
  fi
}

configure_lbu() {
  # Optional; only if LBU_MEDIA provided. This assumes lbu is present.
  # LBU lets you persist changes to the boot media (apkovl).
  [ -n "$LBU_MEDIA" ] || return 0
  need lbu 2>/dev/null || true

  # Configure media target
  if command -v lbu >/dev/null 2>&1; then
    # Try to set media; if lbu set not present, use config file as fallback
    if lbu set -d "$LBU_MEDIA" >/dev/null 2>&1; then
      :
    else
      # Fallback to config file
      mkdir -p /etc/lbu
      if [ -f /etc/lbu/lbu.conf ]; then
        sed -i "s|^LBU_MEDIA=.*|LBU_MEDIA=\"$LBU_MEDIA\"|" /etc/lbu/lbu.conf || true
      else
        printf 'LBU_MEDIA="%s"\n' "$LBU_MEDIA" > /etc/lbu/lbu.conf
      fi
    fi

    # Ensure we persist key config files
    lbu add /etc/ssh/sshd_config >/dev/null 2>&1 || true
    lbu add /etc/timezone /etc/localtime >/dev/null 2>&1 || true
    [ -f /etc/sudoers.d/10-wheel ] && lbu add /etc/sudoers.d/10-wheel >/dev/null 2>&1 || true
    lbu add /etc/apk/repositories /etc/apk/world >/dev/null 2>&1 || true

    # You can optionally commit here if desired:
    # lbu commit
  else
    _logger "WARNING: 'lbu' not available; skipping lbu config."
  fi
}

configure_sudo() {
  [ "$ADD_SUDO" = "yes" ] || return 0
  need sudo
  mkdir -p /etc/sudoers.d
  f=/etc/sudoers.d/10-wheel
  if [ ! -f "$f" ]; then
    umask 077
    cat > "$f" <<'EOF'
# Allow members of group wheel to execute any command with no password
# (we don't use passwords on this system)
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$f"
  fi
}

install_extras() {
  [ -n "$EXTRA_PACKAGES" ] || return 0
  need $EXTRA_PACKAGES
}

main() {
  _logger "Setting-up Alpine for Persistent Use"

  # Retrieve WiFi config from wpa_supplicant.conf
  INTERFACESOPTS_SSID="$(grep '^\sssid=' "$BOOT/wpa_supplicant.conf" \
                         | cut -d = -f 2 \
                         | tr -d '"')"

  INTERFACESOPTS_PSK="$(grep '^\spsk=' "$BOOT/wpa_supplicant.conf" \
                        | cut -d = -f 2)"

  setup_alpine_quick
  configure_community_repository
  configure_apk_cache
  install_extras
  ensure_user
  configure_sudo
  harden_sshd
  setup_timezone
  enable_ntp
  configure_lbu

  _logger "Unattended finish: done."
}

main "$@"
