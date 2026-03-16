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

VERSION="5.0.5"

# === ROOT CHECK ===
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

# === AUTO-SCREEN ===
# If not inside screen, relaunch inside screen so the script survives SSH drops.
if [ -z "${STY:-}" ]; then
    if command -v screen &>/dev/null; then
        echo "Launching inside screen (reconnect with: screen -r dokploy-install)"
        exec screen -S dokploy-install bash "$0" "$@"
    else
        echo "[WARN] screen not found — if SSH drops, the install will be interrupted."
        echo "       Consider running: screen -S dokploy-install bash $0"
    fi
fi

# === LOAD CONFIG FROM SETUP.SH ===
CONFIG_FILE="/root/.vps_hardening_config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Config file not found at $CONFIG_FILE"
    echo "        Run setup.sh first to harden the server."
    exit 1
fi

# Safe config parsing — only read expected variables (no arbitrary code execution)
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    # Strip leading/trailing whitespace and quotes
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    case "$key" in
        SSH_PORT|NEW_USER|LOG_DAYS|LOG_WEEKS|CURRENT_USER)
            declare "$key=$value"
            ;;
        *)
            echo "[WARN] Ignoring unknown config key: $key"
            ;;
    esac
done < "$CONFIG_FILE"

# Validate required variables
for var in SSH_PORT NEW_USER LOG_DAYS; do
    if [ -z "${!var:-}" ]; then
        echo "[ERROR] Missing $var in $CONFIG_FILE -- run setup.sh first"
        exit 1
    fi
done

