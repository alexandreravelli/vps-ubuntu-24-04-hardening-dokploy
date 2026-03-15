#!/bin/bash
# VPS Hardening Script
# Ubuntu 24.04 LTS
# https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy
# Usage: sudo bash setup.sh
#
# Architecture:
#   Phase 1 — Collect all user inputs (interactive, requires terminal)
#   Phase 2 — Apply hardening (non-interactive, survives SSH disconnection)
#   Phase 3 — SSH test + CONFIRM (interactive, requires terminal)

set -euo pipefail

VERSION="5.0.0"

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

# === AUTO-SCREEN ===
# If not inside screen, relaunch inside screen so the script survives SSH drops.
# The user can reconnect with: screen -r hardening
if [ -z "${STY:-}" ]; then
    if ! command -v screen &>/dev/null; then
        apt-get install -y -qq screen 2>/dev/null || true
    fi
    if command -v screen &>/dev/null; then
        echo "Launching inside screen (reconnect with: screen -r hardening)"
        exec screen -S hardening bash "$0" "$@"
    fi
fi

# === CONFIGURATION ===
CURRENT_USER="${SUDO_USER:-$(whoami)}"
MAX_PORT_ATTEMPTS=10
for _port_try in $(seq 1 $MAX_PORT_ATTEMPTS); do
    if command -v shuf &>/dev/null; then
        SSH_PORT=$(shuf -i 50000-60000 -n 1)
    else
        SSH_PORT=$(( (RANDOM % 10000) + 50000 ))
    fi
    if ! ss -tlnp 2>/dev/null | grep -q ":$SSH_PORT "; then
        break
    fi
    if [ "$_port_try" -eq "$MAX_PORT_ATTEMPTS" ]; then
        echo "Could not find an available port in range 50000-60000"
        exit 1
    fi
done
LOG_FILE="/var/log/vps_setup.log"
CONFIG_FILE="/root/.vps_hardening_config"
TOTAL_STEPS=7
CURRENT_STEP=0

# === CLEANUP TRAP ===
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
            printf "  \033[1;33m[!] Restoring SSH access on port 22...\033[0m\n"
            sudo ufw allow 22/tcp 2>/dev/null || true
            sudo rm -f /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null || true
            sudo rm -rf /etc/systemd/system/ssh.socket.d 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true
            if [ -f /run/sshd-hardened.pid ]; then
                sudo kill "$(cat /run/sshd-hardened.pid)" 2>/dev/null || true
                sudo rm -f /run/sshd-hardened.pid 2>/dev/null || true
            fi
            printf "  \033[1;33m[!] Port 22 restored. Your session should be intact.\033[0m\n"
        fi
    fi
}
trap cleanup_on_error EXIT
trap '' HUP PIPE

