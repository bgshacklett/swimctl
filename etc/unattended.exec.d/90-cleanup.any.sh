#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail


shred -u /media/mmcblk0p1/wpa_supplicant.conf 2>/dev/null || rm -f /media/mmcblk0p1/wpa_supplicant.conf

# TODO: Remove apkovl

# rm -f /media/mmcblk0p1/unattended.sh
