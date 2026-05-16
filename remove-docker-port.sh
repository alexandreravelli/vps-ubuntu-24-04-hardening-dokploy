#!/bin/bash
# Remove one public Docker port from UFW + DOCKER-USER persistence.
# Usage: sudo ./remove-docker-port.sh 51820/udp

set -euo pipefail

VERSION="1.0.13"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "Docker Public Port Remover v$VERSION"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

usage() {
    cat <<'USAGE'
Usage:
  sudo ./remove-docker-port.sh <port>/<tcp|udp>

Example:
  sudo ./remove-docker-port.sh 51820/udp

This removes the port from UFW and from:
  /etc/vps-hardening/docker-public-ports.conf

Then it rebuilds and restarts:
  /usr/local/bin/docker-firewall.sh
  docker-firewall.service
USAGE
}

PORT_PROTO="${1:-}"

if [ -z "$PORT_PROTO" ] || [[ "$PORT_PROTO" == "--help" || "$PORT_PROTO" == "-h" ]]; then
    usage
    exit 0
fi

if ! echo "$PORT_PROTO" | grep -qE '^[0-9]+/(tcp|udp)$'; then
    echo "[ERROR] Invalid port format: $PORT_PROTO"
    echo "        Expected: 51820/udp or 8080/tcp"
    exit 1
fi

PORT="${PORT_PROTO%/*}"

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "[ERROR] Invalid port: $PORT"
    exit 1
fi

if [ "$PORT_PROTO" = "80/tcp" ] || [ "$PORT_PROTO" = "443/tcp" ]; then
    echo "[ERROR] Refusing to remove required web port: $PORT_PROTO"
    echo "        80/tcp and 443/tcp are managed as baseline Docker public ports."
    exit 1
fi

CONFIG_DIR="/etc/vps-hardening"
CONFIG_FILE="$CONFIG_DIR/docker-public-ports.conf"
FIREWALL_SCRIPT="/usr/local/bin/docker-firewall.sh"
SERVICE_FILE="/etc/systemd/system/docker-firewall.service"

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

if grep -qE "^${PORT_PROTO}([[:space:]]|$)" "$CONFIG_FILE"; then
    grep -vE "^${PORT_PROTO}([[:space:]]|$)" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "[OK] Removed $PORT_PROTO from $CONFIG_FILE"
else
    echo "[OK] $PORT_PROTO was not present in $CONFIG_FILE"
fi

# Keep baseline web ports present.
if ! grep -qE '^80/tcp[[:space:]]' "$CONFIG_FILE"; then
    printf '%s %s\n' "80/tcp" "web-http" >> "$CONFIG_FILE"
fi
if ! grep -qE '^443/tcp[[:space:]]' "$CONFIG_FILE"; then
    printf '%s %s\n' "443/tcp" "web-https" >> "$CONFIG_FILE"
fi

ufw delete allow "$PORT_PROTO" > /dev/null 2>&1 || true
echo "[OK] UFW allow removed for $PORT_PROTO"

cat > "$FIREWALL_SCRIPT" <<'FWSCRIPT'
#!/bin/bash
set -euo pipefail

CONFIG_FILE="/etc/vps-hardening/docker-public-ports.conf"

valid_port_proto() {
    echo "$1" | grep -qE '^[0-9]+/(tcp|udp)$'
}

allow_configured_ports() {
    local cmd="$1"
    [ -f "$CONFIG_FILE" ] || return 0

    while read -r port_proto _label; do
        [ -n "${port_proto:-}" ] || continue
        case "$port_proto" in \#*) continue ;; esac
        valid_port_proto "$port_proto" || continue

        local port="${port_proto%/*}"
        local proto="${port_proto#*/}"
        "$cmd" -A DOCKER-USER -p "$proto" --dport "$port" -j ACCEPT
    done < "$CONFIG_FILE"
}

iptables -L DOCKER-USER -n >/dev/null 2>&1 && {
    iptables -F DOCKER-USER
    iptables -A DOCKER-USER -s 172.16.0.0/12 -j ACCEPT
    iptables -A DOCKER-USER -s 10.0.0.0/8 -j ACCEPT
    iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A DOCKER-USER -i lo -j ACCEPT
    allow_configured_ports iptables
    iptables -A DOCKER-USER -j DROP
}

ip6tables -L DOCKER-USER -n >/dev/null 2>&1 && {
    ip6tables -F DOCKER-USER
    ip6tables -A DOCKER-USER -s fd00::/8 -j ACCEPT
    ip6tables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A DOCKER-USER -i lo -j ACCEPT
    allow_configured_ports ip6tables
    ip6tables -A DOCKER-USER -j DROP
}
FWSCRIPT

chmod 750 "$FIREWALL_SCRIPT"
bash -n "$FIREWALL_SCRIPT"

cat > "$SERVICE_FILE" <<'FWSERVICE'
[Unit]
Description=Docker DOCKER-USER firewall rules
After=docker.service
Requires=docker.service
BindsTo=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/docker-firewall.sh
ExecReload=/usr/local/bin/docker-firewall.sh

[Install]
WantedBy=multi-user.target
FWSERVICE

systemctl daemon-reload
systemctl enable docker-firewall > /dev/null
systemctl restart docker-firewall

echo "[OK] Docker public port removed: $PORT_PROTO"
echo "[OK] docker-firewall.service restarted"
echo ""
echo "Configured Docker public ports:"
cat "$CONFIG_FILE"
