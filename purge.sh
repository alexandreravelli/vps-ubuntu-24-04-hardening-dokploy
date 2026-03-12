#!/bin/bash
# Remove all setup scripts from the server after hardening is complete
# Usage: sudo ./purge.sh
set -euo pipefail

# === INSTALL GUM IF NEEDED ===
if ! command -v gum &>/dev/null; then
    echo "Installing gum..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq gum
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

if ! gum confirm "Delete all setup files from $SCRIPT_DIR?"; then
    echo "  Cancelled."
    exit 0
fi

# Delete everything except purge.sh (which deletes itself last)
find "$SCRIPT_DIR" -mindepth 1 -not -name "purge.sh" -exec rm -rf {} + 2>/dev/null || true

echo ""
gum style --foreground 2 "  [OK] Setup files removed"
gum style --foreground 240 "  Config and logs are preserved:"
printf "    %s\n" "~/.vps_setup_summary"
printf "    %s\n" "/var/log/vps_setup.log"
printf "    %s\n" "/root/.vps_hardening_config"
echo ""

# Self-delete
rm -f "$0"
