#!/usr/bin/env bash
#
# Remnawave node — server-side torrent blocking setup
#
# curl -fsSL https://raw.githubusercontent.com/pidarasovichpidaras2-a11y/torrent-blocker/main/install.sh | bash
#
set -euo pipefail

INSTALL_DIR="/opt/remnanode"
LOG_DIR="/var/log/remnanode"
TBLOCKER_DIR="/opt/tblocker"
SKIP_TBLOCKER=false
SKIP_EGRESS=false

log()  { printf '[torrent-block] %s\n' "$*"; }
warn() { printf '[torrent-block] WARN: %s\n' "$*" >&2; }
die()  { printf '[torrent-block] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Remnawave node — server-side torrent blocking setup

Usage:
  curl -fsSL https://raw.githubusercontent.com/pidarasovichpidaras2-a11y/torrent-blocker/v1.0.3/install.sh | bash

  # If remnanode not in default paths:
  REMNANODE_DIR=/path/to/remnanode curl -fsSL .../install.sh | bash
  bash install.sh [--skip-tblocker] [--skip-egress]

Server setup only. Panel (plugin + routing rules) must be configured separately.
EOF
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --skip-tblocker) SKIP_TBLOCKER=true ;;
    --skip-egress)   SKIP_EGRESS=true ;;
    -h|--help)       usage ;;
  esac
done

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"
}

