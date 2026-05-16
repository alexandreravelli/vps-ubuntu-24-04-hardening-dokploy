#!/bin/bash
# VPS Hardening Check - Post-install security audit
# Verifies that all hardening measures are properly applied
# Usage: ./check.sh

set -euo pipefail

VERSION="1.0.14"

if [[ "${1:-}" == "--version" || "${1:-}" == "-v" ]]; then
    echo "VPS Hardening Check v$VERSION"
    exit 0
fi

# === ROOT CHECK ===
if [ "$(id -u)" -ne 0 ]; then
    echo "This script needs root privileges for accurate results."
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

check_ssh_permissions_for_user() {
    local user="$1"
    local home_dir
    home_dir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)

    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
        warn_check "Cannot inspect SSH permissions for '$user' (home directory not found)"
        return
    fi

    local ssh_dir="$home_dir/.ssh"
    local authorized_keys="$ssh_dir/authorized_keys"

    if [ ! -d "$ssh_dir" ]; then
        warn_check "$user: ~/.ssh directory not found"
        return
    fi

    local ssh_mode ssh_owner keys_mode keys_owner
    ssh_mode=$(sudo stat -c '%a' "$ssh_dir" 2>/dev/null || echo "unknown")
    ssh_owner=$(sudo stat -c '%U' "$ssh_dir" 2>/dev/null || echo "unknown")

    if [ "$ssh_mode" = "700" ]; then
        pass "$user: ~/.ssh permissions are 700"
    else
        warn_check "$user: ~/.ssh permissions are $ssh_mode (expected 700)"
    fi

    if [ "$ssh_owner" = "$user" ]; then
        pass "$user: ~/.ssh owner is correct"
    else
        warn_check "$user: ~/.ssh owner is $ssh_owner (expected $user)"
    fi

    if [ ! -f "$authorized_keys" ]; then
        warn_check "$user: authorized_keys not found"
        return
    fi

    keys_mode=$(sudo stat -c '%a' "$authorized_keys" 2>/dev/null || echo "unknown")
    keys_owner=$(sudo stat -c '%U' "$authorized_keys" 2>/dev/null || echo "unknown")

    if [ "$keys_mode" = "600" ]; then
        pass "$user: authorized_keys permissions are 600"
    else
        warn_check "$user: authorized_keys permissions are $keys_mode (expected 600)"
    fi

    if [ "$keys_owner" = "$user" ]; then
        pass "$user: authorized_keys owner is correct"
    else
        warn_check "$user: authorized_keys owner is $keys_owner (expected $user)"
    fi
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

    if grep -q "^AllowUsers" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        ALLOWED=$(grep "^AllowUsers" /etc/ssh/sshd_config.d/hardening.conf | awk '{$1=""; print $0}' | xargs)
        if [ -n "$ALLOWED" ]; then
            pass "AllowUsers restricted to: $ALLOWED"
        else
            fail "AllowUsers is configured but empty"
        fi
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

if systemctl is-active ssh.service &>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
    pass "SSH is running"
else
    fail "SSH is NOT running (neither ssh.service nor ssh.socket active)"
fi

if /usr/sbin/sshd -t 2>/dev/null; then
    pass "SSH config valid"
else
    fail "SSH config validation failed -- run: sudo /usr/sbin/sshd -t"
fi

if [ -f /etc/systemd/system/ssh.socket.d/override.conf ]; then
    SOCKET_STREAMS=$(grep "^ListenStream=" /etc/systemd/system/ssh.socket.d/override.conf | grep -v "^ListenStream=$" || true)
    if [ -z "$SOCKET_STREAMS" ]; then
        fail "SSH socket override exists but has no configured ListenStream port"
    elif [ -n "${SSH_PORT:-}" ] && ! printf '%s\n' "$SOCKET_STREAMS" | grep -Eq "(:|=)$SSH_PORT$"; then
        warn_check "SSH socket override does not reference SSH port $SSH_PORT"
    else
        pass "SSH socket reconfigured ($(printf '%s' "$SOCKET_STREAMS" | xargs))"
    fi
