#!/bin/bash
# VPS Hardening Script - Simple & Reliable
# Ubuntu 24.04 LTS + Dokploy
# https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy
# Usage: sudo bash setup.sh

set -euo pipefail

VERSION="3.0.0"

# === VERSION FLAG ===
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "VPS Hardening Script v$VERSION"
    exit 0
fi

# === ROOT CHECK ===
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

# === CONFIGURATION ===
# Capture the invoking user before sudo escalation (needed for cleanup step)
CURRENT_USER="${SUDO_USER:-$(whoami)}"
if command -v shuf &>/dev/null; then
    SSH_PORT=$(shuf -i 50000-60000 -n 1)
else
    SSH_PORT=$(( (RANDOM % 10000) + 50000 ))
fi
LOG_FILE="/var/log/vps_setup.log"
CONFIG_FILE="/root/.vps_hardening_config"
TOTAL_STEPS=9
CURRENT_STEP=0

# === CLEANUP TRAP (pre-gum safe) ===
SETUP_PHASE="init"
cleanup_on_error() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo ""
        printf "  \033[1;31m──────────────────────────────────────────────\033[0m\n"
        printf "  \033[1;31m[ERROR] SETUP FAILED during phase: %s\033[0m\n" "$SETUP_PHASE"
        printf "  Check the log: %s\n" "$LOG_FILE"
        printf "  \033[1;31m──────────────────────────────────────────────\033[0m\n"

        if [ "$SETUP_PHASE" = "ssh" ] || [ "$SETUP_PHASE" = "firewall" ]; then
            echo ""
            printf "  \033[1;33m[!] Restoring SSH access on port 22 as a safety measure...\033[0m\n"
            sudo ufw allow 22/tcp 2>/dev/null || true
            if [ -f /etc/ssh/sshd_config.bak ]; then
                sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config 2>/dev/null || true
                sudo systemctl restart ssh 2>/dev/null || true
            fi
            printf "  \033[1;33m[!] Port 22 restored. You should still have access.\033[0m\n"
        fi
    fi
}
trap cleanup_on_error EXIT

# === INSTALL GUM ===
if ! command -v gum &>/dev/null; then
    echo "Installing gum (CLI toolkit)..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gum
fi

# === UI FUNCTIONS ===

progress_bar() {
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
    sudo -v 2>/dev/null || true  # Refresh sudo token to prevent timeout during long operations
    gum spin --spinner dot --title "$label" -- "$@"
}

run_with_log() {
    # Runs a command in the background while streaming its output live.
    # Uses a tmpfile + tail -f so output appears in real time without blocking.
    local label="$1"
    shift
    sudo -v 2>/dev/null || true  # Refresh sudo token to prevent timeout during long operations
    printf "  \033[1;34m>> %s\033[0m\n" "$label"
    local tmpfile
    tmpfile=$(mktemp)
    "$@" > "$tmpfile" 2>&1 &
    local pid=$!
    tail -f "$tmpfile" 2>/dev/null | while IFS= read -r line; do
        printf "  \033[0;90m   %s\033[0m\n" "$line"
    done &
    local tail_pid=$!
    wait "$pid"
    local exit_code=$?
    sleep 0.5  # Allow tail to flush remaining output before killing it
    kill "$tail_pid" 2>/dev/null || true
    rm -f "$tmpfile"
    return "$exit_code"
}

log() {
    gum style --foreground 2 "  [OK] $1"
    echo ""
    echo "[OK] $(date +%H:%M:%S) $1" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    gum style --foreground 3 "  [!] $1"
    echo "[WARN] $(date +%H:%M:%S) $1" >> "$LOG_FILE" 2>/dev/null || true
}

error() {
    gum style --foreground 1 --bold "  [X] $1"
    echo "[ERROR] $(date +%H:%M:%S) $1" >> "$LOG_FILE" 2>/dev/null || true
    exit 1
}

input_banner() {
    echo ""
    gum style --bold --foreground 6 "  INPUT REQUIRED"
    gum style --foreground 6 "  $1"
    echo ""
}

copy_block() {
    printf "\n  \033[1;32m>\033[0m  %s\n\n" "$1"
}

# === WELCOME SCREEN ===
clear 2>/dev/null || true

