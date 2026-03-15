#!/bin/bash
# Remove all setup scripts from the server after hardening is complete
# Deletes: setup.sh, install-dokploy.sh, cleanup.sh, check.sh, purge.sh
# Usage: sudo ./purge.sh
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

echo ""
gum style \
    --border rounded \
    --border-foreground 3 \
    --padding "0 4" \
    --margin "0 2" \
    --bold \
    --align center \
    "PURGE SETUP FILES" \
    "Remove all hardening scripts from this server"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
gum style --foreground 3 "  This will permanently delete:"
echo ""
for f in "$SCRIPT_DIR"/*; do
    [ -e "$f" ] && printf "    %s\n" "$(basename "$f")"
done
if [ -d "$SCRIPT_DIR/.git" ]; then
    printf "    %s\n" ".git/"
fi
echo ""

# Safety check: ensure we're in the expected directory
if [ ! -f "$SCRIPT_DIR/purge.sh" ]; then
    echo "  [ERROR] Safety check failed: purge.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Refuse to purge outside /home or /root
case "$SCRIPT_DIR" in
    /home/*|/root/*) ;;
    *) echo "  [ERROR] Refusing to purge outside /home or /root: $SCRIPT_DIR"; exit 1 ;;
esac

# Resolve symlinks to prevent following links outside the directory
REAL_SCRIPT_DIR=$(realpath "$SCRIPT_DIR" 2>/dev/null || readlink -f "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR")
case "$REAL_SCRIPT_DIR" in
    /home/*|/root/*) ;;
    *) echo "  [ERROR] Resolved path is outside /home or /root: $REAL_SCRIPT_DIR"; exit 1 ;;
esac

if ! gum confirm "Delete all setup files from $SCRIPT_DIR?"; then
    echo "  Cancelled."
    exit 0
fi

# Delete everything except purge.sh (which deletes itself last)
find "$SCRIPT_DIR" -mindepth 1 -not -name "purge.sh" -exec rm -rf {} + 2>/dev/null || true

echo ""
gum style --foreground 2 "  [OK] Setup files removed"
gum style --foreground 240 "  Config and logs are preserved (delete manually if needed):"
printf "    %s\n" "~/.vps_setup_summary"
printf "    %s\n" "/var/log/vps_setup.log"
printf "    %s  (contains SSH port, username)\n" "/root/.vps_hardening_config"
echo ""

# Self-delete
rm -f "$0"
