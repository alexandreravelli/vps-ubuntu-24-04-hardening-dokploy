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
