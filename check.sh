#!/bin/bash
# VPS Hardening Check - Post-install security audit
# Verifies that all hardening measures are properly applied
# Usage: ./check.sh

set -euo pipefail

VERSION="3.0.0"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "VPS Hardening Check v$VERSION"
    exit 0
fi

# === INSTALL GUM IF NEEDED ===
if ! command -v gum &>/dev/null; then
    echo "Installing gum..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq gum
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
    gum style --foreground 2 "  [PASS] $1"
    ((PASS_COUNT++))
}

fail() {
    gum style --foreground 1 --bold "  [FAIL] $1"
    ((FAIL_COUNT++))
}

warn_check() {
    gum style --foreground 3 "  [WARN] $1"
    ((WARN_COUNT++))
}

section() {
    echo ""
    printf "  \033[1m%s\033[0m\n" "$1"
    printf "  \033[0;90m%s\033[0m\n" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"
}

# === HEADER ===
echo ""
printf "  \033[1;34m──────────────────────────────────────────────\033[0m\n"
printf "  \033[1;34mVPS HARDENING CHECK  v%s\033[0m\n" "$VERSION"
printf "  \033[0;90mPost-install security audit\033[0m\n"
printf "  \033[1;34m──────────────────────────────────────────────\033[0m\n"

# === SSH ===
section "SSH Configuration"

if [ -f /etc/ssh/sshd_config.d/hardening.conf ]; then
    pass "Hardening config exists"

    if grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "Root login disabled"
    else
        fail "Root login NOT disabled"
    fi

    if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "Password authentication disabled"
    elif grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        warn_check "Password authentication still ENABLED (run final hardening step)"
    fi

    if grep -q "PubkeyAuthentication yes" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "Public key authentication enabled"
    else
        fail "Public key authentication NOT enabled"
    fi

    if grep -q "MaxAuthTries" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "MaxAuthTries configured"
    else
        warn_check "MaxAuthTries not set"
    fi

    if grep -q "AllowUsers" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        ALLOWED=$(grep "AllowUsers" /etc/ssh/sshd_config.d/hardening.conf | awk '{$1=""; print $0}' | xargs)
        pass "AllowUsers restricted to: $ALLOWED"
    else
        warn_check "AllowUsers not configured"
    fi

    SSH_PORT=$(grep "^Port " /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null | tail -1 | awk '{print $2}')
    if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "22" ]; then
        pass "Custom SSH port: $SSH_PORT"
    elif [ "$SSH_PORT" = "22" ]; then
        warn_check "SSH still on default port 22"
    fi

    if grep -q "^Port 22$" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        warn_check "Port 22 still open in SSH config"
    else
        pass "Port 22 removed from SSH config"
    fi
else
    fail "Hardening config file not found"
fi

if systemctl is-active ssh.service &>/dev/null; then
    pass "SSH service running"
else
    fail "SSH service NOT running"
fi

if systemctl is-enabled ssh.socket &>/dev/null 2>&1; then
    warn_check "SSH socket still enabled (should use ssh.service)"
else
    pass "SSH socket disabled"
fi

# === FIREWALL ===
section "Firewall (UFW)"

if sudo ufw status | grep -q "Status: active"; then
    pass "UFW is active"

    if sudo ufw status | grep -q "LIMIT"; then
        pass "Rate limiting enabled on SSH"
    else
        warn_check "No rate limiting detected on SSH port"
    fi

    if sudo ufw status verbose | grep -q "Default: deny (incoming)"; then
        pass "Default policy: deny incoming"
    else
        fail "Default incoming policy is NOT deny"
    fi
else
    fail "UFW is NOT active"
fi

if sudo iptables -L DOCKER-USER -n 2>/dev/null | grep -q "DROP"; then
    pass "DOCKER-USER deny-by-default rule present"
else
    warn_check "DOCKER-USER DROP rule missing -- Docker containers may be exposed"
fi

if sudo iptables -L DOCKER-USER -n 2>/dev/null | grep -qE "dpt:80|dpt:443"; then
    pass "DOCKER-USER allows ports 80 and 443"
else
    warn_check "DOCKER-USER missing ACCEPT rules for 80/443"
fi

# === FAIL2BAN ===
section "Fail2Ban"

if systemctl is-active fail2ban &>/dev/null; then
    pass "Fail2Ban is running"

    if sudo fail2ban-client status sshd &>/dev/null; then
        BANNED=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        pass "SSH jail active (currently banned: $BANNED)"
    else
        fail "SSH jail NOT active"
    fi
else
    fail "Fail2Ban is NOT running"
fi

# === KERNEL HARDENING ===
section "Kernel Hardening (sysctl)"

check_sysctl() {
    local param="$1"
    local expected="$2"
    local label="$3"
    local current
    current=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    if [ "$current" = "$expected" ]; then
        pass "$label ($param = $expected)"
    else
        fail "$label ($param = $current, expected $expected)"
    fi
}

check_sysctl "net.ipv4.conf.all.rp_filter" "1" "IP spoofing protection"
check_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1" "ICMP broadcast ignored"
check_sysctl "net.ipv4.tcp_syncookies" "1" "SYN cookies enabled"
check_sysctl "net.ipv4.conf.all.accept_redirects" "0" "ICMP redirects blocked"
check_sysctl "net.ipv4.conf.all.send_redirects" "0" "Send redirects disabled"
check_sysctl "kernel.randomize_va_space" "2" "ASLR full randomization"
check_sysctl "kernel.dmesg_restrict" "1" "Dmesg restricted"
check_sysctl "kernel.kptr_restrict" "2" "Kernel pointers restricted"