# === INSTALL GUM ===
install_gum() {
    echo "Installing gum (CLI toolkit)..."
    sudo mkdir -p /etc/apt/keyrings
    local GPG_TMP
    GPG_TMP=$(mktemp)
    curl -fsSL https://repo.charm.sh/apt/gpg.key -o "$GPG_TMP"
    # Verify GPG key fingerprint before trusting
    local CHARM_FP
    CHARM_FP=$(gpg --with-colons --import-options show-only --import "$GPG_TMP" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    local EXPECTED_FP="ED927B38BE981E53CA09153D03BBF595D4DFD35C"
    if [ "$CHARM_FP" != "$EXPECTED_FP" ]; then
        rm -f "$GPG_TMP"
        echo "[ERROR] Charm GPG key fingerprint mismatch!"
        echo "  Expected: $EXPECTED_FP"
        echo "  Got:      $CHARM_FP"
        echo "  The key may have been rotated. Verify at https://charm.sh and update EXPECTED_FP."
        exit 1
    fi
    sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg < "$GPG_TMP" 2>/dev/null
    rm -f "$GPG_TMP"
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq gum
}
if ! command -v gum &>/dev/null; then
    install_gum
fi

# === UI FUNCTIONS ===

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

input_banner() {
    echo ""
    gum style --bold --foreground 6 "  INPUT REQUIRED"
    gum style --foreground 6 "  $1"
    echo ""
}

copy_block() {
    printf "\n  \033[1;32m>\033[0m  %s\n\n" "$1"
}

# ╔════════════════════════════════════════════════════════════════════╗
# ║  PHASE 1 — COLLECT ALL INPUTS                                     ║
# ║  Nothing is modified on the system during this phase.              ║
# ║  If SSH drops here, just reconnect and restart the script.         ║
# ╚════════════════════════════════════════════════════════════════════╝

clear 2>/dev/null || true

gum style \
    --border double \
    --border-foreground 4 \
    --padding "1 6" \
    --margin "1 2" \
    --bold \
    --align center \
    "VPS HARDENING SCRIPT" \
    "" \
    "Ubuntu 24.04 LTS · Secure in 5 minutes" \
    "7 steps · Key-only SSH · Firewall · Kernel hardening"

echo ""

gum style --bold --foreground 6 "  WHAT IT DOES"
gum style --foreground 240 "  ────────────────────────────────────────────────"
echo ""
printf "  $(gum style --foreground 240 '1')  Rename server + create admin user + strong password policy\n"
printf "  $(gum style --foreground 240 '2')  Configure SSH key (ed25519 + passphrase)\n"
printf "  $(gum style --foreground 240 '3')  Update system, auto-sized swap, DNS-over-TLS\n"
printf "  $(gum style --foreground 240 '4')  Kernel hardening: anti-spoofing, ASLR, SYN\n"
printf "  $(gum style --foreground 240 '5')  Install UFW · Fail2Ban · AppArmor · auditd · log retention\n"
printf "  $(gum style --foreground 240 '6')  Firewall: deny-by-default, allow custom SSH + 80 + 443\n"
printf "  $(gum style --foreground 240 '7')  SSH: random port 50000-60000, key-only auth\n"
echo ""

gum style --bold --foreground 2 "  PREREQUISITES"
gum style --foreground 240 "  ────────────────────────────────────────────────"
echo ""
printf "  $(gum style --foreground 2 '✓')  Fresh Ubuntu 24.04 LTS VPS\n"
printf "  $(gum style --foreground 2 '✓')  User with sudo privileges\n"
printf "  $(gum style --foreground 2 '✓')  SSH public key (ed25519) — or generate one\n"
echo ""

gum style --bold --foreground 6 "  SERVER SPECS"
gum style --foreground 240 "  ────────────────────────────────────────────────"
echo ""

SPEC_OS=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Unknown")
SPEC_KERNEL=$(uname -r)
SPEC_CPU=$(nproc 2>/dev/null || echo "?")
SPEC_RAM=$(free -m 2>/dev/null | awk '/^Mem:/{printf "%.1f GB", $2/1024}' || echo "?")
SPEC_DISK_TOTAL=$(df -BG / 2>/dev/null | awk 'NR==2{printf "%d GB", $2}' || echo "?")
SPEC_DISK_FREE=$(df -BG / 2>/dev/null | awk 'NR==2{printf "%d GB", $4}' || echo "?")
SPEC_IPV4=$(curl -s --max-time 3 -4 ifconfig.me 2>/dev/null || echo "not available")
SPEC_IPV6=$(curl -s --max-time 3 -6 ifconfig.me 2>/dev/null || echo "not available")

printf "  %-12s %s\n" "OS" "$SPEC_OS"
printf "  %-12s %s\n" "Kernel" "$SPEC_KERNEL"
printf "  %-12s %s vCPU\n" "CPU" "$SPEC_CPU"
printf "  %-12s %s\n" "RAM" "$SPEC_RAM"
printf "  %-12s %s total / %s free\n" "Disk" "$SPEC_DISK_TOTAL" "$SPEC_DISK_FREE"
printf "  %-12s %s\n" "IPv4" "$SPEC_IPV4"
printf "  %-12s %s\n" "IPv6" "$SPEC_IPV6"
echo ""

HAS_CLOUD_FIREWALL=false
if curl -s --max-time 2 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/ &>/dev/null; then
    HAS_CLOUD_FIREWALL=true
elif curl -s --max-time 2 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
    HAS_CLOUD_FIREWALL=true
elif curl -s --max-time 2 http://169.254.169.254/hetzner/v1/metadata &>/dev/null; then
    HAS_CLOUD_FIREWALL=true
elif curl -s --max-time 2 http://169.254.169.254/openstack/latest/ &>/dev/null; then
    HAS_CLOUD_FIREWALL=true
elif grep -qi "digitalocean\|vultr" /sys/class/dmi/id/board_vendor 2>/dev/null; then
    HAS_CLOUD_FIREWALL=true
fi

if [ "$HAS_CLOUD_FIREWALL" = true ]; then
    gum style \
        --border rounded \
        --border-foreground 3 \
        --foreground 3 \
        --padding "0 2" \
        --margin "0 2" \
        "⚠  EXTERNAL FIREWALL DETECTED" \
        "Open these ports in your provider's control panel BEFORE running:" \
        "" \
        "$(printf '  %5s        SSH (temporary — closed after setup)' '22')" \
        "$(printf '  %5s        HTTP' '80')" \
        "$(printf '  %5s        HTTPS' '443')" \
        "$(printf '  %5s        SSH (custom port for this install)' "$SSH_PORT")"
else
    gum style \
        --border rounded \
        --border-foreground 3 \
        --foreground 3 \
        --padding "0 2" \
        --margin "0 2" \
        "⚠  EXTERNAL FIREWALL" \
        "If your provider has a network firewall, open these ports BEFORE running:" \
        "" \
        "$(printf '  %5s        SSH (temporary — closed after setup)' '22')" \
        "$(printf '  %5s        HTTP' '80')" \
        "$(printf '  %5s        HTTPS' '443')" \
        "" \
        "The final custom SSH port will be shown at the end."
fi

echo ""
gum confirm "Ready to start?" || { echo "Setup cancelled."; exit 0; }

# --- Collect hostname ---
input_banner "Choose a hostname for this server (e.g. web-prod-01)"
INPUT_HOSTNAME=$(gum input --placeholder "Hostname (letters, numbers, hyphens)" --prompt "> " --prompt.foreground 6)

if [ -n "$INPUT_HOSTNAME" ]; then
    if ! echo "$INPUT_HOSTNAME" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$'; then
        error "Invalid hostname. Use letters, numbers, and hyphens. Must start/end with alphanumeric."
    fi
fi

# --- Collect username ---
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

# --- Collect password ---
input_banner "Set password for $NEW_USER (min 12 chars, mixed case, numbers, symbols)"
while true; do
    PASS1=$(gum input --password --placeholder "Password (min 12 chars)" --prompt "> " --prompt.foreground 6)
    PASS2=$(gum input --password --placeholder "Confirm password" --prompt "> " --prompt.foreground 6)
    if [ -z "$PASS1" ]; then
        warn "Password cannot be empty"; continue
    fi
    if [ ${#PASS1} -lt 12 ]; then
        warn "Password must be at least 12 characters"; continue
    fi
    if [ "$PASS1" != "$PASS2" ]; then
        warn "Passwords don't match"; continue
    fi
    break
done

# --- Collect SSH key ---
SSH_METHOD=$(gum choose --header "How would you like to configure SSH?" \
    "I already have an SSH key -- paste it" \
    "Generate a new SSH key pair for me")

INPUT_SSH_KEY=""
KEY_PASSPHRASE=""
GENERATE_KEY=false

if [[ "$SSH_METHOD" == *"Generate"* ]]; then
    GENERATE_KEY=true
    if gum confirm "Protect the key with a passphrase? (adds extra security)"; then
        input_banner "Choose a passphrase for your SSH key"
        while true; do
            PP1=$(gum input --password --placeholder "Passphrase" --prompt "> " --prompt.foreground 6)
            PP2=$(gum input --password --placeholder "Confirm passphrase" --prompt "> " --prompt.foreground 6)
            if [ -z "$PP1" ]; then
                warn "Passphrase cannot be empty"; continue
            fi
            if [ "$PP1" != "$PP2" ]; then
                warn "Passphrases don't match"; continue
            fi
            KEY_PASSPHRASE="$PP1"
            break
        done
    fi
else
    input_banner "Paste your SSH public key (ssh-ed25519 or ssh-rsa)"
    INPUT_SSH_KEY=$(gum write --placeholder "Paste your key here (ssh-ed25519 AAAA... or ssh-rsa AAAA...) then press Ctrl+D" --width 120 --char-limit 0)
    if [ -z "$INPUT_SSH_KEY" ]; then
        error "SSH key cannot be empty"
    fi
    if ! echo "$INPUT_SSH_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2)"; then
        error "Invalid SSH key format"
    fi
fi

# --- Collect log retention ---
input_banner "Choose a log retention policy for your server"
printf "  \033[0;90mAffected logs: auditd, journald, Fail2Ban, UFW, syslog, auth.log\033[0m\n"
echo ""

LOG_RETENTION_CHOICE=$(gum choose \
    "Standard (90 days)" \
    "Extended (365 days)" \
    "Compliance (2 years)" \
    "Custom")

case "$LOG_RETENTION_CHOICE" in
    "Standard (90 days)")  LOG_DAYS=90  ;;
    "Extended (365 days)") LOG_DAYS=365 ;;
    "Compliance (2 years)") LOG_DAYS=730 ;;
    "Custom")
        input_banner "Enter custom retention period in days"
        LOG_DAYS=$(gum input --placeholder "Number of days (e.g. 180)" --prompt "> " --prompt.foreground 6)
        if ! echo "$LOG_DAYS" | grep -qE '^[0-9]+$' || [ "$LOG_DAYS" -lt 1 ]; then
            warn "Invalid number -- defaulting to 90 days"
            LOG_DAYS=90
        fi
        ;;
