# Remnawave torrent block — server installer

One-command server setup for blocking torrents on Remnawave/Xray nodes.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/pidarasovichpidaras2-a11y/torrent-blocker/v1.0.3/install.sh | bash

# if remnanode is in a custom folder:
REMNANODE_DIR=/path/to/remnanode curl -fsSL .../v1.0.3/install.sh | bash
```

## What it installs

- `/var/log/remnanode` + logrotate
- [tblocker](https://github.com/kutovoys/xray-torrent-blocker) (24h IP ban via nftables)
- Egress filter backup (torrent ports in nftables, if remnanode table exists)
- Docker compose log volume patch (`/opt/*/docker-compose.yml`)
- Reference config: `/opt/remnanode/panel-torrent-block-config.json`

## Options

```bash
curl -fsSL .../install.sh | bash -s -- --skip-tblocker
curl -fsSL .../install.sh | bash -s -- --skip-egress
```

## After install — Remnawave Panel

1. **Plugins**: Torrent Blocker + Egress Filter (`blockDuration: 86400`, `includeRuleTags`)
2. **Config Profile**: routing rules for ports 6881+, public trackers, bittorrent → TORRENT
3. **Logging**: `access.log` / `error.log` → `/var/log/remnanode/`
4. **Sniffing** on inbounds: http, tls, quic

See `panel-torrent-block-config.json` for reference.

## Requirements

- Linux, root
- Docker + remnanode container
- nftables (`apt install nftables`)
- `cap_add: NET_ADMIN` in docker-compose
