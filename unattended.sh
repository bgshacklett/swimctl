#!/bin/sh

# Original unattended.sh script:
# https://raw.githubusercontent.com/macmpi/alpine-linux-headless-bootstrap/3666fd7caf82946715c6fd2b555e5db8b94b2e36/sample_unattended.sh

# SPDX-FileCopyrightText: Copyright 2022-2023, macmpi
# SPDX-License-Identifier: MIT

## collection of few code snippets as sample unnatteded actions some may find usefull

## will run encapusated within headless_unattended OpenRC service

# To prevent headless bootstrap script from starting sshd
# only keep a single starting # on the line below
##NO_SSH

# Uncomment to enable stdout and errors redirection to console (service won't show messages)
# exec 1>/dev/console 2>&1

# shellcheck disable=SC2142  # known special case
alias _logger='logger -st "${0##*/}"'

## Obvious one; reminder: is run as background service
_logger "hello world !!"
sleep 60
_logger "Finished script"
########################################################


## This snippet removes apkovl file on volume after initial boot
# grab used ovl filename from dmesg
ovl="$( dmesg | grep -o 'Loading user settings from .*:' | awk '{print $5}' | sed 's/:.*$//' )"
if [ -f "${ovl}" ]; then
	ovlpath="$( dirname "$ovl" )"
else
	# search path again as mountpoint have been changed later in the boot process...
	ovl="$( basename "${ovl}" )"
	ovlpath=$( find /media -maxdepth 2 -type d -path '*/.*' -prune -o -type f -name "${ovl}" -exec dirname {} \; | head -1 )
	ovl="${ovlpath}/${ovl}"
fi

# also works in case volume is mounted read-only
grep -q "${ovlpath}.*[[:space:]]ro[[:space:],]" /proc/mounts; is_ro=$?
_is_ro() { return "$is_ro"; }
_is_ro && mount -o remount,rw "${ovlpath}"
rm -f "${ovl}"
_is_ro && mount -o remount,ro "${ovlpath}"

########################################################



## This snippet configures Minimal diskless environment
# note: with INTERFACESOPTS=none, no networking will be setup so it won't work after reboot!
# Change it or run setup-interfaces in interractive mode afterwards (and lbu commit -d thenafter)

INTERFACESOPTS_SSID="$(grep '^\sssid=' wpa_supplicant.conf \
                       | cut -d = f 2 \
                       | tr -d '"')"

INTERFACESOPTS_PSK="$(grep '^\spsk=' wpa_supplicant.conf | cut -d = f 2)"


_logger "Setting-up minimal environment"


cat <<-EOF > /tmp/ANSWERFILE
	# base answer file for setup-alpine script

	KEYMAPOPTS="us us"

	# Keep hostname
	HOSTNAMEOPTS="$(hostname)"

	# Set device manager to mdev
	DEVDOPTS=mdev

	# Contents of /etc/network/interfaces
	INTERFACESOPTS="auto lo
	iface lo inet loopback
	
	auto wlan0
	iface wlan0 inet dhcp
	    wpa-ssid ${INTERFACESOPT_SSID}
	    wpa-psk  ${INTERFACESOPTS_PSK}"
	
	# Set timezone to local time. This device performs tasks on a schedule, and
	# keeping it in the local time zone makes more sense than using an offset.
	TIMEZONEOPTS="-z America/New_York"

	# Add first mirror (CDN)
	APKREPOSOPTS="-1"

	# Do not create any user
	USEROPTS=none

	# No Openssh
	SSHDOPTS="-c openssh"

	# Use openntpd
	NTPOPTS="chrony"

	# No disk install (diskless)
	DISKOPTS=none

  # Setup storage for diskless (find boot directory in
  # /media/xxxx/apk/.boot_repository)
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

	APKCACHEOPTS="\$LBUOPTS/cache"
	EOF

# trick setup-alpine to pretend existing SSH connection
# and therefore keep (do not reset) network interfaces while running in background
# requires alpine-conf 3.15.1 and later, available from Alpine 3.17
SSH_CONNECTION="FAKE" setup-alpine -ef /tmp/ANSWERFILE

########################################################


# Autoload I²C modules
mkdir -p /etc/modules-load.d
printf '%s\n' i2c_bcm2835 i2c_dev > /etc/modules-load.d/i2c.conf

# Optional: convert first USB drive to data‑disk and point K3s there
DISK=/dev/sda
if [ -b "$DISK" ] && ! mountpoint -q /var; then
  setup-disk -m data "$DISK"
  echo 'K3S_DATA_DIR=/var/lib/rancher/k3s' >> /etc/profile
fi

# One‑time cleanup
shred -u /media/mmcblk0p1/wpa_supplicant.conf 2>/dev/null || true
rm -f /media/mmcblk0p1/unattended.sh

# Commit changes
lbu commit -d

_logger "Finished unattended script. Rebooting!"
reboot
