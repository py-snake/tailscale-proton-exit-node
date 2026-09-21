#!/bin/bash
set -u

# Recycle the warp0 (WARP) tunnel when it stops working.
#
# Two failure classes are covered:
#   1. Handshake stale/missing — Cloudflare maintenance, NAT mapping loss,
#      or session eviction. Recreating the interface forces a fresh handshake.
#   2. Routing policy lost — the fwmark rule or table-51820 default route
#      vanished while the handshake still looks fine ("connected but not
#      routing"). Re-running wg-config reinstalls both.
#
# Restarting wg-config.service is safe: the script is idempotent and the
# kill-switch prohibit routes (metric 900, not device-bound) stay in place
# during the recycle, so client traffic is blocked rather than leaked.

THRESHOLD="${WATCHDOG_HANDSHAKE_MAX_AGE:-180}"

handshake_age() {
    local last now up_us boot_us
    last=$(wg show warp0 latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    if [ -z "${last:-}" ]; then
        echo -1
        return
    fi
    now=$(date +%s)
    if [ "$last" -eq 0 ]; then
        # Never handshaken: measure from when wg-config brought the link up,
        # so a freshly booted container isn't recycled before its first handshake
        up_us=$(systemctl show -p ActiveEnterTimestampMonotonic --value wg-config.service)
        boot_us=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
        echo $(( (boot_us - up_us) / 1000000 ))
    else
        echo $(( now - last ))
    fi
}

AGE=$(handshake_age)
if [ "$AGE" -lt 0 ]; then
    echo "warp0 interface missing — recycling tunnel"
elif [ "$AGE" -gt "$THRESHOLD" ]; then
    echo "WireGuard handshake stale (${AGE}s > ${THRESHOLD}s) — recycling tunnel"
elif ! ip -4 rule show | grep -q "fwmark 0xca6c"; then
    echo "fwmark policy rule missing — recycling tunnel"
elif ! ip -4 route show table 51820 | grep -q "^default"; then
    echo "table 51820 default route missing — recycling tunnel"
else
    exit 0
fi

systemctl restart wg-config.service
echo "wg-config restarted; handshake age now: $(handshake_age)s"