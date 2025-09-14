#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail

# Ensure stdout and stderr are redirected to the console
# (service won't show messages)
exec 1>/dev/console 2>&1

# shellcheck disable=SC2142  # known special case
alias _logger='logger -st "${0##*/}"'

_logger "Starting unattended.sh..."


# Run sorted steps
run_steps() {
	dir="$1"
	[ -d "$dir" ] || return 0
	find "$dir" -maxdepth 1 -type f -name '*.sh' | sort | while read -r s; do
		case "$s" in
			*.disabled) continue;;
			*.sh) _logger "→ $s"; ("$s");;
			*) :;;
		esac
	done
}

_logger "Discovering environment..."
# grab used ovl filename from dmesg
HEADLESS_OVL="$( \
	dmesg \
	| grep -o 'Loading user settings from .*:' \
	| awk '{print $5}' \
	| sed 's/:.*$//'
)"

# Locate the boot volume containing .apkovl.tar.gz (USB/SD, gadget, etc.)
if [ -f "${HEADLESS_OVL}" ]; then
	BOOT="$( dirname "$HEADLESS_OVL" )"
else
	# search path again; mountpoint have been changed later in the boot process...
	HEADLESS_OVL="$( basename "${HEADLESS_OVL}" )"
	BOOT=$( find /media -maxdepth 2 -type d -path '*/.*' -prune -o -type f -name "${HEADLESS_OVL}" -exec dirname {} \; | head -1 )
	HEADLESS_OVL="${BOOT}/${HEADLESS_OVL}"
fi
export BOOT
_logger "Found boot media at: $BOOT"


. "$BOOT/unattended.lib.sh"


# Source config (if present) from boot media
# shellcheck disable=SC1091  # Cannot determine path statically
[ -r "$BOOT/unattended.conf" ] && . "$BOOT/unattended.conf"
if [ -d "$BOOT/unattended.conf.d" ]; then
	for f in "$BOOT"/unattended.conf.d/*.conf; do
		_logger "Loading configuration file: $f"
		# shellcheck disable=SC1090  # Cannot specify path; will always be dynamic
		[ -r "$f" ] && . "$f"
	done
fi

# Execute repo-provided steps from the boot media
run_steps "$BOOT/unattended.exec.d"

_logger "Finished unattended script. Rebooting!"
reboot
