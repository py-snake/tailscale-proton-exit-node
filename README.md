# Tailscale + ProtonVPN Exit Node

A single Docker container that acts as a **Tailscale exit node** routing all traffic through **ProtonVPN** via WireGuard.

Uses systemd as init and systemd-networkd for WireGuard interface management, with smart routing that keeps Tailscale control traffic direct while sending exit-node traffic through the VPN tunnel.

## How It Works

```
Tailscale peers ──► tailscale0 ──► proton0 (WireGuard) ──► ProtonVPN server ──► Internet
                     │                                          │
                     │  Tailscale control plane                 │  Your traffic exits
                     │  goes direct (priority 5210-5270)        │  with ProtonVPN's IP
                     │                                          │
                     └── Exit traffic hits InvertRule ───────────┘
                         at priority 6000 → VPN tunnel
```

- **systemd-networkd** manages the WireGuard interface via `.netdev`/`.network` files
- **FirewallMark + InvertRule** routing ensures Tailscale's own traffic bypasses the VPN
- **Kill switch** uses prohibit routes — if WireGuard drops, all traffic is blocked
- **iptables MASQUERADE** NATs exit-node traffic through ProtonVPN

## Quick Start

### Prerequisites

- Docker and Docker Compose
- A [ProtonVPN](https://protonvpn.com) account (Plus or higher for WireGuard)
- A [Tailscale](https://tailscale.com) account

### 1. Clone and configure

```bash
git clone https://codeberg.org/richharvey/tailscale-proton-exit-node.git
cd tailscale-proton-exit-node
cp env.example .env
```

### 2. Get your ProtonVPN WireGuard config

1. Go to [ProtonVPN Downloads](https://account.protonvpn.com/downloads#wireguard-configuration)
2. Select your preferred **country**, **Secure Core**, **NetShield** level, and **VPN Accelerator**
3. Click **Generate** to create a WireGuard configuration
4. Copy the values into your `.env` file:

```
WG_PRIVATE_KEY=<PrivateKey from [Interface]>
WG_PEER_PUBLIC_KEY=<PublicKey from [Peer]>
WG_ENDPOINT=<Endpoint from [Peer]>
WG_ADDRESS=10.2.0.2/32
WG_DNS=10.2.0.1
```

> **Note:** Country, Secure Core, NetShield, and VPN Accelerator are configured when you generate the WireGuard key on ProtonVPN's dashboard. To change them, generate a new config and update the `WG_*` values.

### 3. Get your Tailscale auth key

1. Go to [Tailscale Admin - Keys](https://login.tailscale.com/admin/settings/keys)
2. Generate a new auth key
3. Add it to `.env`:

```
TS_AUTHKEY=tskey-auth-xxxxx
TS_HOSTNAME=proton-exit
```

### 4. Start the container

```bash
docker compose up -d
```

### 5. Approve the exit node

1. Go to [Tailscale Machines](https://login.tailscale.com/admin/machines)
2. Find your machine (named whatever you set `TS_HOSTNAME` to)
3. Click **Edit route settings** and enable **Use as exit node**

### 6. Connect a device

On any device in your tailnet:

```bash
tailscale set --exit-node=proton-exit
```

## Configuration

All settings are in `.env`. See `env.example` for full documentation.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `WG_PRIVATE_KEY` | Yes | | Your ProtonVPN WireGuard private key |
| `WG_PEER_PUBLIC_KEY` | Yes | | ProtonVPN server's public key |
| `WG_ENDPOINT` | Yes | | ProtonVPN server endpoint (ip:port) |
| `WG_ADDRESS` | No | `10.2.0.2/32` | WireGuard interface address |
| `WG_DNS` | No | `10.2.0.1` | DNS server (ProtonVPN internal) |
| `KILL_SWITCH` | No | `true` | Block all traffic if VPN drops |
| `TS_AUTHKEY` | Yes | | Tailscale auth key |
| `TS_HOSTNAME` | No | `proton-exit` | Machine name in Tailscale |
| `TS_EXTRA_ARGS` | No | | Extra `tailscale up` flags |

## Kill Switch

When `KILL_SWITCH=true` (the default), prohibit routes are installed at metric 900 in the WireGuard routing table. If the VPN tunnel drops:

- Normal VPN routes (metric 500) disappear
- Prohibit routes (metric 900) take over and block all public internet traffic
- LAN (RFC-1918), Tailscale (100.64.0.0/10), and link-local addresses remain reachable

This is the same approach used by [protonwire](https://github.com/tprasadtp/protonwire).

## Verifying

Check the container is working:

```bash
# View container logs
docker compose logs -f

# Check WireGuard status
docker compose exec tailscale-proton wg show

# Verify your exit IP is ProtonVPN's
docker compose exec tailscale-proton curl -s https://icanhazip.com/

# Check Tailscale status
docker compose exec tailscale-proton tailscale status
```

## Systemd Services

The container runs systemd as PID 1 with these services:

| Service | Type | Purpose |
|---------|------|---------|
| `wg-config` | oneshot | Generates WireGuard `.netdev`/`.network` files from env vars |
| `systemd-networkd` | system | Creates and manages the `proton0` WireGuard interface |
| `kill-switch` | oneshot | Installs prohibit routes (conditional on `KILL_SWITCH=true`) |
| `tailscaled` | daemon | Tailscale daemon |
| `ts-configure` | oneshot | Sets up iptables NAT, runs `tailscale up --advertise-exit-node` |

Boot order: `wg-config` → `systemd-networkd` → `kill-switch` → `tailscaled` → `ts-configure`

## Switching Servers

To change ProtonVPN server (country, Secure Core, etc.):

1. Generate a new WireGuard config on the ProtonVPN dashboard
2. Update `WG_PRIVATE_KEY`, `WG_PEER_PUBLIC_KEY`, and `WG_ENDPOINT` in `.env`
3. Restart: `docker compose restart`

## License

MIT
