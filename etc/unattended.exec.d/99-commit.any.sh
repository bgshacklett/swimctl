#!/bin/sh

# shellcheck disable=SC3040 #  See: https://blog.toast.cafe/posix2024-xcu
set -euo pipefail

set -x

# Show changes to be committed
lbu status -a

# Commit changes
lbu commit "$BOOT/"
set +x
