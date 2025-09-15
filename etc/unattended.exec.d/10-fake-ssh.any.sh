#!/bin/sh

. "$BOOT/unattended.lib.sh"

set -x
LINK_NAME="$(ip -br link)"

_logger "Found link named: $LINK_NAME"

udhcpc -i "$LINK_NAME"
set +x
