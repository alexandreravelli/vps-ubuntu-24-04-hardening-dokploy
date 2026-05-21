#!/bin/bash
# Allow one public Docker port through UFW + DOCKER-USER.
# Usage: sudo ./allow-docker-port.sh 51820/udp wg-easy

set -euo pipefail

VERSION="1.0.16"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "Docker Public Port Allowlist v$VERSION"
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
  sudo ./allow-docker-port.sh <port>/<tcp|udp> [label]

Example:
  sudo ./allow-docker-port.sh 51820/udp wg-easy

This opens the port in UFW, persists it in:
  /etc/vps-hardening/docker-public-ports.conf

Then it rebuilds and restarts:
  /usr/local/bin/docker-firewall.sh
  docker-firewall.service
USAGE
}

PORT_PROTO="${1:-}"
LABEL="${2:-custom}"

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

if [ "$PORT_PROTO" = "3000/tcp" ]; then
    echo "[ERROR] 3000/tcp is the temporary Dokploy setup port."
    echo "        Do not make it persistent. Close it after domain + HTTPS setup."
    exit 1
fi

if ! echo "$LABEL" | grep -qE '^[A-Za-z0-9_.-]+$'; then
    echo "[ERROR] Invalid label: $LABEL"
    echo "        Use letters, numbers, dots, underscores, or hyphens only."
    exit 1
fi

CONFIG_DIR="/etc/vps-hardening"
CONFIG_FILE="$CONFIG_DIR/docker-public-ports.conf"
FIREWALL_SCRIPT="/usr/local/bin/docker-firewall.sh"
SERVICE_FILE="/etc/systemd/system/docker-firewall.service"

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

ensure_port() {
    local port_proto="$1"
    local label="$2"

    if ! grep -qE "^${port_proto}[[:space:]]" "$CONFIG_FILE"; then
        printf '%s %s\n' "$port_proto" "$label" >> "$CONFIG_FILE"
    fi
}

ensure_port "80/tcp" "web-http"
ensure_port "443/tcp" "web-https"
ensure_port "$PORT_PROTO" "$LABEL"

# Remove duplicate port entries while preserving the last chosen label.
awk '
    NF >= 1 {
        ports[$1] = $2
        order[++count] = $1
    }
    END {
        for (i = 1; i <= count; i++) {
            port = order[i]
            if (!seen[port]++) {
                unique[++unique_count] = port
            }
        }
        for (i = 1; i <= unique_count; i++) {
            port = unique[i]
            print port, ports[port]
        }
    }
' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

ufw allow "$PORT_PROTO" > /dev/null
echo "[OK] UFW allows $PORT_PROTO"

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

echo "[OK] Docker public port persisted: $PORT_PROTO $LABEL"
echo "[OK] docker-firewall.service restarted"
echo ""
echo "Configured Docker public ports:"
cat "$CONFIG_FILE"
