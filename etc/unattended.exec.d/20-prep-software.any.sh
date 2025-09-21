#!/bin/sh

. "$BOOT/unattended.lib.sh"

set -x
ntpd -n -q -p pool.ntp.org
date -u    # sanity-check it's roughly correct now



# temporarily point to HTTP so we can install CA certs
echo 'http://dl-cdn.alpinelinux.org/alpine/latest-stable/main' >/etc/apk/repositories

apk update
apk add ca-certificates-bundle

# ensure BusyBox sees the right file (usually created by the pkg already)
ls -l /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt
# if /etc/ssl/cert.pem is missing for some reason:
ln -sf /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem

set +x
