#!/bin/sh
set -e

# Enable I²C in firmware
grep -q '^dtparam=i2c_arm=on' /boot/usercfg.txt 2>/dev/null ||
  echo 'dtparam=i2c_arm=on' >> /boot/usercfg.txt

# Autoload I²C modules
mkdir -p /etc/modules-load.d
printf '%s\n' i2c_bcm2835 i2c_dev > /etc/modules-load.d/i2c.conf

# Add cgroup v1 memory flags if missing
grep -q 'cgroup_memory=1' /boot/cmdline.txt ||
  sed -i 's#$# cgroup_memory=1 cgroup_enable=memory#' /boot/cmdline.txt

# Optional: convert first USB drive to data‑disk and point K3s there
DISK=/dev/sda
if [ -b "$DISK" ] && ! mountpoint -q /var; then
  setup-disk -m data "$DISK"
  echo 'K3S_DATA_DIR=/var/lib/rancher/k3s' >> /etc/profile
fi

# One‑time cleanup
shred -u /media/mmcblk0p1/wpa_supplicant.conf 2>/dev/null || true
rm -f /media/mmcblk0p1/unattended.sh
logger -t unattended "unattended.sh done – rebooting"
reboot
