#!/bin/bash
set -euo pipefail

# Bring up the proton0 WireGuard interface and install routing policy.
#
# Doing this directly (instead of via systemd-networkd .netdev/.network files)
# because systemd-networkd inside a container without systemd-udevd cannot
# match .network files to wg links — Network File stays "n/a" and the
# [RoutingPolicyRule]/[Route] blocks never get applied.

for var in WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_ENDPOINT WG_ADDRESS WG_DNS; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set" >&2
        exit 1
    fi
done

# ProtonVPN uses 10.2.0.1 as the internal gateway/DNS
WG_GATEWAY="${WG_DNS%%,*}"
TABLE=51820
FWMARK=51820
PRIORITY=6000

echo "Configuring proton0 WireGuard interface..."

# Idempotent: drop any previous instance
ip link del proton0 2>/dev/null || true

ip link add proton0 type wireguard

# Apply WG config via a private temp file (private key never hits a world-readable path)
CONF=$(mktemp)
trap 'rm -f "$CONF"' EXIT
chmod 600 "$CONF"
cat > "$CONF" <<EOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
FwMark = ${FWMARK}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0
Endpoint = ${WG_ENDPOINT}
PersistentKeepalive = 25
EOF
wg setconf proton0 "$CONF"

ip addr add "${WG_ADDRESS}" dev proton0
ip link set proton0 up

# Policy: any packet NOT marked by WG itself (FwMark=51820) goes through table 51820.
# WG's outgoing tunnel packets are marked, so they bypass the rule and use the main
# table → eth0 → ProtonVPN endpoint. Tailscale's own rules at priority 5210-5270
# are evaluated before ours (lower priority wins) and let control traffic go direct.
ip -4 rule del priority "${PRIORITY}" 2>/dev/null || true
ip -4 rule add not from all fwmark "${FWMARK}" table "${TABLE}" priority "${PRIORITY}"

ip -4 route replace default via "${WG_GATEWAY}" dev proton0 onlink table "${TABLE}" metric 500

echo "proton0 up: address=${WG_ADDRESS}, gateway=${WG_GATEWAY}, table=${TABLE}, fwmark=${FWMARK}"
