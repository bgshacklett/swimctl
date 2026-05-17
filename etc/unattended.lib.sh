#!/bin/sh
# unattended.lib.sh — shared helpers for unattended.sh and friends.
#
# Sourced from:
#   - etc/unattended.sh                          (via $BOOT)
#   - etc/pre-network.d/*.sh                     (via $OVLPATH)
#   - etc/unattended.exec.d/*.sh                 (via $BOOT)
#
# MUST be POSIX sh — the consumers run under Alpine's /bin/sh (busybox ash).
# MUST NOT rely on aliases — exec.d scripts are invoked in subshells from
# unattended.sh and aliases do not propagate across that boundary.

# _logger: tag-prefixed log to stderr + syslog.
#
# unattended.sh defines `_logger` as an alias before sourcing this file. That
# alias does not survive into the subshell that runs each exec.d script, so we
# (re)define it as a real function here. `${0##*/}` resolves to the basename of
# whichever script is currently executing, so each line is tagged with the
# script that produced it.
_logger() {
    logger -st "${0##*/}" -- "$@"
}

# config_sim_ap: configure a simulated wifi AP inside the `ap` netns.
#
# Called from etc/pre-network.d/10-setup-wifi.qemu.sh as:
#   ip netns exec ap /bin/sh -xc \
#     ". $OVLPATH/unattended.lib.sh; config_sim_ap $IP $OVLPATH"
#
# When fully implemented this should:
#   - write a hostapd.conf matching the wpa_supplicant client's SSID/PSK
#   - bring up the AP-side wlan iface with an IPv4 address
#   - run a DHCP server (udhcpd or dnsmasq) so the STA gets a lease
#   - NAT-masquerade out the uplink iface that was moved into this netns
#
# STUB: returns 0 so the surrounding pre-network script can complete. The real
# implementation will land alongside the Phase 2 QEMU wifi assertion that
# verifies wpa_supplicant reaches state=COMPLETED.
config_sim_ap() {
    _ip_cmd="${1:-/sbin/ip}"
    _ovl_path="${2:-}"
    _logger "config_sim_ap: stub (ip=$_ip_cmd ovl=$_ovl_path) — AP simulation not yet implemented"
    return 0
}
