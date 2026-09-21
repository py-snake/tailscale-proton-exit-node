#!/bin/sh
# Automated Cloudflare WARP registration with wgcf (ViRb3/wgcf, floating latest).
# Non-interactive: `wgcf register --accept-tos && wgcf generate`
# Produces: ./warp/wgcf-account.toml, ./warp/wgcf-profile.conf, ./warp/.env.warp
set -eu

WGCF_VERSION="${WGCF_VERSION:-latest}"

# Layouts (single source of truth: everything lives under OUT_DIR):
# - host (run from repo root): OUT_DIR=./warp, ENV_FILE=./warp/.env.warp
# - wgcf-init container (working_dir=/warp, ./warp mounted there):
#   OUT_DIR=/warp, ENV_FILE=/warp/.env.warp
if [ "$(pwd)" = "/warp" ]; then
  OUT_DIR="/warp"
else
  OUT_DIR="${OUT_DIR:-./warp}"
fi
ENV_FILE="${ENV_FILE:-${OUT_DIR}/.env.warp}"
mkdir -p "$OUT_DIR"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)   WGCF_ARCH="linux_amd64" ;;
  aarch64|arm64) WGCF_ARCH="linux_arm64" ;;
  armv7l)   WGCF_ARCH="linux_armv7" ;;
  *) echo "Unsupported arch: $ARCH (need x86_64/arm64/armv7)" >&2; exit 1 ;;
esac

if ! command -v wgcf >/dev/null 2>&1; then
  if [ -x "$OUT_DIR/wgcf" ]; then
    WGCF="$OUT_DIR/wgcf"
  else
    if [ "$WGCF_VERSION" = "latest" ]; then
      echo "[wgcf] resolving latest release tag..."
      if command -v curl >/dev/null 2>&1; then
        WGCF_VERSION="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | cut -d'"' -f4)"
      elif command -v wget >/dev/null 2>&1; then
        WGCF_VERSION="$(wget -qO- https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep '"tag_name"' | cut -d'"' -f4)"
      else
        echo "Need curl or wget to resolve wgcf latest version." >&2; exit 1
      fi
      echo "[wgcf] latest is $WGCF_VERSION"
      if [ -z "${WGCF_VERSION:-}" ]; then
        echo "ERROR: could not resolve latest wgcf release (GitHub API rate limit?) — set WGCF_VERSION=vX.Y.Z explicitly." >&2
        exit 1
      fi
    fi
    WGCF_BASENAME="wgcf_${WGCF_VERSION#v}_${WGCF_ARCH}"
    echo "[wgcf] downloading wgcf $WGCF_VERSION ($WGCF_ARCH)..."
    URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/${WGCF_BASENAME}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$OUT_DIR/wgcf" "$URL"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$OUT_DIR/wgcf" "$URL"
    else
      echo "Need curl or wget to fetch wgcf." >&2; exit 1
    fi
    chmod +x "$OUT_DIR/wgcf"
    WGCF="$OUT_DIR/wgcf"
    # Verify sha256 against the release checksums.txt (fail closed).
    if command -v sha256sum >/dev/null 2>&1; then
      SUM_URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/checksums.txt"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$OUT_DIR/checksums.txt" "$SUM_URL"
      else
        wget -qO "$OUT_DIR/checksums.txt" "$SUM_URL"
      fi
      EXPECTED="$(grep -F " ${WGCF_BASENAME}" "$OUT_DIR/checksums.txt" | awk '{print $1}' | head -1 || true)"
      ACTUAL="$(sha256sum "$OUT_DIR/wgcf" | awk '{print $1}')"
      if [ -z "${EXPECTED:-}" ]; then
        echo "WARN: no checksum entry for $WGCF_BASENAME — skipping verification." >&2
      elif [ "$EXPECTED" = "$ACTUAL" ]; then
        echo "[wgcf] sha256 verified."
      else
        echo "ERROR: sha256 mismatch for $WGCF_BASENAME, refusing to run it." >&2
        exit 1
      fi
    else
      echo "WARN: sha256sum unavailable — skipping binary verification." >&2
    fi
  fi
else
  WGCF="wgcf"
