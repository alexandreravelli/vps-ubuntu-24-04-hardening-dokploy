#!/bin/bash
# VPS Hardening Script - Simple & Reliable
# Ubuntu 24.04 LTS + Dokploy
# https://github.com/alexandreravelli/vps-hardening-script-ubuntu-24.04-LTS

set -euo pipefail

VERSION="3.0.0"

# === VERSION FLAG ===
if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "VPS Hardening Script v$VERSION"
    exit 0
fi

# === CONFIGURATION ===
CURRENT_USER=$(whoami)
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
HAS_GUM=false
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo ""
        if $HAS_GUM; then
            gum style --foreground 1 --bold --border rounded --border-foreground 1 --padding "1 2" \
                "SETUP FAILED during phase: $SETUP_PHASE" \
                "" \
                "Check the log: $LOG_FILE"
        else
            echo -e "\033[0;31m[ERROR] SETUP FAILED during phase: $SETUP_PHASE\033[0m"
            echo "Check the log: $LOG_FILE"
        fi

        if [ "$SETUP_PHASE" = "ssh" ] || [ "$SETUP_PHASE" = "firewall" ]; then
            echo ""
            echo -e "\033[1;33m[!] Restoring SSH access on port 22 as a safety measure...\033[0m"
            sudo ufw allow 22/tcp 2>/dev/null || true
            if [ -f /etc/ssh/sshd_config.bak ]; then
                sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config 2>/dev/null || true
                sudo systemctl restart ssh 2>/dev/null || true
            fi
            echo -e "\033[1;33m[!] Port 22 restored. You should still have access.\033[0m"
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
HAS_GUM=true

# === UI FUNCTIONS ===

progress_bar() {
    local current=$1
    local total=$2
    local label="$3"
    local filled=$((current * 20 / total))
    local empty=$((20 - filled))
    local bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar+=$(printf '%*s' "$empty" '' | tr ' ' '-')
    echo ""
    gum style --foreground 4 --bold "[$bar] Step $current/$total -- $label"
    echo ""
}

run_with_spinner() {
    local label="$1"
    shift
    sudo -v 2>/dev/null || true
    gum spin --spinner dot --title "$label" -- "$@"
}

log() {
    gum style --foreground 2 "  [OK] $1"
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
    gum style --border rounded --border-foreground 6 --foreground 6 --padding "0 1" --margin "1 0" "INPUT REQUIRED  $1"
}

copy_block() {
    gum style --border double --border-foreground 2 --padding "0 2" --margin "0 2" "$1"
}

table_row() {
    printf "  \033[2m%-16s\033[0m %s\n" "$1" "$2"
}

# === WELCOME SCREEN ===
clear 2>/dev/null || true

gum style \
    --border double \
    --border-foreground 4 \
    --padding "1 4" \
    --margin "1 0" \
    --bold \
    --align center \
    "VPS HARDENING SCRIPT  v$VERSION" \
    "" \
    "Ubuntu 24.04 LTS + Dokploy" \
    "Secure your server in minutes"

echo ""
gum style --foreground 7 --bold "  This script will:"
echo ""
gum style --foreground 8 "  1. Create a secure admin user"
gum style --foreground 8 "  2. Configure SSH key authentication"
gum style --foreground 8 "  3. Update system + swap + DNS-over-TLS"
gum style --foreground 8 "  4. Apply kernel hardening (sysctl)"
gum style --foreground 8 "  5. Install security tools (UFW, Fail2Ban, auditd...)"
gum style --foreground 8 "  6. Configure firewall"
gum style --foreground 8 "  7. Harden SSH on a random port"
gum style --foreground 8 "  8. Install Docker (official repo)"
gum style --foreground 8 "  9. Install Dokploy"
echo ""
gum style --foreground 7 --bold "  Prerequisites:"
echo ""
gum style --foreground 8 "  - Fresh Ubuntu 24.04 LTS VPS"
gum style --foreground 8 "  - User with sudo privileges"
gum style --foreground 8 "  - SSH public key ready (or generate one)"
echo ""

gum confirm "Ready to start?" || { echo "Setup cancelled."; exit 0; }

# === PRE-CHECKS ===
progress_bar 0 $TOTAL_STEPS "Pre-flight checks"
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

