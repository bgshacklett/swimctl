#!/bin/sh

shred -u /media/mmcblk0p1/wpa_supplicant.conf 2>/dev/null || true

# TODO: Remove apkovl

rm -f /media/mmcblk0p1/unattended.sh