esac

LOG_WEEKS=$(( LOG_DAYS / 7 ))
[ "$LOG_WEEKS" -lt 1 ] && LOG_WEEKS=1

echo ""
gum style --bold --foreground 2 "  All inputs collected. Starting hardening..."
gum style --foreground 240 "  If your SSH session drops, the script will continue."
gum style --foreground 240 "  Reconnect with: screen -r hardening"
echo ""
sleep 2

# ╔════════════════════════════════════════════════════════════════════╗
# ║  PHASE 2 — APPLY HARDENING (non-interactive)                      ║
# ║  No user input required. Survives SSH disconnection via screen.    ║
# ╚════════════════════════════════════════════════════════════════════╝

START_TIME=$SECONDS

# === PRE-CHECKS ===
progress_bar 0 "$TOTAL_STEPS" "Pre-flight checks"
SETUP_PHASE="pre-checks"

sudo touch "$LOG_FILE"
sudo chmod 640 "$LOG_FILE"
echo "=== VPS Hardening Setup v$VERSION - $(date) ===" | sudo tee "$LOG_FILE" > /dev/null

echo "SSH_PORT=$SSH_PORT" | sudo tee "$CONFIG_FILE" > /dev/null
sudo chmod 600 "$CONFIG_FILE"

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

if [ -n "$INPUT_HOSTNAME" ]; then
    sudo hostnamectl set-hostname "$INPUT_HOSTNAME"
    log "Hostname set to '$INPUT_HOSTNAME'"
