#!/bin/bash
set -e

# Check WireGuard interface exists
if ! ip link show warp0 >/dev/null 2>&1; then
    echo "FAIL: warp0 interface missing"
    exit 1
fi

# Check for a recent WireGuard handshake (within last 3 minutes)
LAST_HS=$(wg show warp0 latest-handshakes 2>/dev/null | awk '{print $2}')
if [ -z "$LAST_HS" ] || [ "$LAST_HS" -eq 0 ]; then
    echo "FAIL: no WireGuard handshake"
    exit 1
fi
NOW=$(date +%s)
AGE=$(( NOW - LAST_HS ))
if [ "$AGE" -gt 180 ]; then
    echo "FAIL: WireGuard handshake stale (${AGE}s ago)"
    exit 1
fi

# Check Tailscale is connected
if ! tailscale status >/dev/null 2>&1; then
    echo "FAIL: tailscale not connected"
    exit 1
fi

echo "OK: WG handshake ${AGE}s ago, tailscale up"