# Title box
gum style \
    --border double \
    --border-foreground 4 \
    --padding "1 6" \
    --margin "1 2" \
    --bold \
    --align center \
    "VPS HARDENING SCRIPT" \
    "" \
    "Ubuntu 24.04 LTS + Dokploy" \
    "~10 min  ·  9 steps"

echo ""

# Steps section
gum style --bold --foreground 6 "  WHAT IT DOES"
gum style --foreground 240 "  ────────────────────────────────────────────────"
echo ""
printf "  $(gum style --bold --foreground 6 '1')  Create admin user + strong password policy\n"
printf "  $(gum style --bold --foreground 6 '2')  Configure SSH key (ed25519 + passphrase)\n"
printf "  $(gum style --bold --foreground 6 '3')  Update system, auto-sized swap, DNS-over-TLS\n"
printf "  $(gum style --bold --foreground 6 '4')  Kernel hardening: anti-spoofing, ASLR, SYN\n"
printf "  $(gum style --bold --foreground 6 '5')  Install UFW · Fail2Ban · AppArmor · auditd\n"
printf "  $(gum style --bold --foreground 6 '6')  Firewall: deny-by-default, allow 80/443/3000\n"
printf "  $(gum style --bold --foreground 6 '7')  SSH: random port 50000-60000, key-only auth\n"
printf "  $(gum style --bold --foreground 6 '8')  Docker: official APT repo + GPG + Swarm\n"
printf "  $(gum style --bold --foreground 6 '9')  Dokploy: self-hosted PaaS at port 3000\n"
echo ""

# Prerequisites section
gum style --bold --foreground 2 "  PREREQUISITES"
gum style --foreground 240 "  ────────────────────────────────────────────────"
echo ""
printf "  $(gum style --foreground 2 '✓')  Fresh Ubuntu 24.04 LTS VPS\n"
printf "  $(gum style --foreground 2 '✓')  User with sudo privileges\n"
printf "  $(gum style --foreground 2 '✓')  SSH public key (ed25519) -- or generate one\n"
echo ""

# Firewall warning box
gum style \
    --border rounded \
    --border-foreground 3 \
    --foreground 3 \
    --padding "0 2" \
    --margin "0 2" \
    "⚠  EXTERNAL FIREWALL (OVH, Hetzner, AWS...)" \
    "Open these ports BEFORE running the script:" \
    "22 (SSH)  ·  80 (HTTP)  ·  443 (HTTPS)  ·  3000 (Dokploy)" \
    "The final custom SSH port will be shown at the end."

echo ""

gum confirm "Ready to start?" || { echo "Setup cancelled."; exit 0; }

START_TIME=$SECONDS

# === PRE-CHECKS ===
progress_bar 0 "$TOTAL_STEPS" "Pre-flight checks"
SETUP_PHASE="pre-checks"

sudo touch "$LOG_FILE"
sudo chmod 640 "$LOG_FILE"
echo "=== VPS Hardening Setup v$VERSION - $(date) ===" | sudo tee "$LOG_FILE" > /dev/null

echo "SSH_PORT=$SSH_PORT" | sudo tee "$CONFIG_FILE" > /dev/null
sudo chmod 600 "$CONFIG_FILE"

if ! sudo -v; then
    error "This script requires sudo privileges"
fi

if ! grep -q "Ubuntu 24" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu 24.04 LTS"
fi

if ! curl -s --max-time 5 https://api.ipify.org &>/dev/null; then
    error "No internet connection (TCP/443 unreachable)"
fi
log "All pre-checks passed"

# === STEP 1: CREATE USER ===
CURRENT_STEP=1
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Create secure user"
SETUP_PHASE="user-creation"

input_banner "Choose a username for your admin account"
NEW_USER=$(gum input --placeholder "Username (lowercase, letters/numbers/hyphens)" --prompt "> " --prompt.foreground 6)

if [ -z "$NEW_USER" ]; then
    error "Username cannot be empty"
fi

if ! echo "$NEW_USER" | grep -qE '^[a-z][a-z0-9_-]*$'; then
    error "Invalid username. Use lowercase letters, numbers, underscores, hyphens. Must start with a letter."
fi

if id "$NEW_USER" &>/dev/null; then
    error "User '$NEW_USER' already exists"
fi