else
    warn "No hostname provided — keeping current: $(hostname)"
fi

sudo adduser --gecos "" --disabled-password "$NEW_USER"
sudo chpasswd <<< "$NEW_USER:$PASS1"
PASS1=""; PASS2=""
unset PASS1 PASS2
log "User '$NEW_USER' created with password"

sudo usermod -aG sudo "$NEW_USER"
log "Sudo access granted"

# === STEP 2: SSH KEY ===
CURRENT_STEP=2
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Configure SSH key"
SETUP_PHASE="ssh-key"

sudo mkdir -p "/home/$NEW_USER/.ssh"

if [ "$GENERATE_KEY" = true ]; then
    TEMP_KEY_DIR=$(mktemp -d)
    TEMP_KEY_PATH="$TEMP_KEY_DIR/id_ed25519"

    ssh-keygen -t ed25519 -f "$TEMP_KEY_PATH" -N "$KEY_PASSPHRASE" -C "$NEW_USER@$(hostname)" -q
    KEY_PASSPHRASE=""
    unset KEY_PASSPHRASE PP1 PP2

    sudo cp "$TEMP_KEY_PATH.pub" "/home/$NEW_USER/.ssh/authorized_keys"

    echo ""
    gum style \
        --border rounded \
        --border-foreground 3 \
        --foreground 3 \
        --padding "0 2" \
        --margin "0 2" \
        "⚠  IMPORTANT: Save your private key NOW" \
        "Copy it to your password manager." \
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

    shred -u "$TEMP_KEY_PATH" 2>/dev/null || rm -f "$TEMP_KEY_PATH"
    rm -f "$TEMP_KEY_PATH.pub"
    rmdir "$TEMP_KEY_DIR" 2>/dev/null || true

    log "SSH key pair generated (ed25519), public key installed, private key removed from server"
else
    echo "$INPUT_SSH_KEY" | sudo tee "/home/$NEW_USER/.ssh/authorized_keys" > /dev/null
    INPUT_SSH_KEY=""
    unset INPUT_SSH_KEY
    log "SSH key configured"
fi

sudo chmod 700 "/home/$NEW_USER/.ssh"
sudo chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"

# === STEP 3: SYSTEM UPDATE ===
CURRENT_STEP=3
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Update system (~2-3 min)"
SETUP_PHASE="system-update"

run_with_spinner "Updating package lists" sudo apt-get update -qq
sudo mkdir -p /etc/needrestart/conf.d
sudo tee /etc/needrestart/conf.d/99-no-ssh-restart.conf > /dev/null << 'NEEDRESTART'
$nrconf{override_rc}{q(ssh)} = 0;
$nrconf{override_rc}{q(sshd)} = 0;
NEEDRESTART
run_with_spinner "Upgrading packages" sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
log "System updated"

sudo timedatectl set-timezone UTC
log "Timezone set to UTC"