if ! ping -c 1 8.8.8.8 &>/dev/null; then
    error "No internet connection"
fi
log "All pre-checks passed"

# === STEP 1: CREATE USER ===
CURRENT_STEP=1
progress_bar $CURRENT_STEP $TOTAL_STEPS "Create secure user"
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
PASS1=""; PASS2=""
unset PASS1 PASS2
log "Password set"

sudo usermod -aG sudo "$NEW_USER"
log "Sudo access granted"

# === STEP 2: SSH KEY ===
CURRENT_STEP=2
progress_bar $CURRENT_STEP $TOTAL_STEPS "Configure SSH key"
SETUP_PHASE="ssh-key"

SSH_METHOD=$(gum choose --header "How would you like to configure SSH?" \
    "I already have an SSH key -- paste it" \
    "Generate a new SSH key pair for me")

if [[ "$SSH_METHOD" == *"Generate"* ]]; then
    TEMP_KEY_DIR=$(mktemp -d)
    TEMP_KEY_PATH="$TEMP_KEY_DIR/id_ed25519"

    gum spin --spinner dot --title "Generating ed25519 key pair..." -- \
        ssh-keygen -t ed25519 -f "$TEMP_KEY_PATH" -N "" -C "$NEW_USER@$(hostname)"

    SSH_PUB_KEY=$(cat "$TEMP_KEY_PATH.pub")
    SSH_PRIV_KEY=$(cat "$TEMP_KEY_PATH")

    sudo mkdir -p "/home/$NEW_USER/.ssh"
    echo "$SSH_PUB_KEY" | sudo tee "/home/$NEW_USER/.ssh/authorized_keys" > /dev/null
    sudo chmod 700 "/home/$NEW_USER/.ssh"
    sudo chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"

    echo ""
    gum style --border rounded --border-foreground 3 --foreground 3 --padding "1 2" --margin "1 0" \
        "IMPORTANT: Save your private key NOW" \
        "" \
        "This key will be DELETED from the server after this step." \
        "Copy everything below (including BEGIN and END lines)" \
        "and save it to a file on your local machine:" \
        "" \
        "  Linux/Mac: ~/.ssh/id_ed25519" \
        "  Windows:   C:\Users\YOU\.ssh\id_ed25519" \
        "" \
        "Then set permissions:" \
        "  chmod 600 ~/.ssh/id_ed25519"

    echo ""
    gum style --border double --border-foreground 2 --padding "1 2" --margin "0 2" "$SSH_PRIV_KEY"
    echo ""

    gum style --foreground 7 "  Public key (for reference):"
    gum style --border rounded --border-foreground 8 --padding "0 2" --margin "0 2" "$SSH_PUB_KEY"
    echo ""

    gum confirm "I have saved the private key" || {
        warn "Please save the private key before continuing!"
        echo ""
        gum style --border double --border-foreground 2 --padding "1 2" --margin "0 2" "$SSH_PRIV_KEY"
        echo ""
        gum confirm "I have saved the private key now" || error "Cannot continue without saving the private key"
    }

    shred -u "$TEMP_KEY_PATH" 2>/dev/null || rm -f "$TEMP_KEY_PATH"
    rm -f "$TEMP_KEY_PATH.pub"
    rmdir "$TEMP_KEY_DIR" 2>/dev/null || true

    log "SSH key pair generated, public key installed, private key removed from server"

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
    log "SSH key configured"
fi

# === STEP 3: SYSTEM UPDATE ===
CURRENT_STEP=3
progress_bar $CURRENT_STEP $TOTAL_STEPS "Update system (~2-3 min)"
SETUP_PHASE="system-update"

run_with_spinner "Updating package lists" sudo apt-get update -qq
run_with_spinner "Upgrading packages" sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
log "System updated"

sudo timedatectl set-timezone UTC
log "Timezone set to UTC"

if [ ! -f /swapfile ]; then
    run_with_spinner "Creating 2GB swap file" bash -c 'sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none && sudo chmod 600 /swapfile && sudo mkswap /swapfile > /dev/null && sudo swapon /swapfile'
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
        sudo sysctl -p > /dev/null
    fi
    log "Swap configured (2GB, swappiness=10)"
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
progress_bar $CURRENT_STEP $TOTAL_STEPS "Kernel hardening (sysctl)"
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
progress_bar $CURRENT_STEP $TOTAL_STEPS "Install security tools (~1-2 min)"
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
progress_bar $CURRENT_STEP $TOTAL_STEPS "Configure firewall"
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
progress_bar $CURRENT_STEP $TOTAL_STEPS "Harden SSH"
SETUP_PHASE="ssh"

sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

sudo systemctl disable --now ssh.socket 2>/dev/null || true
sudo systemctl enable ssh.service
log "SSH socket disabled, using direct service"

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
AllowUsers $NEW_USER
EOF

sudo systemctl restart ssh
log "SSH hardened (ports: 22 + $SSH_PORT, password auth still enabled)"

# === STEP 8: INSTALL DOCKER ===
CURRENT_STEP=8
progress_bar $CURRENT_STEP $TOTAL_STEPS "Install Docker (~2-3 min)"
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
run_with_spinner "Installing Docker Engine" sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

# === STEP 9: INSTALL DOKPLOY ===
CURRENT_STEP=9
progress_bar $CURRENT_STEP $TOTAL_STEPS "Install Dokploy (~1-2 min)"
SETUP_PHASE="dokploy"

run_with_spinner "Installing Dokploy" bash -c 'curl -sSL https://dokploy.com/install.sh | sudo sh'
log "Dokploy installed"

gum spin --spinner dot --title "Waiting for Dokploy to start..." -- bash -c '
for i in $(seq 1 30); do
    curl -s http://localhost:3000 &>/dev/null && exit 0
    sleep 2
done
exit 1
' && log "Dokploy is running" || warn "Dokploy did not respond within 60s -- it may still be starting"

# === TEST SSH CONNECTION ===
progress_bar $TOTAL_STEPS $TOTAL_STEPS "All steps completed"
SETUP_PHASE="ssh-test"

PUBLIC_IP=$(curl -s --max-time 10 ifconfig.me || echo "UNKNOWN")

gum style --border rounded --border-foreground 3 --foreground 3 --bold --padding "1 2" --margin "1 0" \
    "CRITICAL: Test your SSH connection before continuing"

echo ""
gum style --foreground 7 "  Open a NEW terminal and run:"
echo ""
copy_block "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"

if gum confirm "Did SSH work on port $SSH_PORT?"; then
    echo ""
    gum style --border rounded --border-foreground 3 --foreground 3 --padding "1 2" --margin "1 0" \
        "WARNING: This will permanently close port 22" \
        "and disable password authentication." \
        "" \
        "Make sure you can connect via:" \
        "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"

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
        sudo systemctl restart ssh
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

        sudo ufw delete allow "$SSH_PORT/tcp" > /dev/null
        sudo ufw limit "$SSH_PORT/tcp" > /dev/null

        log "Port 22 closed, password auth disabled, rate limiting enabled"
    else
        warn "Confirmation cancelled -- keeping port 22 and password auth open"
    fi
else
    warn "SSH test failed -- keeping port 22 and password auth open for safety"
    echo ""
    gum style --foreground 7 "  Fix the issue, then run these commands manually:"
    echo ""
    gum style --foreground 8 "  sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/hardening.conf"
    gum style --foreground 8 "  sudo sed -i '/^Port 22$/d' /etc/ssh/sshd_config.d/hardening.conf"
    gum style --foreground 8 "  sudo systemctl restart ssh"
    gum style --foreground 8 "  sudo ufw delete allow 22/tcp"
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
    gum style --border rounded --border-foreground 4 --padding "0 2" --margin "1 0" "Optional: Remove old user '$OLD_USER'"

    if [ "$OLD_USER" = "$(whoami)" ]; then
        warn "Cannot auto-remove '$OLD_USER' -- you're currently logged in as this user"
        echo ""
        gum style --foreground 7 "  To remove this user safely:"
        gum style --foreground 8 "  1. Disconnect from this session"
        gum style --foreground 8 "  2. Login as '$NEW_USER':"
        copy_block "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"
        gum style --foreground 8 "  3. Run: sudo deluser --remove-home $OLD_USER"
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
                gum style --foreground 8 "  Try manually: sudo userdel -r -f $OLD_USER"
            fi

            if ! id "$OLD_USER" &>/dev/null; then
                log "Verified: '$OLD_USER' no longer exists"
            else
                warn "User '$OLD_USER' still exists -- remove manually"
            fi
        else
            warn "User '$OLD_USER' NOT removed"
            gum style --foreground 8 "  Remove later with: sudo deluser --remove-home $OLD_USER"
        fi
    fi
