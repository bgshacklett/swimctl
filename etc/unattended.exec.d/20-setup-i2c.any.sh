#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail


# Autoload I²C modules
mkdir -p /etc/modules-load.d
printf '%s\n' i2c_bcm2835 i2c_dev > /etc/modules-load.d/i2c.conf
