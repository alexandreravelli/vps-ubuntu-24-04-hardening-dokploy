#!/bin/bash
# Post-installation cleanup - removes old default user
# Usage: ./cleanup.sh [username]
set -euo pipefail

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

trap 'echo "  [ERROR] Cleanup failed unexpectedly. Check manually: id $TARGET_USER"' ERR

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

CURRENT_USER=$(whoami)
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
! id "$TARGET_USER" &>/dev/null && log "User '$TARGET_USER' doesn't exist (already removed)" && exit 0

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
else
    warn "User still exists -- remove manually"
fi

echo ""
gum style --foreground 2 --bold "  Cleanup complete!"
echo ""
