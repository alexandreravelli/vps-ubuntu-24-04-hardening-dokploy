#!/bin/bash
# Post-installation cleanup - removes old default user
# Usage: ./cleanup.sh [username]
set -euo pipefail

VERSION="1.0.16"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "VPS Hardening Cleanup v$VERSION"
    exit 0
fi

# === ROOT CHECK ===
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges."
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

# === INSTALL GUM IF NEEDED ===
install_gum() {
    echo "Installing gum..."
    sudo mkdir -p /etc/apt/keyrings
    local GPG_TMP
    GPG_TMP=$(mktemp)
    curl -fsSL https://repo.charm.sh/apt/gpg.key -o "$GPG_TMP"
    local CHARM_FP
    CHARM_FP=$(gpg --with-colons --import-options show-only --import "$GPG_TMP" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    local EXPECTED_FP="ED927B38BE981E53CA09153D03BBF595D4DFD35C"
    if [ "$CHARM_FP" != "$EXPECTED_FP" ]; then
        rm -f "$GPG_TMP"
        echo "[ERROR] Charm GPG key fingerprint mismatch! Expected: $EXPECTED_FP Got: $CHARM_FP"
        exit 1
    fi
    sudo gpg --yes --dearmor -o /etc/apt/keyrings/charm.gpg < "$GPG_TMP" 2>/dev/null
    rm -f "$GPG_TMP"
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq gum
}
if ! command -v gum &>/dev/null; then
    install_gum
fi

TARGET_USER=""
trap 'echo "  [ERROR] Cleanup failed unexpectedly. Check manually: id ${TARGET_USER:-unknown}"' ERR

LOG_FILE="/var/log/vps_setup.log"

log() {
    gum style --foreground 2 "  [OK] $1"
    echo "[OK] $(date +%H:%M:%S) [cleanup] $1" >> "$LOG_FILE" 2>/dev/null || true
}
warn() {
    gum style --foreground 3 "  [!] $1"
    echo "[WARN] $(date +%H:%M:%S) [cleanup] $1" >> "$LOG_FILE" 2>/dev/null || true
}
error() {
    gum style --foreground 1 --bold "  [X] $1"
    echo "[ERROR] $(date +%H:%M:%S) [cleanup] $1" >> "$LOG_FILE" 2>/dev/null || true
    exit 1
}

cleanup_sudoers_for_user() {
    local target_user="$1"
    local backup_dir
    local modified=false
    local file backup_path
    local files=()

    backup_dir="/root/vps-hardening-sudoers-backup-$(date +%Y%m%d%H%M%S)"

    files+=("/etc/sudoers")
    while IFS= read -r file; do
        files+=("$file")
    done < <(find /etc/sudoers.d -maxdepth 1 -type f 2>/dev/null | sort)

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        if grep -qE "^[[:space:]]*${target_user}[[:space:]]" "$file" 2>/dev/null; then
            sudo mkdir -p "$backup_dir$(dirname "$file")"
            backup_path="$backup_dir$file"
            sudo cp -a "$file" "$backup_path"
            sudo sed -i "/^[[:space:]]*${target_user}[[:space:]]/d" "$file"
            if [ "$file" != "/etc/sudoers" ] && [ ! -s "$file" ]; then
                sudo rm -f "$file"
            fi
            modified=true
        fi
    done

    if [ "$modified" = true ]; then
        if sudo visudo -cf /etc/sudoers > /dev/null; then
            log "Removed stale sudoers entries for '$target_user' (backup: $backup_dir)"
        else
            warn "sudoers validation failed -- restoring backup"
            while IFS= read -r backup_path; do
                file="/${backup_path#"$backup_dir"/}"
                sudo mkdir -p "$(dirname "$file")"
                sudo cp -a "$backup_path" "$file"
            done < <(find "$backup_dir" -type f 2>/dev/null | sort)
            sudo visudo -cf /etc/sudoers > /dev/null || true
            error "sudoers cleanup failed; backup restored from $backup_dir"
        fi
    else
        log "No direct sudoers entries found for '$target_user'"
    fi
}

cleanup_temporary_ssh_files() {
    if [ -f /run/sshd-hardened.pid ] && kill -0 "$(cat /run/sshd-hardened.pid)" 2>/dev/null; then
        warn "Temporary sshd still running -- keeping SSH test config for safety"
        return
    fi

    if [ -f /etc/ssh/sshd_test_config ] || [ -f /etc/ssh/sshd_config.d/zz-setup-keepalive.conf ]; then
        sudo rm -f /etc/ssh/sshd_test_config /etc/ssh/sshd_config.d/zz-setup-keepalive.conf
        log "Temporary SSH setup files removed"
    else
        log "No temporary SSH setup files found"
    fi
}

echo ""
gum style \
    --border rounded \
    --border-foreground 4 \
    --padding "0 4" \
    --margin "0 2" \
    --bold \
    --align center \
    "POST-INSTALLATION CLEANUP" \
    "Remove the old default user"
echo ""

CURRENT_USER="${SUDO_USER:-$(whoami)}"
if [ $# -ge 1 ]; then
    TARGET_USER="$1"
else
    printf "  Common default users: ubuntu, admin, debian\n"
    TARGET_USER=$(gum input --placeholder "Which user to remove?" --prompt "> " --prompt.foreground 6)
fi

[ -z "$TARGET_USER" ] && error "No user specified"
# Validate username format to prevent injection
if ! echo "$TARGET_USER" | grep -qE '^[a-z][a-z0-9_-]*$'; then
    error "Invalid username format. Use lowercase letters, numbers, underscores, hyphens."
fi
[ "$CURRENT_USER" = "$TARGET_USER" ] && error "You are logged in as '$TARGET_USER'. Login with a different user first."
# Protect system accounts (UID < 1000)
if id "$TARGET_USER" &>/dev/null; then
    TARGET_UID=$(id -u "$TARGET_USER")
    [ "$TARGET_UID" -lt 1000 ] && error "Refusing to remove system account '$TARGET_USER' (UID $TARGET_UID)"
fi
if ! id "$TARGET_USER" &>/dev/null; then
    log "User '$TARGET_USER' doesn't exist (already removed)"
    cleanup_sudoers_for_user "$TARGET_USER"
    cleanup_temporary_ssh_files
    exit 0
fi

gum style --foreground 3 "  This will remove user '$TARGET_USER' and its home directory."
gum confirm "Continue?" || { warn "Cleanup cancelled"; exit 0; }

gum spin --spinner dot --title "Removing user..." -- bash -c '
    sudo pkill -9 -u "$1" 2>/dev/null || true
    sleep 2
    sudo deluser --remove-home "$1" 2>/dev/null || sudo userdel -r -f "$1" 2>/dev/null
' _ "$TARGET_USER"

if ! id "$TARGET_USER" &>/dev/null; then
    log "User '$TARGET_USER' removed successfully"
    log "Verified: '$TARGET_USER' no longer exists"
    cleanup_sudoers_for_user "$TARGET_USER"
    cleanup_temporary_ssh_files
else
    warn "User still exists -- remove manually"
fi

echo ""
gum style --foreground 2 --bold "  Cleanup complete!"
echo ""
