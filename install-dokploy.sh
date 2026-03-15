#!/bin/bash
# Docker + Dokploy Installer
# Run this AFTER setup.sh has completed hardening.
# Usage: sudo bash install-dokploy.sh
#
# This script:
#   1. Installs Docker (official APT repo + GPG)
#   2. Configures Docker log rotation + Content Trust
#   3. Initializes Docker Swarm (required for Traefik/Dokploy)
#   4. Sets up DOCKER-USER firewall (deny-by-default)
#   5. Installs Dokploy
#   6. Re-verifies firewall + SSH after Dokploy install

set -euo pipefail

VERSION="4.0.0"

# === ROOT CHECK ===
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

# === LOAD CONFIG FROM SETUP.SH ===
CONFIG_FILE="/root/.vps_hardening_config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config file not found at $CONFIG_FILE"
    echo "        Run setup.sh first to harden the server."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate required variables
for var in SSH_PORT NEW_USER LOG_DAYS; do
    if [ -z "${!var:-}" ]; then
        echo "[ERROR] Missing $var in $CONFIG_FILE -- run setup.sh first"
        exit 1
    fi
done

LOG_FILE="/var/log/vps_setup.log"
TOTAL_STEPS=3
CURRENT_STEP=0

# === CLEANUP TRAP ===
SETUP_PHASE="init"
cleanup_on_error() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo ""
        printf "  \033[1;31m──────────────────────────────────────────────\033[0m\n"
        printf "  \033[1;31m[ERROR] INSTALL FAILED during phase: %s\033[0m\n" "$SETUP_PHASE"
        printf "  Check the log: %s\n" "$LOG_FILE"
        printf "  \033[1;31m──────────────────────────────────────────────\033[0m\n"

        # Restore SSH access if we broke something
        echo ""
        printf "  \033[1;33m[!] Verifying SSH is still accessible...\033[0m\n"
        if [ -f /run/sshd-hardened.pid ] && kill -0 "$(cat /run/sshd-hardened.pid)" 2>/dev/null; then
            printf "  \033[1;32m[OK] Standalone sshd still running on port %s\033[0m\n" "$SSH_PORT"
        elif systemctl is-active ssh.service &>/dev/null; then
            printf "  \033[1;32m[OK] ssh.service is active\033[0m\n"
        else
            printf "  \033[1;33m[!] Restarting SSH service...\033[0m\n"
            sudo systemctl start ssh.service 2>/dev/null || true
        fi

        # Re-apply UFW in case Dokploy broke it
        if command -v ufw &>/dev/null; then
            sudo ufw allow "$SSH_PORT/tcp" 2>/dev/null || true
        fi
    fi
}
trap cleanup_on_error EXIT
trap '' HUP PIPE

# === UI FUNCTIONS ===

if ! command -v gum &>/dev/null; then
    echo "[ERROR] gum not found. Run setup.sh first."
    exit 1
fi

progress_bar() {
    tty -s 2>/dev/null || return 0
    local current=$1
    local total=$2
    local label="$3"
    local filled=$((current * 20 / total))
    local empty=$((20 - filled))
    local bar
    bar="$(printf '%*s' "$filled" '' | tr ' ' '=')$(printf '%*s' "$empty" '' | tr ' ' ' ')"
    echo ""
    printf "  \033[0;90m──────────────────────────────────────────────\033[0m\n"
    echo ""
    printf "  [\033[0;32m%s\033[0m] \033[1;34mStep %s/%s\033[0m -- %s\n" "$bar" "$current" "$total" "$label"
    echo ""
}

run_with_spinner() {
    local label="$1"
    shift
    sudo -v 2>/dev/null || true
    if tty -s 2>/dev/null; then
        gum spin --spinner dot --title "$label" -- "$@"
    else
        "$@" > /dev/null 2>&1
    fi
}

