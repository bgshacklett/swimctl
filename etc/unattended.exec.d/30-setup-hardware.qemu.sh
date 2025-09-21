#!/bin/sh

. "$BOOT/unattended.lib.sh"


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
ls /sys/class/net | grep -E '^wlan[0-9]+$' || {
  echo "No wlan* found. Did modprobe mac80211_hwsim radios=2 succeed?"; exit 1; }

# pick radios (as you already do)
WLAN_LIST="$($IP -o link show | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]+$' | sort)"
AP_WLAN="$(echo "$WLAN_LIST" | sed -n '1p')"   # e.g., wlan0
STA_WLAN="$(echo "$WLAN_LIST" | sed -n '2p')"  # e.g., wlan1

[ -n "$AP_WLAN" ] && [ -n "$STA_WLAN" ] || {
  echo "Need two wlan* from hwsim; found: $WLAN_LIST"; exit 1; }

# create namespace, move uplink with ip
$IP netns add ap 2>/dev/null || true
UPLINK="$($IP -o link show | awk -F': ' '{print $2}' \
  | awk '/^usb0$/ {print; exit} /^eth[0-9]+$/ && !seen[$0]++ {print; exit}')"
[ -n "$UPLINK" ] || { echo "No uplink (usb0/ethX) found"; exit 1; }

$IP link set "$UPLINK" down
$IP link set "$UPLINK" netns ap

ip link set "$AP_WLAN" down
AP_PHY="$(basename "$(readlink -f "/sys/class/net/$AP_WLAN/phy80211")")"
iw phy "$AP_PHY" set netns name ap


/sbin/ip netns exec ap /bin/sh -xc ". $BOOT/unattended.lib.sh; config_sim_ap $IP"
$IP netns exec ap $IP -br link | sed 's/^/ ap : /'


$IP link set "$STA_WLAN" up
install -m600 "$BOOT"/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf
rc-service wpa_supplicant restart

if wait_for_wpa "$STA_WLAN" 20; then
		udhcpc -i "$STA_WLAN" -n -q -t 5 -T 3
else
    echo "failed to authenticate"
fi

$IP -br link | sed 's/^/root: /'


# Optional smoke cheks
ping -c1 -W1 10.23.0.1 >/dev/null 2>&1 || true
ping -c1 -W1 1.1.1.1   >/dev/null 2>&1 || true

log "hwsim up: STA (root ns, wlan1) ↔ AP (ap ns, wlan0) with NAT via usb0."



set +x
