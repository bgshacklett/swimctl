#!/bin/sh

. "$BOOT/unattended.lib.sh"


set -x
dmesg | grep -E -i 'usb|cdc|rndis|eth'
lsmod | grep -E 'usbnet|cdc_ether|cdc_subset|rndis_host' || true
modprobe usbnet cdc_ether cdc_subset rndis_host  # harmless if already present


# Set up initial network connectivity to retrieve required packages
ip link show
ip link set usb0 up

# continues only if a lease was obtained
udhcpc -i usb0 -n -q -t 5 -T 3

set +x