find_docker() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return 0
  fi
  for p in /usr/bin/docker /usr/local/bin/docker /snap/bin/docker; do
    if [[ -x "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

find_compose_files() {
  local dir
  for dir in /opt /root /home /srv ${REMNANODE_DIR:+$REMNANODE_DIR}; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 4 -name 'docker-compose.yml' 2>/dev/null
  done | sort -u
}

check_prerequisites() {
  log "Checking prerequisites..."

  DOCKER_BIN="$(find_docker || true)"
  if [[ -z "$DOCKER_BIN" ]]; then
    warn "docker CLI not found in PATH"
    warn "If remnanode runs in docker, install: curl -fsSL https://get.docker.com | sh"
  else
    log "docker: $DOCKER_BIN"
    if ! "$DOCKER_BIN" ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'remnanode|remna'; then
      warn "No running remnanode container visible"
    else
      log "remnanode container: OK ($("$DOCKER_BIN" ps --format '{{.Names}}' | grep -iE 'remnanode|remna' | tr '\n' ' '))"
    fi
  fi

  if ! command -v nft >/dev/null 2>&1; then
    log "Installing nftables..."
    apt-get update -qq && apt-get install -y -qq nftables
  fi
}

setup_log_directory() {
  log "Setting up $LOG_DIR ..."
  mkdir -p "$LOG_DIR"
  touch "$LOG_DIR/access.log" "$LOG_DIR/error.log"
  chmod 755 "$LOG_DIR"
  chmod 644 "$LOG_DIR"/*.log
}

setup_logrotate() {
  log "Installing logrotate..."
  cat > /etc/logrotate.d/remnanode <<'EOF'
/var/log/remnanode/*.log {
    su root root
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
}

patch_docker_compose_files() {
  log "Patching docker-compose (log volume)..."
  local patched=0 compose found=0
  while IFS= read -r compose; do
    [[ -f "$compose" ]] || continue
    found=$((found + 1))
    grep -qE 'remnawave/node|remnanode' "$compose" 2>/dev/null || continue
    if grep -q '/var/log/remnanode:/var/log/remnanode' "$compose"; then
      log "  OK (volume exists): $compose"
      continue
    fi
    if grep -q '^[[:space:]]*volumes:' "$compose"; then
      sed -i '/^[[:space:]]*volumes:/a\      - "/var/log/remnanode:/var/log/remnanode"' "$compose"
    elif grep -q '^[[:space:]]*cap_add:' "$compose"; then
      sed -i '/^[[:space:]]*cap_add:/i\    volumes:\n      - "/var/log/remnanode:/var/log/remnanode"' "$compose"
    elif grep -q '^[[:space:]]*environment:' "$compose"; then
      sed -i '/^[[:space:]]*environment:/i\    volumes:\n      - "/var/log/remnanode:/var/log/remnanode"' "$compose"
    else
      warn "  Manual patch needed: $compose"
      continue
    fi
    log "  Patched: $compose"
    patched=$((patched + 1))
  done < <(find_compose_files)

  if [[ "$found" -eq 0 ]]; then
    warn "No docker-compose.yml found in /opt /root /home /srv"
    warn "Set path manually: REMNANODE_DIR=/path/to/remnanode bash install.sh"
  fi

  if [[ "$patched" -gt 0 ]]; then
    log "Restart containers after install:"
    find_compose_files | while read -r c; do
      grep -qE 'remnawave/node|remnanode' "$c" 2>/dev/null && echo "  cd $(dirname "$c") && docker compose up -d"
    done
  fi
}

install_tblocker_package() {
  apt-get update -qq
  apt-get install -y -qq curl gnupg ca-certificates
  if [[ ! -f /etc/apt/sources.list.d/openrepo-xray-tools.list ]]; then
    curl -fsSL https://repo.remna.dev/xray-tools/public.gpg \
      | gpg --yes --dearmor -o /usr/share/keyrings/openrepo-xray-tools.gpg
    echo "deb [arch=any signed-by=/usr/share/keyrings/openrepo-xray-tools.gpg] https://repo.remna.dev/xray-tools/ stable main" \
      > /etc/apt/sources.list.d/openrepo-xray-tools.list
  fi
  apt-get update -qq
  apt-get install -y -qq tblocker
}

install_tblocker() {
  [[ "$SKIP_TBLOCKER" == true ]] && { log "Skipping tblocker"; return 0; }
  if dpkg -l tblocker >/dev/null 2>&1; then
    log "tblocker already installed"
  else
    log "Installing tblocker (non-interactive)..."
    install_tblocker_package
  fi
  mkdir -p "$TBLOCKER_DIR"
  cat > "$TBLOCKER_DIR/config.yaml" <<'EOF'
LogFile: "/var/log/remnanode/access.log"
BlockDuration: 1440
TorrentTag: "TORRENT"
BlockMode: "nft"
EOF
  systemctl enable tblocker 2>/dev/null || true
  if systemctl restart tblocker 2>/dev/null; then
    log "tblocker: $(systemctl is-active tblocker)"
  else
    warn "tblocker installed but not running yet (normal before remnanode is up)"
  fi
}

install_egress_filter() {
  [[ "$SKIP_EGRESS" == true ]] && { log "Skipping egress backup (--skip-egress)"; return 0; }
  mkdir -p "$INSTALL_DIR"
  cat > "$INSTALL_DIR/apply-torrent-egress-filter.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
PORTS=(6881 6882 6883 6884 6885 6886 6887 6888 6889 51413 21413 17417 37305)
apply() {
  local f=$1 t=$2 s=$3
  nft list table "$f" "$t" >/dev/null 2>&1 || return 0
  local e=()
  for p in "${PORTS[@]}"; do e+=("tcp . $p" "udp . $p"); done
  nft add element "$f" "$t" "$s" "{ $(printf '%s, ' "${e[@]}") }" 2>/dev/null || true
}
apply ip remnanode egress-filter-port
apply ip6 remnanode6 egress-filter-port6
SCRIPT
  chmod +x "$INSTALL_DIR/apply-torrent-egress-filter.sh"
  cat > /etc/systemd/system/torrent-egress-filter.service <<EOF
[Unit]
Description=Apply torrent egress port blocking
After=network-online.target docker.service
[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/apply-torrent-egress-filter.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/torrent-egress-filter.timer <<'EOF'
[Unit]
Description=Re-apply torrent egress port blocking
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now torrent-egress-filter.service torrent-egress-filter.timer
}

install_helper_files() {
  mkdir -p "$INSTALL_DIR"
  [[ -f "$INSTALL_DIR/panel-torrent-block-config.json" ]] && return 0
  cat > "$INSTALL_DIR/panel-torrent-block-config.json" <<'EOF'
{
  "routingRulesToAdd": [
    {"type": "field", "port": "6881-6889,51413,21413,17417,37305", "ruleTag": "TORRENT_BY_PORT", "outboundTag": "BLOCK"},
    {"type": "field", "domain": ["geosite:category-public-tracker"], "ruleTag": "TORRENT_BY_DOMAIN", "outboundTag": "BLOCK"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "TORRENT"}
  ],
  "nodePluginConfig": {
    "torrentBlocker": {
      "enabled": true,
      "ignoreLists": {"ip": [], "userId": []},
      "blockDuration": 86400,
      "includeRuleTags": ["TORRENT_BY_PORT", "TORRENT_BY_DOMAIN"]
    },
    "egressFilter": {
      "enabled": true,
      "blockedPorts": [6881,6882,6883,6884,6885,6886,6887,6888,6889,51413,21413,17417,37305]
    }
  }
}
EOF
}

print_done() {
  cat <<'EOF'

Server setup complete.

If remnanode is not installed yet:
  1. Install docker:  curl -fsSL https://get.docker.com | sh
  2. Install remnanode (Remnawave node installer)
  3. Re-run this script OR restart containers:
       cd /opt/remnanode && docker compose up -d

Panel (manual):
  1. Enable Torrent Blocker + Egress Filter plugins
  2. Add routing rules: TORRENT_BY_PORT, TORRENT_BY_DOMAIN
  3. Enable logging -> /var/log/remnanode/access.log
  4. Enable sniffing on inbounds

Reference: /opt/remnanode/panel-torrent-block-config.json
EOF
}

main() {
  require_root
  check_prerequisites
  setup_log_directory
  setup_logrotate
  patch_docker_compose_files
  install_tblocker
  install_egress_filter
  install_helper_files
  print_done
  log "Done."
}

main "$@"
