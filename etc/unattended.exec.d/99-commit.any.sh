#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail

# Show changes to be committed
lbu status -a

# Commit changes
lbu commit -d mmcblk1p1

set +x