sudo adduser --gecos "" --disabled-password "$NEW_USER"
log "User '$NEW_USER' created"

input_banner "Set password for $NEW_USER (min 12 chars, mixed case, numbers, symbols)"
while true; do
    PASS1=$(gum input --password --placeholder "Password (min 12 chars)" --prompt "> " --prompt.foreground 6)
    PASS2=$(gum input --password --placeholder "Confirm password" --prompt "> " --prompt.foreground 6)

    if [ -z "$PASS1" ]; then
        warn "Password cannot be empty"
        continue
    fi

    if [ ${#PASS1} -lt 12 ]; then
        warn "Password must be at least 12 characters"
        continue
    fi

    if [ "$PASS1" != "$PASS2" ]; then
        warn "Passwords don't match"
        continue
    fi

    printf '%s:%s' "$NEW_USER" "$PASS1" | sudo chpasswd && break
done
# Clear sensitive variables from memory
PASS1=""; PASS2=""
unset PASS1 PASS2
log "Password set"

sudo usermod -aG sudo "$NEW_USER"
log "Sudo access granted"

# === STEP 2: SSH KEY ===
CURRENT_STEP=2
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Configure SSH key"
SETUP_PHASE="ssh-key"

SSH_METHOD=$(gum choose --header "How would you like to configure SSH?" \
    "I already have an SSH key -- paste it" \
    "Generate a new SSH key pair for me")

if [[ "$SSH_METHOD" == *"Generate"* ]]; then

    # Optional passphrase
    KEY_PASSPHRASE=""
    if gum confirm "Protect the key with a passphrase? (adds extra security)"; then
        input_banner "Choose a passphrase for your SSH key"
        while true; do
            PP1=$(gum input --password --placeholder "Passphrase" --prompt "> " --prompt.foreground 6)
            PP2=$(gum input --password --placeholder "Confirm passphrase" --prompt "> " --prompt.foreground 6)
            if [ -z "$PP1" ]; then
                warn "Passphrase cannot be empty"
                continue
            fi
            if [ "$PP1" != "$PP2" ]; then
                warn "Passphrases don't match"
                continue
            fi
            KEY_PASSPHRASE="$PP1"
            break
        done
    fi

    TEMP_KEY_DIR=$(mktemp -d)
    TEMP_KEY_PATH="$TEMP_KEY_DIR/id_ed25519"

    gum spin --spinner dot --title "Generating ed25519 key pair..." -- \
        ssh-keygen -t ed25519 -f "$TEMP_KEY_PATH" -N "$KEY_PASSPHRASE" -C "$NEW_USER@$(hostname)"

    KEY_PASSPHRASE=""
    unset KEY_PASSPHRASE PP1 PP2

    sudo mkdir -p "/home/$NEW_USER/.ssh"
    sudo cp "$TEMP_KEY_PATH.pub" "/home/$NEW_USER/.ssh/authorized_keys"
    sudo chmod 700 "/home/$NEW_USER/.ssh"
    sudo chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"

    echo ""
    gum style \
        --border rounded \
        --border-foreground 3 \
        --foreground 3 \
        --padding "0 2" \
        --margin "0 2" \
        "⚠  IMPORTANT: Save your private key NOW" \
        "This key will be DELETED from the server after this step."
    echo ""

    gum style --bold --foreground 6 "  Private key:"
    echo ""
    cat "$TEMP_KEY_PATH"
    echo ""

    gum style --bold --foreground 6 "  Public key:"
    echo ""
    cat "$TEMP_KEY_PATH.pub"
    echo ""

    gum confirm --prompt.foreground 6 "I have saved the private key" || {
        warn "Please save the private key before continuing!"
        echo ""
        cat "$TEMP_KEY_PATH"
        echo ""
        gum confirm --prompt.foreground 6 "I have saved the private key now" || error "Cannot continue without saving the private key"
    }

    # Securely delete private key -- shred overwrites file contents before deleting
    shred -u "$TEMP_KEY_PATH" 2>/dev/null || rm -f "$TEMP_KEY_PATH"
    rm -f "$TEMP_KEY_PATH.pub"
    rmdir "$TEMP_KEY_DIR" 2>/dev/null || true

    log "SSH key pair generated (ed25519), public key installed, private key removed from server"

else
    input_banner "Paste your SSH public key (ssh-ed25519 or ssh-rsa)"
    SSH_KEY=$(gum write --placeholder "Paste your key here (ssh-ed25519 AAAA... or ssh-rsa AAAA...) then press Ctrl+D" --width 120 --char-limit 0)

    if [ -z "$SSH_KEY" ]; then
        error "SSH key cannot be empty"
    fi

    if ! echo "$SSH_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2)"; then
        error "Invalid SSH key format"
    fi

    sudo mkdir -p "/home/$NEW_USER/.ssh"
    echo "$SSH_KEY" | sudo tee "/home/$NEW_USER/.ssh/authorized_keys" > /dev/null
    sudo chmod 700 "/home/$NEW_USER/.ssh"
    sudo chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    # Clear sensitive variable from memory
    SSH_KEY=""
    unset SSH_KEY
    log "SSH key configured"
fi

# === STEP 3: SYSTEM UPDATE ===
CURRENT_STEP=3
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Update system (~2-3 min)"
SETUP_PHASE="system-update"

run_with_spinner "Updating package lists" sudo apt-get update -qq
run_with_spinner "Upgrading packages" sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
log "System updated"

sudo timedatectl set-timezone UTC
log "Timezone set to UTC"

if [ ! -f /swapfile ]; then
    # Scale swap to RAM: ≤4GB → 2GB swap, 4-16GB → 4GB swap, >16GB → skip (enough RAM for Docker/PaaS)
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM_MB" -le 4096 ]; then
        SWAP_SIZE_MB=2048
    elif [ "$TOTAL_MEM_MB" -le 16384 ]; then
        SWAP_SIZE_MB=4096
    else
        SWAP_SIZE_MB=0
    fi

    if [ "$SWAP_SIZE_MB" -gt 0 ]; then
        SWAP_LABEL="$(( SWAP_SIZE_MB / 1024 ))GB"
        run_with_spinner "Creating ${SWAP_LABEL} swap file" bash -c "sudo fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB} status=none && sudo chmod 600 /swapfile && sudo mkswap /swapfile > /dev/null && sudo swapon /swapfile"
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
        if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
            echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl -p > /dev/null
        fi
        log "Swap configured (${SWAP_LABEL}, swappiness=10)"
    else
        log "Swap skipped ($(( TOTAL_MEM_MB / 1024 ))GB RAM detected -- not needed)"
    fi
else
    log "Swap already exists"
fi

sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/quad9.conf > /dev/null << EOF
[Resolve]
DNS=9.9.9.9 149.112.112.112 2620:fe::fe 2620:fe::9
FallbackDNS=9.9.9.11 149.112.112.11 2620:fe::11 2620:fe::fe:11
DNSOverTLS=yes
DNSSEC=yes
EOF
sudo systemctl restart systemd-resolved
log "Quad9 DNS configured with DNS-over-TLS + DNSSEC"

# === STEP 4: KERNEL HARDENING ===
CURRENT_STEP=4
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Kernel hardening (sysctl)"
SETUP_PHASE="kernel-hardening"

sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null << EOF
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Log Martians (spoofed packets)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ASLR full randomization
kernel.randomize_va_space = 2

# Restrict dmesg access
kernel.dmesg_restrict = 1

# Restrict kernel pointer access
kernel.kptr_restrict = 2
EOF
run_with_spinner "Applying kernel parameters" sudo sysctl --system
log "Kernel hardening applied"

# === STEP 5: INSTALL SECURITY TOOLS ===
CURRENT_STEP=5
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Install security tools (~1-2 min)"
SETUP_PHASE="security-tools"

run_with_spinner "Installing UFW, Fail2Ban, auditd, pwquality" sudo apt-get install -y -qq ufw fail2ban unattended-upgrades libpam-pwquality auditd
log "Security tools installed"

sudo tee /etc/security/pwquality.conf > /dev/null << EOF
minlen = 12
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
reject_username
enforce_for_root
EOF
log "Strong password policy configured"

sudo tee /etc/audit/rules.d/hardening.rules > /dev/null << EOF
-a always,exit -F arch=b64 -S execve -F euid=0 -k sudo_commands
-w /var/log/auth.log -p wa -k auth_log
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/group -p wa -k group_changes
-w /etc/hosts -p wa -k hosts_changes
-w /etc/network -p wa -k network_changes
EOF
sudo systemctl restart auditd
log "Audit logging configured"

sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}ESMApps:\${distro_codename}-apps-security";
    "\${distro_id}ESM:\${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null << EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
log "Automatic security updates enabled"

if sudo aa-status &>/dev/null; then
    PROFILES=$(sudo aa-status 2>/dev/null | grep "profiles are loaded" | awk '{print $1}')
    log "AppArmor active ($PROFILES profiles loaded)"
else
    warn "AppArmor not running -- installing..."
    run_with_spinner "Installing AppArmor" sudo apt-get install -y -qq apparmor apparmor-utils
    sudo systemctl enable apparmor
    sudo systemctl start apparmor
    log "AppArmor installed and enabled"
fi

sudo tee /etc/fail2ban/jail.local > /dev/null << EOF
[sshd]
enabled = true
port = 22,$SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
sudo systemctl restart fail2ban
log "Fail2Ban configured (ports 22 and $SSH_PORT)"

# === STEP 6: CONFIGURE FIREWALL ===
CURRENT_STEP=6
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Configure firewall"
SETUP_PHASE="firewall"

sudo ufw --force reset > /dev/null
sudo ufw default deny incoming > /dev/null
sudo ufw default allow outgoing > /dev/null
sudo ufw allow 22/tcp > /dev/null
sudo ufw allow "$SSH_PORT/tcp" > /dev/null
sudo ufw allow 80/tcp > /dev/null
sudo ufw allow 443/tcp > /dev/null
sudo ufw allow 3000/tcp > /dev/null
sudo ufw --force enable > /dev/null
log "Firewall configured (ports: 22, $SSH_PORT, 80, 443, 3000)"

# === STEP 7: CONFIGURE SSH ===
CURRENT_STEP=7
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Harden SSH"
SETUP_PHASE="ssh"

sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Ubuntu 24.04 uses ssh.socket by default; switch to ssh.service for reliable port binding
sudo systemctl disable --now ssh.socket 2>/dev/null || true
sudo systemctl enable ssh.service
sudo systemctl start ssh.service 2>/dev/null || true
log "SSH socket disabled, using direct service"

# AllowUsers is intentionally omitted here -- added only after the new connection is verified
# so the current user can still reconnect on port 22 if something goes wrong before CONFIRM
sudo tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null << EOF
Port 22
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Use reload (SIGHUP) instead of restart -- applies new config without dropping active SSH sessions
sudo systemctl reload ssh
log "SSH hardened (ports: 22 + $SSH_PORT, password auth still enabled)"

# === STEP 8: INSTALL DOCKER ===
CURRENT_STEP=8
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
log "Docker installed (official APT repo with GPG)"

sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << EOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
sudo systemctl restart docker
log "Docker log rotation configured"

# Initialize Docker Swarm (required for Dokploy/Traefik)
if ! sudo docker info 2>/dev/null | grep -q "Swarm: active"; then
    SWARM_ADDR=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    run_with_spinner "Initializing Docker Swarm" sudo docker swarm init --advertise-addr "$SWARM_ADDR"
    log "Docker Swarm initialized (required for Traefik)"
else
    log "Docker Swarm already active"
fi

# Docker firewall: deny-by-default on DOCKER-USER, allow only needed ports
run_with_spinner "Installing iptables-persistent" bash -c 'echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections && echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections && sudo apt-get install -y -qq iptables-persistent'

run_with_spinner "Configuring DOCKER-USER firewall rules" bash -c '
    sudo iptables -I DOCKER-USER -j DROP
    sudo iptables -I DOCKER-USER -p tcp --dport 443 -j ACCEPT
    sudo iptables -I DOCKER-USER -p tcp --dport 80 -j ACCEPT
    sudo iptables -I DOCKER-USER -p tcp --dport 3000 -j ACCEPT
    sudo iptables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    sudo iptables -I DOCKER-USER -s 172.16.0.0/12 -j ACCEPT
    sudo iptables -I DOCKER-USER -s 10.0.0.0/8 -j ACCEPT
    sudo iptables -I DOCKER-USER -i lo -j ACCEPT
'

# Same rules for IPv6 (if Docker manages ip6tables)
if sudo ip6tables -L DOCKER-USER &>/dev/null 2>&1; then
    run_with_spinner "Configuring DOCKER-USER IPv6 firewall rules" bash -c '
        sudo ip6tables -I DOCKER-USER -j DROP 2>/dev/null || true
        sudo ip6tables -I DOCKER-USER -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
        sudo ip6tables -I DOCKER-USER -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
        sudo ip6tables -I DOCKER-USER -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
        sudo ip6tables -I DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        sudo ip6tables -I DOCKER-USER -i lo -j ACCEPT 2>/dev/null || true
    '
fi

run_with_spinner "Saving firewall rules" sudo netfilter-persistent save
log "Docker firewall configured (DOCKER-USER: deny-by-default, allow 80, 443, 3000)"

# === STEP 9: INSTALL DOKPLOY ===
CURRENT_STEP=9
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Install Dokploy (~1-2 min)"
SETUP_PHASE="dokploy"

run_with_log "Installing Dokploy" bash -c 'timeout 300 bash -c "curl -sSL https://dokploy.com/install.sh | sudo sh"'
log "Dokploy installed"

gum spin --spinner dot --title "Waiting for Dokploy to start..." -- bash -c '
for i in $(seq 1 30); do
    curl -s http://localhost:3000 &>/dev/null && exit 0
    sleep 2
done
exit 1
' && log "Dokploy is running" || warn "Dokploy did not respond within 60s -- it may still be starting"

# === DOWNLOAD POST-INSTALL SCRIPTS ===
REPO_BASE="https://raw.githubusercontent.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/main"
USER_HOME=$(eval echo "~$NEW_USER")
for script in cleanup.sh check.sh; do
    curl -sSL "$REPO_BASE/$script" -o "$USER_HOME/$script"
    chmod +x "$USER_HOME/$script"
    chown "$NEW_USER:$NEW_USER" "$USER_HOME/$script"
done
log "Post-install scripts downloaded (cleanup.sh, check.sh)"

# === TEST SSH CONNECTION ===
progress_bar "$TOTAL_STEPS" "$TOTAL_STEPS" "All steps completed"
SETUP_PHASE="ssh-test"

PUBLIC_IP=$(curl -s --max-time 10 ifconfig.me || echo "UNKNOWN")

gum style \
    --border rounded \
    --border-foreground 1 \
    --foreground 1 \
    --padding "0 2" \
    --margin "0 2" \
    --bold \
    "CRITICAL: Test your SSH connection before continuing" \
    "" \
    "External firewall (OVH, Hetzner, AWS...): open port $SSH_PORT first." \
    "Open a NEW terminal and run:"
copy_block "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"

if gum confirm "Did SSH work on port $SSH_PORT?"; then
    echo ""
    gum style \
        --border rounded \
        --border-foreground 3 \
        --foreground 3 \
        --padding "0 2" \
        --margin "0 2" \
        "⚠  This will permanently close port 22 and disable password auth." \
        "Make sure you can connect via:"
    copy_block "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"

    CONFIRM_CLOSE=$(gum input --placeholder "Type CONFIRM to proceed, anything else to cancel" --prompt "> " --prompt.foreground 3)

    if [ "$CONFIRM_CLOSE" = "CONFIRM" ]; then
        sudo tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null << EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $NEW_USER
EOF
        # Use reload instead of restart -- script session stays alive to finish the remaining steps
        sudo systemctl reload ssh
        sudo ufw delete allow 22/tcp

        sudo tee /etc/fail2ban/jail.local > /dev/null << EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
        sudo systemctl restart fail2ban

        # Order matters: add LIMIT rule first, then remove ALLOW to avoid a gap in coverage
        sudo ufw limit "$SSH_PORT/tcp" > /dev/null
        sudo ufw delete allow "$SSH_PORT/tcp" > /dev/null

        log "Port 22 closed, password auth disabled, rate limiting enabled"
    else
        warn "Confirmation cancelled -- keeping port 22 and password auth open"
    fi
else
    warn "SSH test failed -- keeping port 22 and password auth open for safety"
    echo ""
    printf "  Fix the issue, then run these commands manually:\n"
    echo ""
    printf "  sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/hardening.conf\n"
    printf "  sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config.d/hardening.conf\n"
    printf "  sudo systemctl restart ssh\n"
    printf "  sudo ufw delete allow 22/tcp\n"
fi

# === OPTIONAL: REMOVE OLD USER ===
OLD_USER="$CURRENT_USER"

if [ "$OLD_USER" = "$NEW_USER" ]; then
    log "Old user and new user are the same -- nothing to remove"
elif [ "$OLD_USER" = "root" ]; then
    log "Running as root -- no user to remove"
elif ! id "$OLD_USER" &>/dev/null; then
    log "User '$OLD_USER' doesn't exist (already removed)"
else
    echo ""
    gum style --bold --foreground 6 "  Optional: Remove old user '$OLD_USER'"
    echo ""

    if [ "$OLD_USER" = "$(whoami)" ]; then
        warn "Cannot auto-remove '$OLD_USER' -- you're currently logged in as this user"
        echo ""
        printf "  To remove this user safely:\n"
        printf "  1. Disconnect from this session\n"
        printf "  2. Login as '%s':\n" "$NEW_USER"
        copy_block "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"
        printf "  3. Run: sudo deluser --remove-home %s\n" "$OLD_USER"
    else
        if gum confirm "Remove user '$OLD_USER'?"; then
            sudo pkill -9 -u "$OLD_USER" 2>/dev/null || true
            sleep 2

            if sudo deluser --remove-home "$OLD_USER" 2>/dev/null; then
                log "User '$OLD_USER' removed"
            elif sudo userdel -r -f "$OLD_USER" 2>/dev/null; then
                log "User '$OLD_USER' removed"
            else
                warn "Could not remove '$OLD_USER' automatically"
                printf "  Try manually: sudo userdel -r -f %s\n" "$OLD_USER"
            fi

            if ! id "$OLD_USER" &>/dev/null; then
                log "Verified: '$OLD_USER' no longer exists"
            else
                warn "User '$OLD_USER' still exists -- remove manually"
            fi
        else
            warn "User '$OLD_USER' NOT removed"
            printf "  Remove later with: sudo deluser --remove-home %s\n" "$OLD_USER"
        fi
    fi
fi

# === CONFIG SUMMARY FILE ===
sudo tee "/home/$NEW_USER/.vps_setup_summary" > /dev/null << EOF
# VPS Setup Summary - $(date +%Y-%m-%d)
# Generated by VPS Hardening Script v$VERSION
HOST=$PUBLIC_IP
USER=$NEW_USER
SSH_PORT=$SSH_PORT
DOKPLOY_URL=http://$PUBLIC_IP:3000
SSH_CMD=ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT
LOG_FILE=$LOG_FILE
EOF
sudo chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.vps_setup_summary"

# === FINAL SUMMARY ===
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
    "SERVER READY  (${ELAPSED_MIN}m ${ELAPSED_SEC}s)"

echo ""
gum style --bold --foreground 2 "  CONNECT"
gum style --foreground 240 "  ──────────────────────────────────────────────────"
printf "  $(gum style --bold 'SSH')      ssh %s@%s -p %s\n" "$NEW_USER" "$PUBLIC_IP" "$SSH_PORT"
printf "  $(gum style --bold 'Dokploy')  http://%s:3000\n" "$PUBLIC_IP"
printf "  $(gum style --bold 'Log')      %s\n" "$LOG_FILE"
echo ""
gum style --bold --foreground 2 "  NEXT STEPS"
gum style --foreground 240 "  ──────────────────────────────────────────────────"
printf "  $(gum style --bold --foreground 6 '1')  Reconnect as %s on port %s\n" "$NEW_USER" "$SSH_PORT"
printf "  $(gum style --bold --foreground 6 '2')  Run ./cleanup.sh  -- remove old default user\n"
printf "  $(gum style --bold --foreground 6 '3')  Run ./check.sh    -- verify hardening\n"
printf "  $(gum style --bold --foreground 6 '4')  Setup Dokploy at http://%s:3000\n" "$PUBLIC_IP"
printf "  $(gum style --bold --foreground 6 '5')  After SSL, close port 3000:\n"
printf "       sudo iptables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT\n"
printf "       sudo netfilter-persistent save\n"
echo ""

printf '\a'  # Terminal bell -- audible notification that setup is complete
