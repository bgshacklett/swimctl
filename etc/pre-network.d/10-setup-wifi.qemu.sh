#!/bin/sh
# shellcheck shell=dash

# shellcheck source=etc/unattended.lib.sh
. "$OVLPATH/unattended.lib.sh"


init_pre_setup_networking() {
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
}


setup_prereqs() {
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
}


wait_for_wpa() { # iface timeout
    iface="$1"
    timeout="${2:-30}"   # default: 30s
    t=0
    while [ "$t" -lt "$timeout" ]; do
        state=$(wpa_cli -i "$iface" status 2>/dev/null | awk -F= '/^wpa_state=/{print $2}')
        if [ "$state" = "COMPLETED" ]; then
            echo "wpa_supplicant: authenticated on $iface"
            return 0
        fi
        sleep 1
        t=$((t + 1))
    done
    echo "wpa_supplicant: timeout waiting for authentication on $iface" >&2
    return 1
}


set -x
init_pre_setup_networking
setup_prereqs
# ################################
# Setup wifi hardware simulation #
# ################################

# Add required packages
apk add --force-overwrite --no-cache iproute2-minimal iproute2
apk add --no-cache iw hostapd wpa_supplicant busybox-extras iptables

# Use full iproute2; you've got iproute2-minimal so /sbin/ip is fine
IP=/sbin/ip

# Radios
modprobe mac80211_hwsim radios=2

# “Router/AP” namespace owns wlan0 + usb0
# Take usb0 down and reconfigure it in an isolated network namespace
$IP link set usb0 down


# Make sure radios exist
_have_wlan=0
for _iface in /sys/class/net/wlan[0-9]*; do
  [ -e "$_iface" ] && _have_wlan=1 && break
done
if [ "$_have_wlan" -eq 0 ]; then
  echo "No wlan* found. Did modprobe mac80211_hwsim radios=2 succeed?"
  exit 1
fi

# pick radios (as you already do)
WLAN_LIST="$($IP -o link show | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]+$' | sort)"
AP_WLAN="$(echo "$WLAN_LIST" | sed -n '1p')"   # e.g., wlan0
STA_WLAN="$(echo "$WLAN_LIST" | sed -n '2p')"  # e.g., wlan1

if [ -z "$AP_WLAN" ] || [ -z "$STA_WLAN" ]; then
  echo "Need two wlan* from hwsim; found: $WLAN_LIST"
  exit 1
fi

# create namespace, move uplink with ip
$IP netns add ap 2>/dev/null || true
UPLINK="$($IP -o link show | awk -F': ' '{print $2}' \
  | awk '/^usb0$/ {print; exit} /^eth[0-9]+$/ && !seen[$0]++ {print; exit}')"
[ -n "$UPLINK" ] || { echo "No uplink (usb0/ethX) found"; exit 1; }

$IP link set "$UPLINK" down
$IP link set "$UPLINK" netns ap

$IP link set "$AP_WLAN" down
AP_PHY="$(basename "$(readlink -f "/sys/class/net/$AP_WLAN/phy80211")")"
iw phy "$AP_PHY" set netns name ap


/sbin/ip netns exec ap /bin/sh -xc ". $OVLPATH/unattended.lib.sh; config_sim_ap $IP $OVLPATH"
$IP netns exec ap $IP -br link | sed 's/^/ ap : /'


$IP link set "$STA_WLAN" up
install -m600 "$OVLPATH/wpa_supplicant.conf" /etc/wpa_supplicant/wpa_supplicant.conf
# rc-service wpa_supplicant restart

_logger "hwsim up: STA (root ns, wlan1) ↔ AP (ap ns, wlan0) with NAT via usb0."

set +x