if [ ! -f /swapfile ]; then
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
        run_with_spinner "Creating ${SWAP_LABEL} swap file" bash -c "sudo fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || { sudo rm -f /swapfile && sudo dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE_MB} status=none; } && sudo chmod 600 /swapfile && sudo mkswap /swapfile > /dev/null && sudo swapon /swapfile"
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
        if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
            echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
            sudo sysctl -p > /dev/null
        fi
        log "Swap configured (${SWAP_LABEL}, swappiness=10)"
    else
        log "Swap skipped ($(( TOTAL_MEM_MB / 1024 ))GB RAM -- not needed)"
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
DNSSEC=allow-downgrade
EOF
sudo systemctl restart systemd-resolved
log "Quad9 DNS configured with DNS-over-TLS + DNSSEC (allow-downgrade)"

# === STEP 4: KERNEL HARDENING ===
CURRENT_STEP=4
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Kernel hardening (sysctl)"
SETUP_PHASE="kernel-hardening"

sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null << EOF
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.yama.ptrace_scope = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
fs.suid_dumpable = 0
EOF
run_with_spinner "Applying kernel parameters" sudo sysctl --system
log "Kernel hardening applied"

echo '* hard core 0' | sudo tee /etc/security/limits.d/no-core.conf > /dev/null
log "Core dumps restricted"

# /tmp noexec is NOT applied automatically because it breaks Docker builds
# and Dokploy operations after every reboot. This is the intended target use case.
# Users who don't use Docker can enable it manually:
log "/tmp noexec skipped (incompatible with Docker/Dokploy)"
log "To enable manually: echo 'tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,size=512M 0 0' >> /etc/fstab && reboot"

echo 'install usb-storage /bin/true' | sudo tee /etc/modprobe.d/no-usb-storage.conf > /dev/null
log "USB mass storage disabled"

# === STEP 5: INSTALL SECURITY TOOLS + CONFIGURE ===
CURRENT_STEP=5
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Install security tools (~1-2 min)"
SETUP_PHASE="security-tools"

run_with_spinner "Installing UFW, Fail2Ban, auditd, pwquality" sudo apt-get install -y -qq ufw fail2ban unattended-upgrades libpam-pwquality auditd
log "Security tools installed"

# journald retention
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/retention.conf > /dev/null << EOF
[Journal]
MaxRetentionSec=${LOG_DAYS}d
SystemMaxUse=500M
EOF
sudo systemctl restart systemd-journald
log "journald retention set to ${LOG_DAYS} days"

# auditd retention
AUDIT_NUM_LOGS=$(( LOG_DAYS / 7 ))
[ "$AUDIT_NUM_LOGS" -lt 5 ] && AUDIT_NUM_LOGS=5
[ "$AUDIT_NUM_LOGS" -gt 99 ] && AUDIT_NUM_LOGS=99
sudo sed -i "s/^num_logs.*/num_logs = $AUDIT_NUM_LOGS/" /etc/audit/auditd.conf
sudo sed -i "s/^max_log_file_action.*/max_log_file_action = ROTATE/" /etc/audit/auditd.conf
log "auditd retention configured ($AUDIT_NUM_LOGS rotated log files)"

# logrotate configs
sudo tee /etc/logrotate.d/ufw-custom > /dev/null << EOF
/var/log/ufw.log {
    weekly
    rotate $LOG_WEEKS
    compress
    delaycompress
    missingok
    notifempty
    create 0640 syslog adm
}
EOF

sudo tee /etc/logrotate.d/rsyslog-custom > /dev/null << EOF
/var/log/syslog
/var/log/auth.log {
    weekly
    rotate $LOG_WEEKS
    compress
    delaycompress
    missingok
    notifempty
    create 0640 syslog adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || true
    endscript
}
EOF

sudo tee /etc/logrotate.d/fail2ban-custom > /dev/null << EOF
/var/log/fail2ban.log {
    weekly
    rotate $LOG_WEEKS
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    postrotate
        fail2ban-client flushlogs >/dev/null 2>&1 || true
    endscript
}
EOF

echo "LOG_RETENTION_DAYS=$LOG_DAYS" | sudo tee -a "$CONFIG_FILE" > /dev/null
log "Log retention policy configured (${LOG_DAYS} days)"

# Password policy
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