fi

cd "$OUT_DIR"
if [ ! -f wgcf-account.toml ]; then
  echo "[wgcf] registering new WARP account (accept-tos, non-interactive)..."
  "$WGCF" register --accept-tos
else
  echo "[wgcf] reusing existing wgcf-account.toml"
fi

echo "[wgcf] generating WireGuard profile..."
"$WGCF" generate
# Keep NAT mappings alive. NOTE: this file is only used for manual WireGuard
# setups — Gluetun reads values from warp/.env.warp and takes its keepalive from
# WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL in docker-compose.yml.
# (Appending at EOF is safe: wgcf always ends the profile with [Peer].)
grep -q PersistentKeepalive wgcf-profile.conf || echo "PersistentKeepalive = 25" >> wgcf-profile.conf

# Parse wgcf-profile.conf -> warp/.env.warp for Gluetun custom provider.
# (Current var names per gluetun-wiki setup/providers/custom.md; the
# VPN_ENDPOINT_* form from passtque/gluetun#1738 is kept as legacy alias.)
# NOTE: base64 keys contain '=' (trailing padding), so `cut -d= -f2` would
# truncate them — extract everything after the first ' = ' separator instead.
getval() {
  sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" wgcf-profile.conf | head -1
}
PRIVKEY="$(getval 'PrivateKey' | tr -d ' \r')"
PUBKEY="$(getval 'PublicKey' | tr -d ' \r')"
ADDRS="$(getval 'Address' | tr -d ' \r')"
ENDPOINT="$(getval 'Endpoint' | tr -d ' \r')"
DNS="$(getval 'DNS' | tr -d ' \r')"
ENDPOINT_HOST="${ENDPOINT%:*}"
ENDPOINT_PORT="${ENDPOINT##*:}"
# Strip IPv6 brackets in case the profile ever returns [2620:...]:port
ENDPOINT_HOST="$(printf '%s' "$ENDPOINT_HOST" | tr -d '[]')"

# WIREGUARD_ENDPOINT_IP MUST be a literal IP — Gluetun does not accept
# hostnames there (gluetun#2680). Resolve engage.cloudflareclient.com now
# and fail loudly if no resolver is available.
RESOLVED=""
if command -v getent >/dev/null 2>&1; then
  RESOLVED="$(getent ahostsv4 "$ENDPOINT_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)"
fi
if [ -z "${RESOLVED:-}" ] && command -v nslookup >/dev/null 2>&1; then
  # busybox nslookup prints the resolver's own IP first, answers last
  RESOLVED="$(nslookup "$ENDPOINT_HOST" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -n 1 || true)"
fi
if [ -n "${RESOLVED:-}" ]; then
  ENDPOINT_HOST="$RESOLVED"
elif ! echo "$ENDPOINT_HOST" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "ERROR: could not resolve $ENDPOINT_HOST to IPv4 (install getent or bind-tools/nslookup) and Gluetun needs a literal IP." >&2
  exit 1
fi

cat > "$ENV_FILE" <<EOF
# AUTO-GENERATED by register-warp.sh from wgcf-profile.conf — do not hand-edit.
# Current names per gluetun-wiki setup/providers/custom.md; VPN_ENDPOINT_* are
# legacy aliases kept for older Gluetun images (ignored if unknown).
# Keep this file chmod 600 — it holds the WireGuard private key.
WIREGUARD_ENDPOINT_IP=$ENDPOINT_HOST
WIREGUARD_ENDPOINT_PORT=$ENDPOINT_PORT
VPN_ENDPOINT_IP=$ENDPOINT_HOST
VPN_ENDPOINT_PORT=$ENDPOINT_PORT
WIREGUARD_PUBLIC_KEY=$PUBKEY
WIREGUARD_PRIVATE_KEY=$PRIVKEY
WIREGUARD_ADDRESSES=$ADDRS
EOF
chmod 600 "$ENV_FILE" || true

echo "[wgcf] wrote $ENV_FILE:"
cat "$ENV_FILE"
echo "[wgcf] done. DNS from profile was: ${DNS:-1.1.1.1} (ignored — Gluetun resolves via DNS-over-TLS per compose)."
