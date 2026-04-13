#!/bin/bash
set -euo pipefail

# Validate required env vars
for var in WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_ENDPOINT WG_ADDRESS WG_DNS; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var is not set" >&2
        exit 1
    fi
done

# ProtonVPN uses 10.2.0.1 as the internal gateway/DNS
WG_GATEWAY="${WG_DNS%%,*}"

echo "Generating systemd-networkd WireGuard configuration..."

# --- proton0.netdev: WireGuard interface ---
cat > /etc/systemd/network/proton0.netdev <<EOF
[NetDev]
Name=proton0
Kind=wireguard

[WireGuard]
PrivateKey=${WG_PRIVATE_KEY}
FirewallMark=51820

[WireGuardPeer]
PublicKey=${WG_PEER_PUBLIC_KEY}
AllowedIPs=0.0.0.0/0
Endpoint=${WG_ENDPOINT}
PersistentKeepalive=25
EOF
chmod 640 /etc/systemd/network/proton0.netdev

# --- proton0.network: routing policy ---
# Priority 6000 ensures Tailscale rules (5210-5270) are evaluated first.
# InvertRule + FirewallMark: packets NOT marked as WireGuard go through
# table 51820 (the ProtonVPN tunnel). Tailscale control-plane traffic
# is handled by Tailscale's own rules before reaching priority 6000.
cat > /etc/systemd/network/proton0.network <<EOF
[Match]
Name=proton0

[Network]
Address=${WG_ADDRESS}
DNS=${WG_DNS}
DNSDefaultRoute=yes

[RoutingPolicyRule]
InvertRule=yes
FirewallMark=51820
Table=51820
Priority=6000

[Route]
Gateway=${WG_GATEWAY}
GatewayOnLink=yes
Table=51820
EOF

echo "WireGuard config written to /etc/systemd/network/proton0.{netdev,network}"