run_with_log() {
    local label="$1"
    shift
    sudo -v 2>/dev/null || true
    printf "  \033[1;34m>> %s\033[0m\n" "$label"
    local tmpfile
    tmpfile=$(mktemp) || { echo "Failed to create temp file"; return 1; }
    "$@" > "$tmpfile" 2>&1 &
    local pid=$!
    tail -f "$tmpfile" 2>/dev/null | while IFS= read -r line; do
        printf "  \033[0;90m   %s\033[0m\n" "$line"
    done &
    local tail_pid=$!
    wait "$pid"
    local exit_code=$?
    sleep 1
    kill "$tail_pid" 2>/dev/null; wait "$tail_pid" 2>/dev/null || true
    rm -f "$tmpfile"
    return "$exit_code"
}

log() {
    if tty -s 2>/dev/null; then
        gum style --foreground 2 "  [OK] $1" 2>/dev/null || true
        echo "" 2>/dev/null || true
    fi
    echo "[OK] $(date +%H:%M:%S) $1" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    if tty -s 2>/dev/null; then
        gum style --foreground 3 "  [!] $1" 2>/dev/null || true
    fi
    echo "[WARN] $(date +%H:%M:%S) $1" >> "$LOG_FILE" 2>/dev/null || true
}

error() {
    if tty -s 2>/dev/null; then
        gum style --foreground 1 --bold "  [X] $1" 2>/dev/null || true
    fi
    echo "[ERROR] $(date +%H:%M:%S) $1" >> "$LOG_FILE" 2>/dev/null || true
    exit 1
}

# === WELCOME ===
clear 2>/dev/null || true

gum style \
    --border double \
    --border-foreground 4 \
    --padding "1 6" \
    --margin "1 2" \
    --bold \
    --align center \
    "DOCKER + DOKPLOY INSTALLER" \
    "" \
    "~5 min  ·  3 steps"

echo ""
gum style --bold --foreground 6 "  WHAT IT DOES"
gum style --foreground 240 "  ────────────────────────────────────────────────"
echo ""
printf "  $(gum style --foreground 240 '1')  Docker: official APT repo + GPG + Swarm + log rotation\n"
printf "  $(gum style --foreground 240 '2')  Firewall: DOCKER-USER deny-by-default + allow 80/443/3000\n"
printf "  $(gum style --foreground 240 '3')  Dokploy: self-hosted PaaS at port 3000\n"
echo ""

gum style \
    --border rounded \
    --border-foreground 3 \
    --foreground 3 \
    --padding "0 2" \
    --margin "0 2" \
    "⚠  If you have an external firewall, open port 3000 before continuing." \
    "   Port 3000 is temporary — close it after configuring SSL in Dokploy."

echo ""

gum confirm "Ready to install Docker + Dokploy?" || { echo "Install cancelled."; exit 0; }

START_TIME=$SECONDS
echo "=== Docker + Dokploy Install - $(date) ===" >> "$LOG_FILE"

# === STEP 1: INSTALL DOCKER ===
CURRENT_STEP=1
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Install Docker (~2-3 min)"
SETUP_PHASE="docker"

run_with_spinner "Installing Docker prerequisites" sudo apt-get install -y -qq ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

run_with_spinner "Updating Docker repository" sudo apt-get update -qq
run_with_log "Installing Docker Engine" sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$NEW_USER"
echo 'export DOCKER_CONTENT_TRUST=1' | sudo tee /etc/profile.d/docker-content-trust.sh > /dev/null
log "Docker installed (official APT repo with GPG, content trust enabled)"

sudo mkdir -p /etc/docker
if [ "$LOG_DAYS" -le 90 ]; then
    DOCKER_MAX_FILE=3
elif [ "$LOG_DAYS" -le 365 ]; then
    DOCKER_MAX_FILE=7
else
    DOCKER_MAX_FILE=14
fi
sudo tee /etc/docker/daemon.json > /dev/null << EOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "$DOCKER_MAX_FILE"},
  "no-new-privileges": true
}
EOF
sudo systemctl restart docker
log "Docker log rotation configured"

# Initialize Docker Swarm (required for Dokploy/Traefik)
if ! sudo docker info 2>/dev/null | grep -q "Swarm: active"; then
    SWARM_ADDR=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1 || true)
    [ -n "$SWARM_ADDR" ] || error "Could not determine local IP for Docker Swarm -- check network connectivity"
    run_with_spinner "Initializing Docker Swarm" sudo docker swarm init --advertise-addr "$SWARM_ADDR"
    log "Docker Swarm initialized (required for Traefik)"