# === APPARMOR ===
section "AppArmor"

if sudo aa-status &>/dev/null; then
    PROFILES=$(sudo aa-status 2>/dev/null | grep "profiles are loaded" | awk '{print $1}')
    ENFORCED=$(sudo aa-status 2>/dev/null | grep "profiles are in enforce mode" | awk '{print $1}')
    pass "AppArmor active ($PROFILES profiles, $ENFORCED enforced)"
else
    fail "AppArmor NOT active"
fi

# === AUTO UPDATES ===
section "Automatic Updates"

if dpkg -l | grep -q unattended-upgrades; then
    pass "unattended-upgrades installed"
else
    fail "unattended-upgrades NOT installed"
fi

if [ -f /etc/apt/apt.conf.d/20auto-upgrades ]; then
    if grep -q 'APT::Periodic::Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
        pass "Auto-upgrades enabled"
    else
        warn_check "Auto-upgrades config exists but may not be enabled"
    fi
else
    fail "Auto-upgrades config not found"
fi

# === AUDIT ===
section "Audit Logging"

if systemctl is-active auditd &>/dev/null; then
    pass "auditd is running"

    if [ -f /etc/audit/rules.d/hardening.rules ]; then
        RULE_COUNT=$(wc -l < /etc/audit/rules.d/hardening.rules)
        pass "Hardening audit rules loaded ($RULE_COUNT rules)"
    else
        warn_check "Custom audit rules file not found"
    fi
else
    fail "auditd is NOT running"
fi

# === PASSWORD POLICY ===
section "Password Policy"

if [ -f /etc/security/pwquality.conf ]; then
    if grep -q "minlen = 12" /etc/security/pwquality.conf; then
        pass "Minimum password length: 12"
    else
        warn_check "Password minimum length may not be 12"
    fi

    if grep -q "enforce_for_root" /etc/security/pwquality.conf; then
        pass "Password policy enforced for root"
    else
        warn_check "Password policy NOT enforced for root"
    fi
else
    fail "pwquality config not found"
fi

# === DNS ===
section "DNS"

if [ -f /etc/systemd/resolved.conf.d/quad9.conf ]; then
    if grep -q "DNSOverTLS=yes" /etc/systemd/resolved.conf.d/quad9.conf; then
        pass "DNS-over-TLS enabled"
    else
        warn_check "DNS-over-TLS not enabled"
    fi

    if grep -q "DNSSEC=yes" /etc/systemd/resolved.conf.d/quad9.conf; then
        pass "DNSSEC enabled"
    else
        warn_check "DNSSEC not enabled"
    fi
else
    warn_check "Quad9 DNS config not found"
fi

# === SWAP ===
section "System"

if swapon --show | grep -q "/swapfile"; then
    SWAP_SIZE=$(swapon --show | grep "/swapfile" | awk '{print $3}')
    pass "Swap active ($SWAP_SIZE)"
else
    warn_check "No swap detected"
fi

CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
if [ "$CURRENT_TZ" = "UTC" ]; then
    pass "Timezone: UTC"
else
    warn_check "Timezone: $CURRENT_TZ (expected UTC)"
fi

# === DOCKER ===
section "Docker"

if command -v docker &>/dev/null; then
    pass "Docker installed ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))"

    if [ -f /etc/docker/daemon.json ]; then
        if grep -q "max-size" /etc/docker/daemon.json; then
            pass "Docker log rotation configured"
        else
            warn_check "Docker log rotation not configured"
        fi
    else
        warn_check "Docker daemon.json not found"
    fi

    if systemctl is-active docker &>/dev/null; then
        pass "Docker service running"
    else
        fail "Docker service NOT running"
    fi

    if sudo docker info 2>/dev/null | grep -q "Swarm: active"; then
        pass "Docker Swarm active (required for Traefik)"
    else
        fail "Docker Swarm NOT active -- Traefik cannot start (run: docker swarm init)"
    fi
else
    fail "Docker NOT installed"
fi

# === DOKPLOY / TRAEFIK ===
section "Dokploy / Traefik"

if curl -s --max-time 5 http://localhost:3000 &>/dev/null; then
    pass "Dokploy responding on port 3000"
else
    warn_check "Dokploy not responding on port 3000"
fi

if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q traefik; then
    pass "Traefik container running"
else
    fail "Traefik container NOT running -- ports 80/443 are dead"
fi

if curl -s --max-time 5 http://localhost:80 &>/dev/null || \
   curl -sk --max-time 5 https://localhost:443 &>/dev/null; then
    pass "Web server responding on port 80/443"
else
    fail "Nothing responding on port 80/443 -- check Traefik"
fi

# === SUMMARY ===
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo ""
printf "  \033[1m──────────────────────────────────────────────\033[0m\n"
printf "  PASS: \033[0;32m%s\033[0m  FAIL: \033[0;31m%s\033[0m  WARN: \033[0;33m%s\033[0m  TOTAL: %s\n" \
    "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$TOTAL"
printf "  \033[1m──────────────────────────────────────────────\033[0m\n"
echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    printf "  \033[1;32mYour server is fully hardened.\033[0m\n"
elif [ "$FAIL_COUNT" -eq 0 ]; then
    printf "  \033[1;33mYour server is mostly hardened. Review warnings above.\033[0m\n"
else
    printf "  \033[1;31mYour server has security issues. Fix failures above.\033[0m\n"
fi
echo ""
