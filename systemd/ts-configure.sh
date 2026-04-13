#!/bin/bash
set -euo pipefail

# Wait for tailscaled socket
echo "Waiting for tailscaled..."
for i in $(seq 1 30); do
    if tailscale status >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: tailscaled did not start within 30s" >&2
        exit 1
    fi
    sleep 1
done

# Wait for proton0 interface
echo "Waiting for proton0 interface..."
for i in $(seq 1 30); do
    if ip link show proton0 >/dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: proton0 interface did not appear within 30s" >&2
        exit 1
    fi
    sleep 1
done

# Set up NAT: masquerade exit-node traffic leaving via ProtonVPN
echo "Configuring iptables NAT..."
iptables -t nat -C POSTROUTING -o proton0 -j MASQUERADE 2>/dev/null ||
    iptables -t nat -A POSTROUTING -o proton0 -j MASQUERADE

iptables -C FORWARD -i tailscale0 -o proton0 -j ACCEPT 2>/dev/null ||
    iptables -A FORWARD -i tailscale0 -o proton0 -j ACCEPT

iptables -C FORWARD -i proton0 -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
    iptables -A FORWARD -i proton0 -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Bring up Tailscale as exit node
echo "Starting Tailscale..."
tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME:-proton-exit}" \
    --advertise-exit-node \
    --accept-routes=false \
    ${TS_EXTRA_ARGS:-}

echo "Tailscale exit node is live."
tailscale status
echo ""
echo "Verifying ProtonVPN tunnel..."
EXTERNAL_IP=$(curl -sf --max-time 10 https://icanhazip.com/ 2>/dev/null || echo "unknown")
echo "External IP: ${EXTERNAL_IP}"
