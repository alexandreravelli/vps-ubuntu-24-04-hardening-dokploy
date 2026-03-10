#!/bin/bash
# Post-installation cleanup - removes old default user
# Usage: ./cleanup.sh [username]
set -euo pipefail

# === INSTALL GUM IF NEEDED ===
if ! command -v gum &>/dev/null; then
    echo "Installing gum..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq gum
fi

log() { gum style --foreground 2 "  [OK] $1"; }
warn() { gum style --foreground 3 "  [!] $1"; }
error() { gum style --foreground 1 --bold "  [X] $1"; exit 1; }

echo ""
printf "  \033[1;34m──────────────────────────────────────────────\033[0m\n"
printf "  \033[1;34mPOST-INSTALLATION CLEANUP\033[0m\n"
printf "  \033[1;34m──────────────────────────────────────────────\033[0m\n"
echo ""

CURRENT_USER=$(whoami)
if [ $# -ge 1 ]; then
    TARGET_USER="$1"
else
    printf "  Common default users: ubuntu, admin, debian\n"
    TARGET_USER=$(gum input --placeholder "Which user to remove?" --prompt "> " --prompt.foreground 6)
fi

[ -z "$TARGET_USER" ] && error "No user specified"
[ "$CURRENT_USER" = "$TARGET_USER" ] && error "You are logged in as '$TARGET_USER'. Login with a different user first."
! id "$TARGET_USER" &>/dev/null && log "User '$TARGET_USER' doesn't exist (already removed)" && exit 0

gum style --foreground 3 "  This will remove user '$TARGET_USER' and its home directory."
gum confirm "Continue?" || { warn "Cleanup cancelled"; exit 0; }

gum spin --spinner dot --title "Removing user '$TARGET_USER'..." -- bash -c "
    sudo pkill -9 -u '$TARGET_USER' 2>/dev/null || true
    sleep 2
    sudo deluser --remove-home '$TARGET_USER' 2>/dev/null || sudo userdel -r -f '$TARGET_USER' 2>/dev/null
"

if ! id "$TARGET_USER" &>/dev/null; then
    log "User '$TARGET_USER' removed successfully"
    log "Verified: '$TARGET_USER' no longer exists"
else
    warn "User still exists -- remove manually"
fi

echo ""
gum style --foreground 2 --bold "  Cleanup complete!"
echo ""