# Audit rules
sudo tee /etc/audit/rules.d/hardening.rules > /dev/null << EOF
-a always,exit -F arch=b64 -S execve -F euid=0 -k sudo_commands
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/lastlog -p wa -k login_events
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/group -p wa -k group_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_changes
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/hosts -p wa -k hosts_changes
-w /etc/network -p wa -k network_changes
-a always,exit -F arch=b64 -S init_module -S delete_module -k modules
-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time_change
-a always,exit -F arch=b64 -S clock_settime -k time_change
-a always,exit -F arch=b64 -S unlink -S rename -S unlinkat -S renameat -F auid>=1000 -F auid!=4294967295 -k delete
-e 2
EOF
sudo systemctl restart auditd
log "Audit logging configured"

# Unattended upgrades
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

# AppArmor
if sudo aa-status &>/dev/null; then
    PROFILES=$(sudo aa-status 2>/dev/null | grep "profiles are loaded" | awk '{print $1}')
    log "AppArmor active ($PROFILES profiles loaded)"
else
    run_with_spinner "Installing AppArmor" sudo apt-get install -y -qq apparmor apparmor-utils
    sudo systemctl enable apparmor
    sudo systemctl start apparmor
    log "AppArmor installed and enabled"
fi

# Fail2Ban
sudo tee /etc/fail2ban/jail.local > /dev/null << EOF
[sshd]
enabled = true
port = 22,$SSH_PORT
filter = sshd
backend = systemd
maxretry = 3
bantime = 86400
findtime = 600
bantime.increment = true
bantime.factor = 2
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
sudo ufw --force enable > /dev/null
log "Firewall configured (ports: 22, $SSH_PORT, 80, 443)"

# === STEP 7: CONFIGURE SSH ===
CURRENT_STEP=7
progress_bar "$CURRENT_STEP" "$TOTAL_STEPS" "Harden SSH"
SETUP_PHASE="ssh"

sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
[ -x /usr/sbin/sshd ] || error "sshd binary not found"

# Ensure /run/sshd exists at every boot (privilege separation)
echo "d /run/sshd 0755 root root -" | sudo tee /etc/tmpfiles.d/sshd.conf > /dev/null
sudo systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf 2>/dev/null || sudo mkdir -p /run/sshd

# Clean up leftover pid from a previous run
if [ -f /run/sshd-hardened.pid ]; then
    sudo kill "$(cat /run/sshd-hardened.pid)" 2>/dev/null || true
    sudo rm -f /run/sshd-hardened.pid
fi

# Write SSH hardening config (port 22 kept open until CONFIRM)
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null << EOF
Port 22
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PermitUserEnvironment no
HostbasedAuthentication no
AllowAgentForwarding no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
EOF

sudo /usr/sbin/sshd -t || error "SSH config validation failed"

# Start standalone sshd on custom port for this session
sudo /usr/sbin/sshd -p "$SSH_PORT" -o "PidFile=/run/sshd-hardened.pid"

# Reconfigure ssh.socket to listen on custom port after reboot
# (instead of disabling it, which breaks ssh.service on Ubuntu 24.04)
sudo mkdir -p /etc/systemd/system/ssh.socket.d
sudo tee /etc/systemd/system/ssh.socket.d/override.conf > /dev/null << EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
sudo systemctl daemon-reload

log "SSH hardened (port $SSH_PORT)"

# Save config for install-dokploy.sh
{
    echo "NEW_USER=$NEW_USER"
    echo "LOG_DAYS=$LOG_DAYS"
    echo "LOG_WEEKS=$LOG_WEEKS"
    echo "CURRENT_USER=$CURRENT_USER"
} | sudo tee -a "$CONFIG_FILE" > /dev/null

# === SETUP COMPLETE — PREPARE SUMMARY ===
progress_bar "$TOTAL_STEPS" "$TOTAL_STEPS" "All steps completed"
SETUP_PHASE="ssh-test"

PUBLIC_IP=$(curl -s --max-time 10 -4 ifconfig.me 2>/dev/null || \
            curl -s --max-time 10 https://api.ipify.org 2>/dev/null || \
            curl -s --max-time 10 -6 ifconfig.me 2>/dev/null || \
            echo "")

if [ -z "$PUBLIC_IP" ]; then
    warn "Could not detect public IP — use your provider's dashboard to find it"
    PUBLIC_IP="YOUR_SERVER_IP"
fi

if echo "$PUBLIC_IP" | grep -q ":"; then
    SSH_HOST="[$PUBLIC_IP]"
else
    SSH_HOST="$PUBLIC_IP"
fi

USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] && [ -d "$USER_HOME" ] || error "Cannot find home directory for user '$NEW_USER'"