else
    warn_check "SSH socket override not found -- may revert to port 22 after reboot"
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

if grep -q "TCPKeepAlive no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "TCPKeepAlive disabled"
    else
        warn_check "TCPKeepAlive not disabled"
    fi

    if grep -q "Banner /etc/issue.net" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
        pass "SSH banner configured"
    else
        warn_check "SSH banner not configured"
    fi

    if grep -q "AllowTcpForwarding local" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
    pass "TCP forwarding restricted to local only"
elif grep -q "AllowTcpForwarding no" /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null; then
    pass "TCP forwarding fully disabled"
else
    warn_check "AllowTcpForwarding not restricted"
fi

section "SSH Key Permissions"

SSH_USERS=""
if [ -f /etc/ssh/sshd_config.d/hardening.conf ]; then
    SSH_USERS=$(grep "^AllowUsers " /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null | awk '{$1=""; print $0}' | xargs || true)
fi
if [ -z "$SSH_USERS" ] && sudo test -f /root/.vps_hardening_config 2>/dev/null; then
    SSH_USERS=$(sudo grep "^NEW_USER=" /root/.vps_hardening_config 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi

if [ -n "$SSH_USERS" ]; then
    for ssh_user in $SSH_USERS; do
        check_ssh_permissions_for_user "$ssh_user"
    done
else
    warn_check "No admin SSH user found in AllowUsers or /root/.vps_hardening_config"
fi

# === FIREWALL ===
section "Firewall (UFW)"

if sudo ufw status | grep -q "Status: active"; then
    pass "UFW is active"

    SSH_PORT_CHECK=$(grep "^Port " /etc/ssh/sshd_config.d/hardening.conf 2>/dev/null | tail -1 | awk '{print $2}')
    if [ -n "$SSH_PORT_CHECK" ] && sudo ufw status | grep -q "$SSH_PORT_CHECK.*LIMIT"; then
        pass "Rate limiting enabled on SSH port $SSH_PORT_CHECK"
    elif sudo ufw status | grep -q "LIMIT"; then
        warn_check "Rate limiting exists but may not be on custom SSH port"
    else
        warn_check "No rate limiting detected on SSH port"
    fi

    if sudo ufw status verbose | grep -q "Default: deny (incoming)"; then
        pass "Default policy: deny incoming"
    else
        fail "Default incoming policy is NOT deny"
    fi

    if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        if grep -qE '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
            pass "UFW IPv6 support enabled"
        else
            warn_check "Global IPv6 detected but UFW IPv6 support is not enabled (/etc/default/ufw IPV6=yes)"
        fi

        if sudo ufw status | grep -q "(v6)"; then
            pass "UFW has IPv6 rules loaded"
        else
            warn_check "Global IPv6 detected but no UFW IPv6 rules are visible"
        fi
    else
        pass "No global IPv6 address detected"
    fi
else
    fail "UFW is NOT active"
fi

# === SUDO ===
section "Sudo"

NOPASSWD_ENTRIES=$(sudo grep -RhsE '^[[:space:]]*[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d 2>/dev/null || true)
if [ -n "$NOPASSWD_ENTRIES" ]; then
    warn_check "Passwordless sudo entries found"
    printf '%s\n' "$NOPASSWD_ENTRIES" | sed 's/^/    /'
    warn_check "Review these entries and remove old default users with cleanup.sh when safe"
else
    pass "No passwordless sudo entries found"
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

    if [ -f /etc/fail2ban/jail.local ]; then
        F2B_BANTIME=$(grep "^bantime" /etc/fail2ban/jail.local 2>/dev/null | head -1 | awk '{print $NF}')
        if [ -n "$F2B_BANTIME" ] && [ "$F2B_BANTIME" -ge 86400 ] 2>/dev/null; then
            pass "Fail2Ban bantime >= 24h ($F2B_BANTIME seconds)"
        elif [ -n "$F2B_BANTIME" ]; then
            warn_check "Fail2Ban bantime is only $F2B_BANTIME seconds (recommend >= 86400)"
        fi
        if grep -q "bantime.increment" /etc/fail2ban/jail.local 2>/dev/null; then
            pass "Fail2Ban progressive ban enabled"
        else
            warn_check "Fail2Ban progressive ban not configured"
        fi
    fi
else
    if systemctl is-active crowdsec &>/dev/null && systemctl is-active crowdsec-firewall-bouncer &>/dev/null; then
        pass "CrowdSec + firewall bouncer active (Fail2Ban alternative)"
    else
        fail "Neither Fail2Ban nor CrowdSec firewall bouncer is running"
    fi
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
check_sysctl "kernel.perf_event_paranoid" "3" "Perf events restricted"
check_sysctl "net.core.bpf_jit_harden" "2" "BPF JIT hardened"
check_sysctl "dev.tty.ldisc_autoload" "0" "TTY line discipline autoload disabled"
check_sysctl "fs.protected_fifos" "2" "FIFO protection enabled"

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
elif grep -q "tmpfs.*/tmp.*noexec" /etc/fstab 2>/dev/null; then
    warn_check "/tmp noexec in fstab but not active (reboot needed)"
else
    # noexec on /tmp is intentionally skipped when Docker/Dokploy is the target
    if command -v docker &>/dev/null; then
        pass "/tmp noexec skipped (Docker/Dokploy compatibility)"
    else
        warn_check "/tmp noexec not configured (optional — enable manually if no Docker)"
    fi
fi

# === USB STORAGE ===
section "USB Storage"

if [ -f /etc/modprobe.d/no-usb-storage.conf ] && grep -q "install usb-storage /bin/true" /etc/modprobe.d/no-usb-storage.conf 2>/dev/null; then
    pass "USB storage disabled"
else
    warn_check "USB storage not disabled via modprobe"
fi


# === DISABLED PROTOCOLS ===
section "Disabled Protocols"

if [ -f /etc/modprobe.d/hardening.conf ]; then
    for proto in dccp sctp rds tipc; do
        if grep -q "install $proto /bin/true" /etc/modprobe.d/hardening.conf 2>/dev/null; then
            pass "$proto protocol disabled"
        else
            fail "$proto protocol NOT disabled"
        fi
    done
else
    fail "Protocol hardening config not found (/etc/modprobe.d/hardening.conf)"
fi

# === LEGAL BANNER ===
section "Legal Banner"

if [ -f /etc/issue.net ] && grep -q "Authorized access only" /etc/issue.net 2>/dev/null; then
    pass "Legal banner configured (/etc/issue.net)"
else
    fail "Legal banner NOT configured in /etc/issue.net"
fi

if [ -f /etc/issue ] && grep -q "Authorized access only" /etc/issue 2>/dev/null; then
    pass "Legal banner configured (/etc/issue)"
else
    fail "Legal banner NOT configured in /etc/issue"
fi

# === UMASK ===
section "Umask"

if grep -qE '^UMASK\s+027' /etc/login.defs 2>/dev/null; then
    pass "Default umask set to 027"
else
    fail "Default umask NOT set to 027 in /etc/login.defs"
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

if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
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

    if grep -qE "DNSSEC=(yes|allow-downgrade)" /etc/systemd/resolved.conf.d/quad9.conf; then
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

    DOCKER_GROUP_USERS=$(getent group docker 2>/dev/null | cut -d: -f4)
    if [ -z "$DOCKER_GROUP_USERS" ]; then
        pass "Strict Docker CLI mode active (no users in docker group)"
    else
        warn_check "Users in docker group have root-equivalent Docker access: $DOCKER_GROUP_USERS"
        warn_check "Strict mode: remove users from docker group and use sudo docker"
    fi

    DOCKER_PUBLIC_PORTS="80/tcp 443/tcp"
    DOCKER_PUBLIC_PORTS_CONFIG="/etc/vps-hardening/docker-public-ports.conf"
    if [ -f "$DOCKER_PUBLIC_PORTS_CONFIG" ]; then
        while read -r port_proto _label; do
            [ -n "${port_proto:-}" ] || continue
            case "$port_proto" in \#*) continue ;; esac
            if echo "$port_proto" | grep -qE '^[0-9]+/(tcp|udp)$' &&
               ! printf '%s\n' $DOCKER_PUBLIC_PORTS | grep -Fxq "$port_proto"; then
                DOCKER_PUBLIC_PORTS="$DOCKER_PUBLIC_PORTS $port_proto"
            fi
        done < "$DOCKER_PUBLIC_PORTS_CONFIG"
        pass "Docker public ports config loaded ($DOCKER_PUBLIC_PORTS_CONFIG)"
    else
        pass "Docker public ports config not found; using defaults (80/tcp 443/tcp)"
    fi

    check_docker_user_order() {
        local cmd="$1"
        local label="$2"
        local internal_source_regex="$3"
        local configured_ports="$4"
        local rules
        local rule_count
        local drop_line
        local missing_ports=""
        local port_proto
        local port
        local proto
        local port_line
        local unexpected_accepts

        rules=$(sudo "$cmd" -S DOCKER-USER 2>/dev/null | grep "^-A DOCKER-USER " || true)
        if [ -z "$rules" ]; then
            fail "DOCKER-USER chain missing or empty ($label)"
            return
        fi

        rule_count=$(printf '%s\n' "$rules" | wc -l | xargs)
        drop_line=$(printf '%s\n' "$rules" | awk '/ -j DROP$/ { line = NR } END { print line }')

        if [ -z "$drop_line" ]; then
            fail "DOCKER-USER missing final DROP rule ($label)"
            return
        fi

        if [ "$drop_line" -eq "$rule_count" ]; then
            pass "DOCKER-USER final DROP rule is last ($label)"
        else
            fail "DOCKER-USER DROP rule is not last ($label)"
        fi

        if printf '%s\n' "$rules" | awk '/--dport 3000/ && / -j ACCEPT$/ { found = 1 } END { exit !found }'; then
            fail "DOCKER-USER still allows Dokploy setup port 3000 ($label)"
        else
            pass "DOCKER-USER does not expose Dokploy setup port 3000 ($label)"
        fi

        for port_proto in $configured_ports; do
            port="${port_proto%/*}"
            proto="${port_proto#*/}"
            port_line=$(printf '%s\n' "$rules" | awk -v port="$port" -v proto="$proto" '
                $0 ~ ("-p " proto " ") && $0 ~ ("--dport " port " ") && / -j ACCEPT$/ {
                    print NR
                    exit
                }
            ')

            if [ -z "$port_line" ] || [ "$port_line" -gt "$drop_line" ]; then
                missing_ports="$missing_ports $port_proto"
            fi
        done

        if [ -z "$missing_ports" ]; then
            pass "DOCKER-USER allows configured public ports before DROP ($label): $configured_ports"
        else
            fail "DOCKER-USER missing configured public ports before DROP ($label):$(printf '%s' "$missing_ports")"
        fi

        unexpected_accepts=$(
            printf '%s\n' "$rules" | awk \
                -v drop_line="$drop_line" \
                -v internal_source_regex="$internal_source_regex" \
                -v configured_ports="$configured_ports" '
                function is_configured_public_port(rule, parts, pair, i, port, proto) {
                    split(configured_ports, parts, " ")
                    for (i in parts) {
                        split(parts[i], pair, "/")
                        port = pair[1]
                        proto = pair[2]
                        if (rule ~ ("-p " proto " ") && rule ~ ("--dport " port " ")) {
                            return 1
                        }
                    }
                    return 0
                }
                NR < drop_line && / -j ACCEPT$/ {
                    if ($0 ~ /--ctstate RELATED,ESTABLISHED/) next
                    if ($0 ~ /-i lo /) next
                    if (is_configured_public_port($0)) next
                    if ($0 ~ internal_source_regex) next
                    print
                }
            '
        )

        if [ -n "$unexpected_accepts" ]; then
            fail "DOCKER-USER has unexpected ACCEPT rules before DROP ($label)"
            printf '%s\n' "$unexpected_accepts" | sed 's/^/    /'
        else
            pass "DOCKER-USER has no broad ACCEPT before DROP ($label)"
        fi
    }

    check_docker_user_order "iptables" "IPv4" "-s (172\\.16\\.0\\.0/12|10\\.0\\.0\\.0/8)" "$DOCKER_PUBLIC_PORTS"
    check_docker_user_order "ip6tables" "IPv6" "-s fd00::/8" "$DOCKER_PUBLIC_PORTS"

    if systemctl is-active docker-firewall &>/dev/null; then
        pass "docker-firewall.service active (DOCKER-USER rules persist across Docker restarts)"
    else
        warn_check "docker-firewall.service not active -- DOCKER-USER rules may be lost after Docker restart"
    fi

    if sudo iptables -L DOCKER-USER -n 2>/dev/null | grep -q "172.16.0.0/12"; then
        pass "DOCKER-USER allows Docker bridge networks (172.16.0.0/12)"
    else
        warn_check "DOCKER-USER missing Docker bridge network rule (172.16.0.0/12)"
    fi

    if sudo ip6tables -L DOCKER-USER -n 2>/dev/null | grep -q "fd00::/8"; then
        pass "DOCKER-USER allows Docker internal IPv6 (fd00::/8)"
    else
        warn_check "DOCKER-USER missing Docker internal IPv6 rule (fd00::/8)"
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

# === NEEDRESTART SSH PROTECTION ===
section "Needrestart SSH Protection"

if [ -f /etc/needrestart/conf.d/99-no-ssh-restart.conf ]; then
    if grep -q 'q(ssh)' /etc/needrestart/conf.d/99-no-ssh-restart.conf 2>/dev/null; then
        pass "Needrestart SSH protection active (prevents SSH restart during upgrades)"
    else
        warn_check "Needrestart SSH config exists but may not protect SSH"
    fi
else
    warn_check "Needrestart SSH protection not configured (apt upgrades may restart SSH)"
fi

# === SETUP CLEANUP ===
section "Setup Cleanup"

if [ -f /etc/ssh/sshd_config.d/zz-setup-keepalive.conf ] || [ -f /etc/ssh/sshd_test_config ]; then
    warn_check "Temporary setup files still present (should be removed after CONFIRM)"
else
    pass "No temporary setup files left behind"
fi

if [ -f /run/sshd-hardened.pid ]; then
    if kill -0 "$(cat /run/sshd-hardened.pid)" 2>/dev/null; then
        warn_check "Standalone sshd still running (should be stopped after CONFIRM)"
    else
        warn_check "Stale sshd PID file exists (run: sudo rm -f /run/sshd-hardened.pid)"
    fi
else
    pass "No standalone sshd running"
fi

# === SUMMARY ===
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

echo ""
if [ "$FAIL_COUNT" -eq 0 ] && [ "$WARN_COUNT" -eq 0 ]; then
    VERDICT="All configured hardening checks passed."
    VERDICT_COLOR=2
elif [ "$FAIL_COUNT" -eq 0 ]; then
    VERDICT="Mostly hardened. Review warnings above."
    VERDICT_COLOR=3
else
    VERDICT="Some hardening checks failed. Review failures above."
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