else
    log "Docker Swarm already active"
fi

# === STEP 2: DOCKER-USER FIREWALL ===
CURRENT_STEP=2
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Configure Docker firewall"
SETUP_PHASE="docker-firewall"

sudo tee /usr/local/bin/docker-firewall.sh > /dev/null << 'FWSCRIPT'
#!/bin/bash
# Persistent DOCKER-USER rules — re-applied after Docker starts on each boot.
# Port 3000 (Dokploy UI) is NOT included here: it is opened temporarily during
# initial setup and should be closed manually after SSL is configured.
for cmd in iptables ip6tables; do
    $cmd -L DOCKER-USER -n &>/dev/null 2>&1 || continue
    $cmd -F DOCKER-USER
    $cmd -I DOCKER-USER -j DROP
    $cmd -I DOCKER-USER -p tcp --dport 443 -j ACCEPT
    $cmd -I DOCKER-USER -p tcp --dport 80 -j ACCEPT
    $cmd -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $cmd -I DOCKER-USER -i lo -j ACCEPT
done
# Allow Docker bridge networks (172.16.0.0/12) + overlay/Swarm networks (10.0.0.0/8)
iptables -I DOCKER-USER -s 172.16.0.0/12 -j ACCEPT
iptables -I DOCKER-USER -s 10.0.0.0/8 -j ACCEPT
FWSCRIPT
sudo chmod 750 /usr/local/bin/docker-firewall.sh

sudo tee /etc/systemd/system/docker-firewall.service > /dev/null << 'FWSERVICE'
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

sudo systemctl daemon-reload
sudo systemctl enable docker-firewall
run_with_spinner "Configuring DOCKER-USER firewall rules" sudo systemctl start docker-firewall

# Temporary port 3000 (not in the persistent service — dies on next Docker restart)
sudo iptables -I DOCKER-USER -p tcp --dport 3000 -j ACCEPT
sudo ip6tables -I DOCKER-USER -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
log "Docker firewall configured (DOCKER-USER: deny-by-default, allow 80, 443, 3000)"

# === STEP 3: INSTALL DOKPLOY ===
CURRENT_STEP=3
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Install Dokploy (~2-5 min)"
SETUP_PHASE="dokploy"

# Pre-install iptables-persistent BEFORE Dokploy so its installer finds it
# already present and skips the install (which would otherwise flush all rules
# and conflict with UFW).
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo apt-get install -y -qq iptables-persistent > /dev/null 2>&1
sudo apt-mark hold ufw > /dev/null 2>&1 || true
log "Pre-installed iptables-persistent (prevents Dokploy from flushing rules)"

run_with_spinner "Installing Dokploy (~2-5 min)" bash -c 'curl -sSL https://dokploy.com/install.sh | sh'
log "Dokploy installed"

sudo apt-mark unhold ufw > /dev/null 2>&1 || true

# === POST-DOKPLOY RECOVERY ===
# Dokploy's install script can break things. Fix everything it might have touched.
SETUP_PHASE="post-dokploy-recovery"

# 1. Reinstall UFW if Dokploy removed it
if ! dpkg -l ufw 2>/dev/null | grep -q "^ii"; then
    run_with_spinner "Reinstalling UFW (removed by Dokploy)" sudo apt-get install -y -qq ufw
fi

# 2. Re-apply UFW rules
sudo ufw --force reset > /dev/null
sudo ufw default deny incoming > /dev/null
sudo ufw default allow outgoing > /dev/null
sudo ufw allow "$SSH_PORT/tcp" > /dev/null
sudo ufw limit "$SSH_PORT/tcp" > /dev/null
sudo ufw allow 80/tcp > /dev/null
sudo ufw allow 443/tcp > /dev/null
sudo ufw allow 3000/tcp > /dev/null
sudo ufw --force enable > /dev/null
log "UFW rules reconfigured after Dokploy"

