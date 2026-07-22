FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd \
    wireguard-tools \
    iptables \
    iproute2 \
    curl \
    ca-certificates \
    gnupg \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Tailscale from official repo
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg && \
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && apt-get install -y --no-install-recommends tailscale && \
    rm -rf /var/lib/apt/lists/*

# Strip unnecessary systemd units for a lean container
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp*

# IP forwarding + loose reverse-path filtering for the asymmetric exit-node routing
# (packets enter via tailscale0, leave via proton0 — strict rp_filter would drop them)
RUN mkdir -p /etc/sysctl.d && \
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\nnet.ipv4.conf.all.rp_filter = 2\nnet.ipv4.conf.default.rp_filter = 2\n' \
      > /etc/sysctl.d/99-forwarding.conf

# Copy systemd units and scripts
COPY systemd/wg-config.service    /etc/systemd/system/wg-config.service
COPY systemd/wg-config.sh         /usr/local/bin/wg-config.sh
COPY systemd/ts-configure.service /etc/systemd/system/ts-configure.service
COPY systemd/ts-configure.sh      /usr/local/bin/ts-configure.sh
COPY systemd/kill-switch.service  /etc/systemd/system/kill-switch.service
COPY systemd/kill-switch.sh       /usr/local/bin/kill-switch.sh
COPY systemd/vpn-watchdog.service /etc/systemd/system/vpn-watchdog.service
COPY systemd/vpn-watchdog.timer   /etc/systemd/system/vpn-watchdog.timer
COPY systemd/vpn-watchdog.sh      /usr/local/bin/vpn-watchdog.sh
COPY healthcheck.sh               /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/wg-config.sh \
              /usr/local/bin/ts-configure.sh \
              /usr/local/bin/kill-switch.sh \
              /usr/local/bin/vpn-watchdog.sh \
              /usr/local/bin/healthcheck.sh

# Persistent journal (mount a volume at /var/log/journal to keep logs across
# container recreations — journald uses persistent storage when the dir exists)
RUN mkdir -p /var/log/journal

# Enable services
RUN systemctl enable tailscaled wg-config ts-configure kill-switch vpn-watchdog.timer

# Tailscale state persisted via volume
VOLUME /var/lib/tailscale

HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/lib/systemd/systemd"]