sudo tee "$USER_HOME/.vps_setup_summary" > /dev/null << EOF
# VPS Setup Summary - $(date +%Y-%m-%d)
# Generated by VPS Hardening Script v$VERSION
HOSTNAME=$(hostname)
HOST=$PUBLIC_IP
USER=$NEW_USER
SSH_PORT=$SSH_PORT
SSH_CMD=ssh $NEW_USER@$SSH_HOST -p $SSH_PORT
LOG_RETENTION=${LOG_DAYS}_days
LOG_FILE=$LOG_FILE
STATUS=pending_confirm
EOF
sudo chown "$NEW_USER:$NEW_USER" "$USER_HOME/.vps_setup_summary"
sudo chmod 600 "$USER_HOME/.vps_setup_summary"

# Download post-install scripts into a dedicated subdirectory
SCRIPTS_DIR="$USER_HOME/vps-hardening"
sudo mkdir -p "$SCRIPTS_DIR"
# Pin to release tag (not main) so a compromised main branch cannot inject code
# into servers that already ran setup.sh with this version.
REPO_BASE="https://raw.githubusercontent.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/v${VERSION}"
REPO_FALLBACK="https://raw.githubusercontent.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/main"

for script in cleanup.sh check.sh purge.sh install-dokploy.sh; do
    if curl -sSL --fail "$REPO_BASE/$script" -o "$SCRIPTS_DIR/$script" 2>/dev/null; then
        chmod +x "$SCRIPTS_DIR/$script"
    elif curl -sSL --fail "$REPO_FALLBACK/$script" -o "$SCRIPTS_DIR/$script" 2>/dev/null; then
        warn "$script: tag v${VERSION} not found, downloaded from main branch"
        chmod +x "$SCRIPTS_DIR/$script"
    else
        warn "Could not download $script"
    fi
done

# Integrity check (protects against network corruption, not repo compromise)
if curl -sSL --fail "$REPO_BASE/SHA256SUMS" -o "$SCRIPTS_DIR/SHA256SUMS" 2>/dev/null || \
   curl -sSL --fail "$REPO_FALLBACK/SHA256SUMS" -o "$SCRIPTS_DIR/SHA256SUMS" 2>/dev/null; then
    pushd "$SCRIPTS_DIR" > /dev/null
    if sha256sum -c SHA256SUMS --status 2>/dev/null; then
        log "Downloaded scripts integrity verified (SHA256)"
    else
        warn "Checksum mismatch — verify scripts manually before running"
    fi
    rm -f SHA256SUMS
    popd > /dev/null
fi

sudo chown -R "$NEW_USER:$NEW_USER" "$SCRIPTS_DIR"
log "Post-install scripts downloaded to $SCRIPTS_DIR"

# ╔════════════════════════════════════════════════════════════════════╗
# ║  PHASE 3 — SSH TEST + CONFIRM (interactive)                       ║
# ║  If terminal is lost, setup is complete but port 22 stays open.    ║
# ║  The user can CONFIRM manually later.                              ║
# ╚════════════════════════════════════════════════════════════════════╝

# Schedule auto-lockdown in 24h if CONFIRM is not completed
# This prevents port 22 + password auth from staying open indefinitely
if command -v at &>/dev/null; then
    echo "if grep -q 'STATUS=pending_confirm' '$USER_HOME/.vps_setup_summary' 2>/dev/null; then
        sed -i '/^Port 22$/d' /etc/ssh/sshd_config.d/hardening.conf
        sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/hardening.conf
        systemctl reload ssh 2>/dev/null || true
        systemctl restart ssh.socket 2>/dev/null || true
        ufw delete allow 22/tcp 2>/dev/null || true
        sed -i 's/STATUS=pending_confirm/STATUS=auto_locked/' '$USER_HOME/.vps_setup_summary'
        echo '[AUTO-LOCKDOWN] $(date) Port 22 closed and password auth disabled after 24h timeout' >> '$LOG_FILE'
    fi" | at now + 24 hours 2>/dev/null || true
    log "Auto-lockdown scheduled in 24h if CONFIRM not completed"
fi

if ! tty -s 2>/dev/null; then
    warn "Terminal lost. Setup complete but port 22 and password auth still open."
    warn "Reconnect and run the CONFIRM step manually — see $USER_HOME/.vps_setup_summary"
    warn "Port 22 will auto-close in 24h if not confirmed."
    ELAPSED=$(( SECONDS - START_TIME ))
    log "Setup completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s (pending manual CONFIRM)"
    exit 0
fi

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
copy_block "ssh $NEW_USER@$SSH_HOST -p $SSH_PORT"

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
    copy_block "ssh $NEW_USER@$SSH_HOST -p $SSH_PORT"

    CONFIRM_CLOSE=$(gum input --placeholder "Type CONFIRM to proceed, anything else to cancel" --prompt "> " --prompt.foreground 3)

    if [ "$CONFIRM_CLOSE" = "CONFIRM" ]; then
        sudo tee /etc/ssh/sshd_config.d/hardening.conf > /dev/null << EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PermitUserEnvironment no
