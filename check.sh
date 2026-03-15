#!/bin/bash
# VPS Hardening Check - Post-install security audit
# Verifies that all hardening measures are properly applied
# Usage: ./check.sh

set -euo pipefail

VERSION="4.0.0"

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
    ((PASS_COUNT++)) || true
}

fail() {
    gum style --foreground 1 --bold "  [FAIL] $1"
    ((FAIL_COUNT++)) || true
}

warn_check() {
    gum style --foreground 3 "  [WARN] $1"
    ((WARN_COUNT++)) || true
}

section() {
    echo ""
    gum style --bold --foreground 6 "  $1"
    gum style --foreground 240 "  ──────────────────────────────────────────────"
}

# === HEADER ===
echo ""
gum style \
    --border rounded \
    --border-foreground 4 \
    --padding "0 4" \
    --margin "0 2" \
    --bold \
    --align center \
    "VPS HARDENING CHECK" \
    "Post-install security audit"

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
        warn_check "AllowUsers not yet set (normal if final SSH confirmation not done)"
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

if /usr/sbin/sshd -t 2>/dev/null; then
    pass "SSH config valid"
else
    fail "SSH config validation failed -- run: sudo /usr/sbin/sshd -t"
fi

if systemctl is-enabled ssh.socket &>/dev/null 2>&1; then
    warn_check "SSH socket still enabled (should use ssh.service)"
else
    pass "SSH socket disabled"
fi

if [ -f /etc/tmpfiles.d/sshd.conf ] && grep -q "/run/sshd" /etc/tmpfiles.d/sshd.conf 2>/dev/null; then
    pass "Boot safety: /run/sshd created via tmpfiles.d"
else
    warn_check "/run/sshd tmpfiles.d config missing -- sshd may fail after reboot"
fi

if grep -q "Ciphers" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
    pass "SSH strong ciphers configured"
else
    warn_check "SSH ciphers not explicitly configured"
fi

if grep -q "MACs" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
    pass "SSH MACs configured"
else
    warn_check "SSH MACs not explicitly configured"
fi

if grep -q "PermitEmptyPasswords no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
    pass "Empty passwords disabled"
else
    fail "Empty passwords NOT disabled"
fi

if grep -q "LogLevel VERBOSE" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
    pass "SSH LogLevel VERBOSE"
else
    warn_check "SSH LogLevel not set to VERBOSE"
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
check_sysctl "net.ipv4.conf.default.rp_filter" "1" "IP spoofing protection (default)"
check_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1" "ICMP broadcast ignored"
check_sysctl "net.ipv4.tcp_syncookies" "1" "SYN cookies enabled"
check_sysctl "net.ipv4.tcp_max_syn_backlog" "2048" "SYN backlog"
check_sysctl "net.ipv4.tcp_synack_retries" "2" "SYN ACK retries"
check_sysctl "net.ipv4.conf.all.accept_redirects" "0" "ICMP redirects blocked"
check_sysctl "net.ipv4.conf.default.accept_redirects" "0" "ICMP redirects blocked (default)"
check_sysctl "net.ipv4.conf.all.send_redirects" "0" "Send redirects disabled"
check_sysctl "net.ipv4.conf.all.accept_source_route" "0" "Source routing disabled"
check_sysctl "net.ipv4.conf.default.accept_source_route" "0" "Source routing disabled (default)"
check_sysctl "net.ipv4.conf.all.log_martians" "1" "Martian packet logging"
check_sysctl "net.ipv4.conf.default.log_martians" "1" "Martian packet logging (default)"
check_sysctl "net.ipv6.conf.all.accept_redirects" "0" "IPv6 ICMP redirects blocked"
check_sysctl "net.ipv6.conf.default.accept_redirects" "0" "IPv6 ICMP redirects blocked (default)"
check_sysctl "net.ipv6.conf.all.accept_source_route" "0" "IPv6 source routing disabled"
check_sysctl "kernel.randomize_va_space" "2" "ASLR full randomization"
check_sysctl "kernel.dmesg_restrict" "1" "Dmesg restricted"
check_sysctl "kernel.kptr_restrict" "2" "Kernel pointers restricted"
check_sysctl "kernel.sysrq" "0" "SysRq disabled"
check_sysctl "kernel.yama.ptrace_scope" "1" "Ptrace restricted"
check_sysctl "net.ipv4.icmp_ignore_bogus_error_responses" "1" "Bogus ICMP errors ignored"
check_sysctl "fs.suid_dumpable" "0" "Core dumps disabled (suid)"

# === CORE DUMPS ===
section "Core Dumps"

if [ -f /etc/security/limits.d/no-core.conf ] && grep -q "hard core 0" /etc/security/limits.d/no-core.conf 2>/dev/null; then
    pass "Core dumps disabled via limits.d"
else
    fail "Core dumps NOT disabled in limits.d"
fi

# === /tmp HARDENING ===
section "/tmp Hardening"

if mount | grep -q "/tmp.*noexec"; then
    pass "/tmp mounted with noexec"
else
    warn_check "/tmp not mounted with noexec (may require reboot)"
fi

if grep -q "tmpfs.*/tmp.*noexec" /etc/fstab 2>/dev/null; then
    pass "/tmp hardening in fstab (noexec,nosuid,nodev)"
else
    fail "/tmp hardening NOT in fstab"
fi

# === USB STORAGE ===
section "USB Storage"

