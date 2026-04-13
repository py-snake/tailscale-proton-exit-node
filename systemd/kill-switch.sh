#!/bin/bash
set -euo pipefail

# Kill switch using prohibit routes (same approach as protonwire).
#
# How it works:
#   - Normal VPN routes are added at metric 500 by systemd-networkd
#   - Prohibit (blackhole) routes are added here at metric 900
#   - When proton0 is UP: traffic matches metric-500 routes → goes through VPN
#   - When proton0 is DOWN: metric-500 routes vanish → traffic hits metric-900
#     prohibit routes → all traffic is BLOCKED
#
# Excluded from kill switch (remain reachable):
#   - 10.0.0.0/8      (LAN / ProtonVPN internal)
#   - 100.64.0.0/10   (Tailscale CGNAT)
#   - 169.254.0.0/16  (link-local)
#   - 172.16.0.0/12   (LAN)
#   - 192.168.0.0/16  (LAN)

if [ "${KILL_SWITCH:-false}" != "true" ]; then
    echo "Kill switch disabled, skipping."
    exit 0
fi

echo "Waiting for proton0 interface..."
for i in $(seq 1 30); do
    if ip link show proton0 >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: proton0 not found, cannot set up kill switch" >&2
        exit 1
    fi
    sleep 1
done

TABLE=51820

# These subnets cover the public internet while excluding RFC-1918, CGNAT,
# and link-local. This is the same split used by protonwire.
SUBNETS=(
    "0.0.0.0/5"
    "8.0.0.0/7"
    "11.0.0.0/8"
    "12.0.0.0/6"
    "16.0.0.0/4"
    "32.0.0.0/3"
    "64.0.0.0/2"
    "128.0.0.0/3"
    "160.0.0.0/5"
    "168.0.0.0/6"
    "172.0.0.0/12"
    "172.32.0.0/11"
    "172.64.0.0/10"
    "172.128.0.0/9"
    "173.0.0.0/8"
    "174.0.0.0/7"
    "176.0.0.0/4"
    "192.0.0.0/9"
    "192.128.0.0/11"
    "192.160.0.0/13"
    "192.169.0.0/16"
    "192.170.0.0/15"
    "192.172.0.0/14"
    "192.176.0.0/12"
    "192.192.0.0/10"
    "193.0.0.0/8"
    "194.0.0.0/7"
    "196.0.0.0/6"
    "200.0.0.0/5"
    "208.0.0.0/4"
)

echo "Installing kill-switch prohibit routes (table ${TABLE}, metric 900)..."
for subnet in "${SUBNETS[@]}"; do
    ip -4 route replace table "$TABLE" prohibit "$subnet" metric 900 2>/dev/null || true
done

echo "Kill switch active. Traffic will be blocked if proton0 goes down."