# Validate SSH_PORT is a number in valid range
if ! echo "$SSH_PORT" | grep -qE '^[0-9]+$' || [ "$SSH_PORT" -lt 1024 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "[ERROR] Invalid SSH_PORT=$SSH_PORT in $CONFIG_FILE -- expected a number between 1024 and 65535"
    exit 1
fi

# Validate NEW_USER format
if ! echo "$NEW_USER" | grep -qE '^[a-z][a-z0-9_-]*$'; then
    echo "[ERROR] Invalid NEW_USER=$NEW_USER in $CONFIG_FILE -- expected lowercase letters, numbers, underscores, hyphens"
    exit 1
fi

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

        # Clean up temporary keepalive
        sudo rm -f /etc/ssh/sshd_config.d/zz-install-keepalive.conf 2>/dev/null || true
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

wait_for_apt() {
    local max_wait=120
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 ||
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        if [ "$waited" -eq 0 ]; then
            warn "APT is locked by another process (likely unattended-upgrades). Waiting..."
        fi
        sleep 5
        waited=$((waited + 5))
        if [ "$waited" -ge "$max_wait" ]; then
            error "APT still locked after ${max_wait}s — kill the process or try again later"
        fi
    done
    if [ "$waited" -gt 0 ]; then
        log "APT lock released after ${waited}s"
    fi
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
    # Ensure temp file is cleaned up even if script is interrupted
    # $tmpfile must expand now, not at signal time
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'; trap - RETURN" RETURN
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
    "Self-hosted PaaS · Docker Swarm · Deny-by-default firewall" \
    "3 steps · ~5 minutes"

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

# Temporarily harden SSH keepalive to survive Docker/iptables disruptions
# (setup.sh removed the keepalive after CONFIRM, so we need it again)
sudo tee /etc/ssh/sshd_config.d/zz-install-keepalive.conf > /dev/null << 'KEEPALIVE'
ClientAliveInterval 15
ClientAliveCountMax 10
KEEPALIVE
sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload ssh.service 2>/dev/null || true

START_TIME=$SECONDS
echo "=== Docker + Dokploy Install - $(date) ===" >> "$LOG_FILE"

# === STEP 1: INSTALL DOCKER ===
CURRENT_STEP=1
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Install Docker (~2-3 min)"
SETUP_PHASE="docker"

wait_for_apt
run_with_spinner "Installing Docker prerequisites" sudo apt-get install -y -qq ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
DOCKER_GPG_TMP=$(mktemp)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_GPG_TMP"
DOCKER_FP=$(gpg --with-colons --import-options show-only --import "$DOCKER_GPG_TMP" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
EXPECTED_DOCKER_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
if [ "$DOCKER_FP" != "$EXPECTED_DOCKER_FP" ]; then
    rm -f "$DOCKER_GPG_TMP"
    error "Docker GPG key fingerprint mismatch! Expected: $EXPECTED_DOCKER_FP Got: $DOCKER_FP"
fi
sudo gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg < "$DOCKER_GPG_TMP" 2>/dev/null
rm -f "$DOCKER_GPG_TMP"
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
  "log-opts": {"max-size": "10m", "max-file": "${DOCKER_MAX_FILE}"},
  "no-new-privileges": true
}
EOF
sudo systemctl restart docker
log "Docker log rotation configured"

# NOTE: Docker Swarm is NOT initialized here. Dokploy's installer does
# "docker swarm leave --force" then re-inits Swarm itself. If we init
# Swarm first, the leave+rejoin cycle disrupts iptables and kills SSH.
# Let Dokploy handle Swarm initialization entirely.

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
    "$cmd" -L DOCKER-USER -n &>/dev/null 2>&1 || continue
    "$cmd" -F DOCKER-USER
    "$cmd" -I DOCKER-USER -j DROP
    "$cmd" -I DOCKER-USER -p tcp --dport 443 -j ACCEPT
    "$cmd" -I DOCKER-USER -p tcp --dport 80 -j ACCEPT
    "$cmd" -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$cmd" -I DOCKER-USER -i lo -j ACCEPT
done
# Allow Docker bridge networks (172.16.0.0/12) + overlay/Swarm networks (10.0.0.0/8)
iptables -I DOCKER-USER -s 172.16.0.0/12 -j ACCEPT
iptables -I DOCKER-USER -s 10.0.0.0/8 -j ACCEPT
# Allow Docker internal IPv6 networks
ip6tables -I DOCKER-USER -s fd00::/8 -j ACCEPT 2>/dev/null || true
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

DOKPLOY_INSTALLER=$(mktemp)
curl -sSL https://dokploy.com/install.sh -o "$DOKPLOY_INSTALLER"

# Basic sanity check — verify this looks like the Dokploy installer
if ! grep -qi "dokploy" "$DOKPLOY_INSTALLER"; then
    rm -f "$DOKPLOY_INSTALLER"
    error "Dokploy installer content looks suspicious — aborting for safety"
fi

INSTALLER_HASH=$(sha256sum "$DOKPLOY_INSTALLER" | awk '{print $1}')
log "Dokploy installer SHA256: $INSTALLER_HASH"

run_with_spinner "Installing Dokploy (~2-5 min)" bash "$DOKPLOY_INSTALLER"
rm -f "$DOKPLOY_INSTALLER"
log "Dokploy installed"

sudo apt-mark unhold ufw > /dev/null 2>&1 || true

# === POST-DOKPLOY RECOVERY ===
# Dokploy's install script can break things. Fix everything it might have touched.
SETUP_PHASE="post-dokploy-recovery"

# 1. Reinstall UFW if Dokploy removed it
if ! dpkg -l ufw 2>/dev/null | grep -q "^ii"; then
    run_with_spinner "Reinstalling UFW (removed by Dokploy)" sudo apt-get install -y -qq ufw
fi

# 2. Re-apply UFW rules (force reset removes any manual rules added after setup.sh)
# Backup existing UFW rules before reset
sudo cp /etc/ufw/user.rules "/etc/ufw/user.rules.bak.$(date +%s)" 2>/dev/null || true
sudo cp /etc/ufw/user6.rules "/etc/ufw/user6.rules.bak.$(date +%s)" 2>/dev/null || true
warn "UFW rules backed up and will be reset to match hardening config"
sudo ufw disable > /dev/null 2>&1 || true
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

# Remove temporary keepalive (hardening.conf already has 300s/2 retries)
sudo rm -f /etc/ssh/sshd_config.d/zz-install-keepalive.conf
sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload ssh.service 2>/dev/null || true

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

# If running inside screen, wait for user to read the summary before screen exits
if [ -n "${STY:-}" ]; then
    echo ""
    read -rp "  Press Enter to exit..."
fi