if [ -f /etc/modprobe.d/no-usb-storage.conf ] && grep -q "install usb-storage /bin/true" /etc/modprobe.d/no-usb-storage.conf 2>/dev/null; then
    pass "USB storage disabled"
else
    warn_check "USB storage not disabled via modprobe"
fi


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
    TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM_MB" -gt 16384 ]; then
        pass "No swap (intentional -- $(( TOTAL_MEM_MB / 1024 ))GB RAM detected)"
    else
        warn_check "No swap detected"
    fi
fi

CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
if [ "$CURRENT_TZ" = "UTC" ]; then
    pass "Timezone: UTC"
else
    warn_check "Timezone: $CURRENT_TZ (expected UTC)"
fi

# === LOG RETENTION ===
section "Log Retention"

if [ -f /etc/systemd/journald.conf.d/retention.conf ]; then
    if grep -q "MaxRetentionSec" /etc/systemd/journald.conf.d/retention.conf; then
        RETENTION_VAL=$(grep "MaxRetentionSec" /etc/systemd/journald.conf.d/retention.conf | cut -d= -f2)
        pass "journald retention configured ($RETENTION_VAL)"
    else
        fail "journald retention config exists but MaxRetentionSec not set"
    fi
else
    fail "journald retention config not found"
fi

if grep -q "max_log_file_action = ROTATE" /etc/audit/auditd.conf 2>/dev/null; then
    pass "auditd log rotation enabled"
else
    fail "auditd max_log_file_action is not ROTATE"
fi

if [ -f /etc/logrotate.d/ufw-custom ]; then
    pass "Custom logrotate config for UFW"
else
    warn_check "Custom logrotate config for UFW not found"
fi

if [ -f /etc/logrotate.d/fail2ban-custom ]; then
    pass "Custom logrotate config for Fail2Ban"
else
    warn_check "Custom logrotate config for Fail2Ban not found"
fi

if [ -f /etc/logrotate.d/rsyslog-custom ]; then
    pass "Custom logrotate config for syslog/auth.log"
else
    warn_check "Custom logrotate config for syslog/auth.log not found"
fi

# === DOCKER (optional — only checked if installed) ===
if command -v docker &>/dev/null; then
    section "Docker"

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

    if grep -q '"no-new-privileges": true' /etc/docker/daemon.json 2>/dev/null; then
        pass "Docker no-new-privileges enabled"
    else
        fail "Docker no-new-privileges NOT enabled"
    fi

    if [ -f /etc/profile.d/docker-content-trust.sh ] && grep -q "DOCKER_CONTENT_TRUST=1" /etc/profile.d/docker-content-trust.sh 2>/dev/null; then
        pass "Docker Content Trust enabled"
    else
        warn_check "Docker Content Trust not configured"
    fi

    if sudo iptables -L DOCKER-USER -n 2>/dev/null | grep -q "DROP"; then
        pass "DOCKER-USER deny-by-default rule present (IPv4)"
    else
        warn_check "DOCKER-USER DROP rule missing -- Docker containers may be exposed"
    fi

    if sudo ip6tables -L DOCKER-USER -n 2>/dev/null | grep -q "DROP"; then
        pass "DOCKER-USER deny-by-default rule present (IPv6)"
    else
        warn_check "DOCKER-USER IPv6 DROP rule missing -- Docker containers may be exposed on IPv6"
    fi

    if sudo iptables -L DOCKER-USER -n 2>/dev/null | grep -qE "dpt:80|dpt:443"; then
        pass "DOCKER-USER allows ports 80 and 443"
    else
        warn_check "DOCKER-USER missing ACCEPT rules for 80/443"
    fi

    if systemctl is-active docker-firewall &>/dev/null; then
        pass "docker-firewall.service active (DOCKER-USER rules persist across Docker restarts)"
    else
        warn_check "docker-firewall.service not active -- DOCKER-USER rules may be lost after Docker restart"
    fi

    # === DOKPLOY / TRAEFIK (only if Docker is present) ===
    section "Dokploy / Traefik"

    if curl -s --max-time 5 http://localhost:3000 &>/dev/null; then
        pass "Dokploy responding on port 3000"
    else
        warn_check "Dokploy not responding on port 3000 (not installed or stopped)"
    fi

    if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q traefik; then
        pass "Traefik container running"
    else
        warn_check "Traefik container not running (normal if Dokploy not installed)"
    fi

    if curl -s --max-time 5 http://localhost:80 &>/dev/null || \
       curl -sk --max-time 5 https://localhost:443 &>/dev/null; then
        pass "Web server responding on port 80/443"
    else
        warn_check "Nothing responding on port 80/443 (normal if no app deployed yet)"
    fi
fi

# === SUMMARY ===
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    VERDICT="Your server is fully hardened."
    VERDICT_COLOR=2
elif [ "$FAIL_COUNT" -eq 0 ]; then
    VERDICT="Mostly hardened. Review warnings above."
    VERDICT_COLOR=3
else
    VERDICT="Security issues detected. Fix failures above."
    VERDICT_COLOR=1
fi

gum style \
    --border rounded \
    --border-foreground "$VERDICT_COLOR" \
    --padding "0 2" \
    --margin "0 2" \
    "$(gum style --foreground 2 "PASS: $PASS_COUNT")  $(gum style --foreground 1 "FAIL: $FAIL_COUNT")  $(gum style --foreground 3 "WARN: $WARN_COUNT")  TOTAL: $TOTAL" \
    "$(gum style --bold --foreground "$VERDICT_COLOR" "$VERDICT")"
echo ""