HostbasedAuthentication no
AllowAgentForwarding no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
AllowUsers $NEW_USER

Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
EOF
        sudo /usr/sbin/sshd -t || error "SSH config validation failed"
        sudo kill -HUP "$(cat /run/sshd-hardened.pid 2>/dev/null)" 2>/dev/null || true
        sudo systemctl restart ssh.socket 2>/dev/null || true

        sudo ufw delete allow 22/tcp 2>/dev/null || true
        sudo ufw delete allow from any to any port 22 proto tcp 2>/dev/null || true

        sudo tee /etc/fail2ban/jail.local > /dev/null << EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
backend = systemd
maxretry = 3
bantime = 86400
findtime = 600
bantime.increment = true
bantime.factor = 2
EOF
        sudo systemctl restart fail2ban

        sudo ufw limit "$SSH_PORT/tcp" > /dev/null
        sudo ufw delete allow "$SSH_PORT/tcp" > /dev/null

        sudo sed -i 's/STATUS=pending_confirm/STATUS=complete/' "$USER_HOME/.vps_setup_summary"
        log "Port 22 closed, password auth disabled, rate limiting enabled"
    else
        warn "Confirmation cancelled — keeping port 22 and password auth open"
    fi
else
    warn "SSH test failed — keeping port 22 and password auth open for safety"
    echo ""
    printf "  Fix the issue, then run these commands manually:\n"
    echo ""
    printf "  sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/hardening.conf\n"
    printf "  sudo sed -i '/^Port 22\$/d' /etc/ssh/sshd_config.d/hardening.conf\n"
    printf "  sudo systemctl reload ssh\n"
    printf "  sudo ufw delete allow 22/tcp\n"
fi

# === OPTIONAL: REMOVE OLD USER ===
OLD_USER="$CURRENT_USER"

if [ "$OLD_USER" = "$NEW_USER" ]; then
    log "Old user and new user are the same — nothing to remove"
elif [ "$OLD_USER" = "root" ]; then
    log "Running as root — no user to remove"
elif ! id "$OLD_USER" &>/dev/null; then
    log "User '$OLD_USER' doesn't exist (already removed)"
else
    echo ""
    gum style --bold --foreground 6 "  Optional: Remove old user '$OLD_USER'"
    echo ""

    if [ "$OLD_USER" = "$(whoami)" ]; then
        warn "Cannot auto-remove '$OLD_USER' — you're currently logged in as this user"
        echo ""
        printf "  To remove this user safely:\n"
        printf "  1. Disconnect from this session\n"
        printf "  2. Login as '%s':\n" "$NEW_USER"
        copy_block "ssh $NEW_USER@$SSH_HOST -p $SSH_PORT"
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
            fi
        else
            warn "User '$OLD_USER' NOT removed"
        fi
    fi
fi

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
    "HARDENING COMPLETE  (${ELAPSED_MIN}m ${ELAPSED_SEC}s)"

echo ""
gum style --bold --foreground 2 "  CONNECT"
gum style --foreground 240 "  ──────────────────────────────────────────────────"
printf "  $(gum style --bold 'Host')     %s\n" "$(hostname)"
printf "  $(gum style --bold 'SSH')      ssh %s@%s -p %s\n" "$NEW_USER" "$SSH_HOST" "$SSH_PORT"
printf "  $(gum style --bold 'Log ret.') %s days\n" "$LOG_DAYS"
printf "  $(gum style --bold 'Log')      %s\n" "$LOG_FILE"
echo ""
gum style --bold --foreground 2 "  NEXT STEPS"
gum style --foreground 240 "  ──────────────────────────────────────────────────"
printf "  $(gum style --bold --foreground 6 '1')  Reconnect as %s on port %s\n" "$NEW_USER" "$SSH_PORT"
printf "  $(gum style --bold --foreground 6 '2')  cd ~/vps-hardening/\n"
printf "  $(gum style --bold --foreground 6 '3')  sudo ./install-dokploy.sh  — install Docker + Dokploy\n"
printf "  $(gum style --bold --foreground 6 '4')  sudo ./cleanup.sh  — remove old default user\n"
printf "  $(gum style --bold --foreground 6 '5')  sudo ./check.sh    — verify hardening\n"
printf "  $(gum style --bold --foreground 6 '6')  sudo ./purge.sh    — remove setup files\n"
echo ""

printf '\a'