fi

# === CREATE CLEANUP SCRIPT ===
sudo tee "/home/$NEW_USER/cleanup.sh" > /dev/null << 'CLEANUP_EOF'
#!/bin/bash
# Post-installation cleanup - removes old default user
# Usage: ./cleanup.sh [username]
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $1"; }
error() { echo -e "  ${RED}[X]${NC} $1"; exit 1; }

echo ""
echo "  +------------------------------------------+"
echo "  |  POST-INSTALLATION CLEANUP               |"
echo "  +------------------------------------------+"
echo ""

CURRENT_USER=$(whoami)
if [ $# -ge 1 ]; then
    TARGET_USER="$1"
else
    echo "  Common default users: ubuntu, admin, debian"
    read -r -p "  Which user to remove? > " TARGET_USER
fi

[ -z "$TARGET_USER" ] && error "No user specified"
[ "$CURRENT_USER" = "$TARGET_USER" ] && error "You are logged in as '$TARGET_USER'. Login with a different user first."
! id "$TARGET_USER" &>/dev/null && log "User '$TARGET_USER' doesn't exist (already removed)" && exit 0

echo "  This will remove user '$TARGET_USER' and its home directory."
read -r -p "  Continue? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && warn "Cleanup cancelled" && exit 0

echo "  Removing user '$TARGET_USER'..."
sudo pkill -9 -u "$TARGET_USER" 2>/dev/null || true
sleep 2

if sudo deluser --remove-home "$TARGET_USER" 2>/dev/null; then
    log "User '$TARGET_USER' removed successfully"
elif sudo userdel -r -f "$TARGET_USER" 2>/dev/null; then
    log "User '$TARGET_USER' removed successfully"
else
    error "Could not remove '$TARGET_USER'. Try: sudo userdel -r -f $TARGET_USER"
fi

! id "$TARGET_USER" &>/dev/null && log "Verified: '$TARGET_USER' no longer exists" || warn "User still exists -- remove manually"
echo ""
echo "  Cleanup complete!"
echo ""
CLEANUP_EOF

sudo chmod +x "/home/$NEW_USER/cleanup.sh"
sudo chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/cleanup.sh"

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

gum style \
    --border double \
    --border-foreground 2 \
    --padding "1 4" \
    --margin "1 0" \
    --bold \
    --align center \
    "SERVER READY"

echo ""
table_row "SSH" "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"
table_row "Dokploy" "http://$PUBLIC_IP:3000"
table_row "SSH Port" "$SSH_PORT"
table_row "Firewall" "80, 443, 3000, $SSH_PORT"
table_row "Fail2Ban" "Active (3 retries, 1h ban)"
table_row "Auto-updates" "Enabled"
table_row "Kernel" "Hardened (sysctl)"
table_row "AppArmor" "Active"
table_row "DNS" "Quad9 + DNS-over-TLS"
table_row "Log" "$LOG_FILE"
table_row "Config" "/home/$NEW_USER/.vps_setup_summary"
echo ""

gum style --foreground 7 --bold "  Quick connect:"
copy_block "ssh $NEW_USER@$PUBLIC_IP -p $SSH_PORT"

gum style --foreground 7 --bold "  Next steps:"
echo ""
gum style --foreground 8 "  1. Reconnect as $NEW_USER"
gum style --foreground 8 "  2. Run ./cleanup.sh to remove old default user"
gum style --foreground 8 "  3. Run ./check.sh to verify hardening status"
gum style --foreground 8 "  4. Access Dokploy and create admin account"
gum style --foreground 8 "  5. Configure your domain + SSL in Dokploy"
gum style --foreground 8 "  6. After SSL, block port 3000:"
echo ""
copy_block "sudo iptables -I DOCKER-USER -p tcp --dport 3000 -j DROP && sudo iptables -I DOCKER-USER -i lo -p tcp --dport 3000 -j ACCEPT && sudo apt-get install -y iptables-persistent && sudo netfilter-persistent save"

printf '\a'