# 3. Re-apply needrestart SSH protection
sudo mkdir -p /etc/needrestart/conf.d
sudo tee /etc/needrestart/conf.d/99-no-ssh-restart.conf > /dev/null << 'NEEDRESTART'
$nrconf{override_rc}{q(ssh)} = 0;
$nrconf{override_rc}{q(sshd)} = 0;
NEEDRESTART

# 4. Re-apply DOCKER-USER rules
run_with_spinner "Re-applying DOCKER-USER firewall rules" sudo systemctl restart docker-firewall
sudo iptables -I DOCKER-USER -p tcp --dport 3000 -j ACCEPT
sudo ip6tables -I DOCKER-USER -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true

# 5. Verify sshd is still alive — this is the bug that caused ECONNRESET
if [ -f /run/sshd-hardened.pid ] && ! kill -0 "$(cat /run/sshd-hardened.pid)" 2>/dev/null; then
    warn "Standalone sshd died during Dokploy install — restarting on port $SSH_PORT"
    sudo /usr/sbin/sshd -p "$SSH_PORT" -o "PidFile=/run/sshd-hardened.pid"
    log "Standalone sshd restarted on port $SSH_PORT"
elif ! [ -f /run/sshd-hardened.pid ] && ! systemctl is-active ssh.service &>/dev/null; then
    warn "No sshd running — starting ssh.service"
    sudo systemctl start ssh.service
    log "ssh.service started as fallback"
fi

log "Post-Dokploy recovery complete — all services verified"

# Wait for Dokploy to be ready
gum spin --spinner dot --title "Waiting for Dokploy to start..." -- bash -c '
for i in $(seq 1 30); do
    curl -s http://localhost:3000 &>/dev/null && exit 0
    sleep 2
done
exit 1
' && log "Dokploy is running" || warn "Dokploy did not respond within 60s -- it may still be starting"

# === FINAL SUMMARY ===
PUBLIC_IP=$(curl -s --max-time 10 -4 ifconfig.me 2>/dev/null || \
            curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
            echo "YOUR_SERVER_IP")

if echo "$PUBLIC_IP" | grep -q ":"; then
    SSH_HOST="[$PUBLIC_IP]"
else
    SSH_HOST="$PUBLIC_IP"
fi

USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)

# Update summary file
if [ -n "$USER_HOME" ] && [ -f "$USER_HOME/.vps_setup_summary" ]; then
    if ! grep -q "DOKPLOY_URL" "$USER_HOME/.vps_setup_summary"; then
        echo "DOKPLOY_URL=http://$PUBLIC_IP:3000" | sudo tee -a "$USER_HOME/.vps_setup_summary" > /dev/null
    fi
fi

echo ""

ELAPSED=$(( SECONDS - START_TIME ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

gum style \
    --border double \
    --border-foreground 2 \
    --padding "1 4" \
    --margin "0 2" \
    --bold \
    --align center \
    "DOKPLOY READY  (${ELAPSED_MIN}m ${ELAPSED_SEC}s)"

echo ""
gum style --bold --foreground 2 "  ACCESS"
gum style --foreground 240 "  ──────────────────────────────────────────────────"
printf "  $(gum style --bold 'SSH')      ssh %s@%s -p %s\n" "$NEW_USER" "$SSH_HOST" "$SSH_PORT"
printf "  $(gum style --bold 'Dokploy')  http://%s:3000\n" "$PUBLIC_IP"
echo ""
gum style --bold --foreground 2 "  NEXT STEPS"
gum style --foreground 240 "  ──────────────────────────────────────────────────"
printf "  $(gum style --bold --foreground 6 '1')  Open http://%s:3000 and create your admin account\n" "$PUBLIC_IP"
printf "  $(gum style --bold --foreground 6 '2')  Configure a domain + SSL in Dokploy\n"
printf "  $(gum style --bold --foreground 6 '3')  Close port 3000 after SSL is configured:\n"
printf "       sudo ufw delete allow 3000/tcp\n"
printf "       sudo iptables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT\n"
printf "       sudo ip6tables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true\n"
echo ""

printf '\a'
