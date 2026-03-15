<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Docker-Ready-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

<h1 align="center">VPS Hardening Script</h1>

<p align="center">
  <strong>Secure your Ubuntu 24.04 VPS in minutes. Optionally deploy Dokploy.</strong><br>
  Two scripts. Clean separation. Hardened OS first, then Docker + Dokploy.<br><br>
  <a href="#-quick-start">Quick Start</a> · <a href="#-requirements">Requirements</a> · <a href="#%EF%B8%8F-what-it-does">What It Does</a> · <a href="#-after-installation">After Installation</a> · <a href="#-security">Security</a> · <a href="#-faq">FAQ</a>
</p>

<p align="center">
  <img src="assets/welcome-screen.png?v=2" alt="VPS Hardening Script welcome screen" width="700">
</p>

---

## 🚀 Quick Start

### Step 1 — Harden the server

Connect to your VPS and run:

```bash
sudo -i
```

```bash
curl -sSL https://raw.githubusercontent.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

This hardens the OS in 7 steps (~5 min). At the end, test your SSH connection on the new port and type `CONFIRM` to lock down.

### Step 2 — Install Docker + Dokploy (optional)

Reconnect on your new SSH port, then:

```bash
sudo ./install-dokploy.sh
```

This installs Docker, configures the DOCKER-USER firewall, and deploys Dokploy (~5 min).

> **Not root?** No worries — both scripts detect this and auto-escalate with `sudo`.

---

## 📝 Requirements

- Fresh **Ubuntu 24.04 LTS** VPS
- User with **sudo** privileges
- SSH public key ready (`ssh-ed25519` or `ssh-rsa`) — or let the script generate one

> **External firewall (OVH, Hetzner, AWS, etc.):** If your VPS provider has a network-level firewall, open these ports in their control panel **before** running the script:

| Port | Protocol | Purpose | When to close |
|------|----------|---------|---------------|
| 22 | TCP | SSH (default, script will move it) | After confirming new SSH port works |
| 80 | TCP | HTTP / SSL certificate validation | Keep open |
| 443 | TCP | HTTPS | Keep open |
| 3000 | TCP | Dokploy initial setup | After configuring your domain + SSL |
| *custom* | TCP | New SSH port (shown at end of setup.sh) | Keep open |

> The exact SSH port is displayed at the end of `setup.sh` and saved in `~/.vps_setup_summary`. Open **only that port** in your provider's firewall — not the entire 50000-60000 range.

---

## ⚙️ What It Does

### setup.sh — Server Hardening

**7 interactive steps** · **~5 minutes** · All prompts handled via an interactive CLI built on [gum](https://github.com/charmbracelet/gum)

```
[========            ] Step 4/7 -- Kernel hardening
```

| # | Step | What happens | Time |
|---|------|-------------|------|
| 1 | **User** | Set hostname + create admin with sudo + strong password policy (12+ chars) | ~30s |
| 2 | **SSH Key** | Paste existing key or generate ed25519 with optional passphrase | ~10s |
| 3 | **System** | apt upgrade, auto-sized swap (2GB ≤4GB RAM / 4GB ≤16GB / skipped >16GB), Quad9 DNS-over-TLS + DNSSEC, UTC timezone | ~2-3min |
| 4 | **Kernel** | sysctl: anti-spoofing, SYN flood, ASLR, ptrace, core dumps, /tmp hardening, USB disable | ~5s |
| 5 | **Tools** | UFW, Fail2Ban, auditd, AppArmor, unattended-upgrades, log retention policy | ~2-3min |
| 6 | **Firewall** | UFW deny-by-default, allow custom SSH port + 80 + 443 | ~5s |
| 7 | **SSH** | Random port 50000-60000, key-only auth, no root login | ~5s |

> After step 7, the script asks you to test your SSH connection on the new port. Only after typing `CONFIRM` will it close port 22 and disable password auth.

### install-dokploy.sh — Docker + Dokploy

**3 steps** · **~5 minutes** · Run after `setup.sh` is complete and you've reconnected on the new SSH port.

| # | Step | What happens | Time |
|---|------|-------------|------|
| 1 | **Docker** | Official APT repo + GPG + Docker Swarm + log rotation + Content Trust | ~2-3min |
| 2 | **Firewall** | DOCKER-USER deny-by-default, allow 80 + 443 + 3000 (temporary) | ~5s |
| 3 | **Dokploy** | Self-hosted PaaS, ready at `http://your-ip:3000` | ~2-5min |

> This script reads the config saved by `setup.sh` (`/root/.vps_hardening_config`) — no need to re-enter anything.

### Why two scripts?

Dokploy's installer (`curl | sh`) can interfere with firewall rules, remove UFW, and restart services unpredictably. Separating the scripts means:

- **Hardening is reliable** — no third-party installer can break your SSH or firewall
- **Dokploy is optional** — use the hardening for any purpose (Coolify, CapRover, plain Docker, or no Docker at all)
- **Easier to debug** — if something breaks, you know which script caused it
- **Post-install recovery** — `install-dokploy.sh` automatically re-verifies UFW, DOCKER-USER, and SSH health after Dokploy finishes

<details>
<summary><strong>🔑 SSH key options (step 2)</strong></summary>

| Option | What happens |
|--------|-------------|
| **Paste existing key** | You paste your `ssh-ed25519` (recommended) or `ssh-rsa` (legacy) public key |
| **Generate new pair** | Script creates an ed25519 pair, displays the private key for you to save, installs the public key, then **securely deletes** the private key with `shred` |

> When generating a new key pair, the script asks if you want to **protect it with a passphrase**. Even if someone gets your private key file, they can't use it without the passphrase.

</details>

---

## 📋 After Installation

### 1. Connect on your new SSH port

The full command is saved in `~/.vps_setup_summary`.

```bash
ssh your-user@your-ip -p <SSH_PORT>
```

> **IPv6 server?** Use brackets: `ssh your-user@[2001:db8::1] -p <SSH_PORT>` — the script handles this automatically in its output.

### 2. Install Docker + Dokploy (optional)

```bash
sudo ./install-dokploy.sh
```

> All scripts are automatically downloaded to your home directory during setup.

### 3. Secure Dokploy

1. Create your admin account at `http://your-ip:3000`
2. **Enable MFA** on your Dokploy account (Settings > Security)
3. Configure your domain + SSL in Dokploy
4. Close port 3000 (only needed for initial setup):

Remove from UFW (host firewall):

```bash
sudo ufw delete allow 3000/tcp
```

Remove from Docker's firewall chain:

```bash
sudo iptables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT
sudo ip6tables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
```

> No `netfilter-persistent save` needed — port 3000 is not in the persistent `docker-firewall.service`, so it won't come back after reboot.

> If using an external firewall, also close port 3000 in your provider's control panel.

5. **Enable Isolated Deployment** on each project (Settings > Project > Isolated Deployment) — prevents containers across projects from communicating with each other.

### 4. Remove default user

Interactive mode — the script lists existing users and lets you choose which one to delete:

```bash
sudo ./cleanup.sh
```

Direct mode — deletes the specified user immediately:

```bash
sudo ./cleanup.sh ubuntu
```

### 5. Run security audit

Checks all hardening settings and reports any misconfiguration:

```bash
sudo ./check.sh
```

### 6. Clean up setup files

Once everything is verified, remove the setup scripts from the server:

```bash
sudo ./purge.sh
```

> This deletes all script files (setup.sh, install-dokploy.sh, cleanup.sh, check.sh, purge.sh) from the server. Your config (`~/.vps_setup_summary`, `/var/log/vps_setup.log`) is preserved.

---

## 🔒 Security

The script covers **5 security layers** plus built-in safety mechanisms. No manual configuration required.

<details>
<summary><strong>🔐 SSH hardening</strong></summary>

| Feature | Details |
|---------|---------|
| Custom port | Random port 50000-60000 |
| Root login disabled | `PermitRootLogin no` |
| Key-only auth | Password auth disabled after confirmation |
| Brute-force protection | MaxAuthTries 3, LoginGraceTime 30s |
| Session control | ClientAliveInterval 300s, ClientAliveCountMax 2, MaxSessions 2 |
| User whitelist | `AllowUsers` restricts to admin only |
| Forwarding disabled | X11, TCP, agent forwarding all off |
| Strong ciphers | Mozilla Modern: chacha20-poly1305, aes256-gcm, curve25519 |
| Extra hardening | PermitEmptyPasswords no, HostbasedAuthentication no, LogLevel VERBOSE |
| Boot safety | `/run/sshd` created via `tmpfiles.d` (prevents privilege separation crash) |

</details>

<details>
<summary><strong>🌐 Network and firewall</strong></summary>

| Feature | Details |
|---------|---------|
| UFW firewall | deny-by-default, allow custom SSH port + 80 + 443 |
| DOCKER-USER chain | deny-by-default for Docker containers, allow 80 + 443 + internal networks — persisted via `docker-firewall.service` (survives Docker restarts) |
| Rate limiting | 6 connections/30s per IP on custom SSH port |
| Fail2Ban | 3 attempts = 1h ban (systemd backend) |
| DNS-over-TLS | Quad9 (9.9.9.9) + DNSSEC |

</details>

<details>
<summary><strong>🧠 Kernel hardening</strong></summary>

| Feature | Details |
|---------|---------|
| Anti-spoofing | `rp_filter`, martian logging |
| SYN flood protection | `tcp_syncookies`, tuned backlog |
| ICMP hardening | Redirects + broadcasts + bogus errors blocked |
| ASLR | Full randomization (level 2) |
| Restricted info | dmesg + kernel pointers restricted, SysRq disabled |
| Ptrace restriction | `yama.ptrace_scope = 1` |
| Core dumps | Disabled (`suid_dumpable = 0` + `limits.d`) |
| /tmp hardening | Mounted with `noexec,nosuid,nodev` |
| USB storage | Disabled via modprobe |

</details>

<details>
<summary><strong>👤 Authentication and monitoring</strong></summary>

| Feature | Details |
|---------|---------|
| Password policy | 12+ chars, mixed case, numbers, symbols |
| Audit logging | sudo, auth, SSH, sudoers, kernel modules, time changes, file deletions, immutable config (`-e 2`) |
| AppArmor | Mandatory access control |
| Auto-updates | Daily security patches (reboot disabled) |
| Log retention | Configurable: 90d / 365d / 2y / custom (journald, auditd, logrotate, Docker) |

</details>

<details>
<summary><strong>🐳 Docker</strong> (via install-dokploy.sh)</summary>

| Feature | Details |
|---------|---------|
| Official install | APT repo with GPG, not `curl \| sh` |
| Docker Swarm | Initialized automatically (required for Traefik/Dokploy) |
| Log rotation | 10MB max, scaled to retention policy (3/7/14 files) |
| Content Trust | `DOCKER_CONTENT_TRUST=1` — image signature verification |
| No privilege escalation | `no-new-privileges` in daemon.json |
| DOCKER-USER firewall | deny-by-default, allow Docker bridge (172.16.0.0/12) + overlay (10.0.0.0/8) subnets |
| Post-install recovery | Automatically re-verifies UFW, DOCKER-USER, SSH, and needrestart after Dokploy |

</details>

<details>
<summary><strong>🛡️ Recovery and safety</strong></summary>

| Feature | Details |
|---------|---------|
| Error trap | Restores SSH access on port 22 if setup fails |
| Config backup | `sshd_config.bak` saved before changes |
| Summary file | `~/.vps_setup_summary` with all details (chmod 600) |
| Double confirmation | `CONFIRM` required before closing port 22 |
| No lockout | Password auth stays on until SSH key is verified |
| Log | Full log saved to `/var/log/vps_setup.log` |
| sshd health check | `install-dokploy.sh` verifies sshd is still alive after Dokploy install |

</details>

---

## ❓ FAQ

<details>
<summary><strong>What if I lose my SSH key?</strong></summary>

Use your VPS provider's console/VNC access, then edit the SSH config and set `PasswordAuthentication yes`:

```bash
sudo nano /etc/ssh/sshd_config.d/hardening.conf
```

Then restart the SSH service:

```bash
sudo systemctl restart ssh
```
</details>

<details>
<summary><strong>What if I forget my SSH port?</strong></summary>

Saved in two places — access via your provider's console:
- `/root/.vps_hardening_config`
- `~/.vps_setup_summary`
</details>

<details>
<summary><strong>What if the script fails mid-way?</strong></summary>

The error trap automatically restores SSH access on port 22. Check `/var/log/vps_setup.log` for details, then re-run on a fresh server.
</details>

<details>
<summary><strong>Can I run the script again?</strong></summary>

The script is designed for fresh installs. Use `check.sh` to verify your server's state instead.
</details>

<details>
<summary><strong>Can I skip Dokploy?</strong></summary>

Yes — just don't run `install-dokploy.sh`. The hardening in `setup.sh` works standalone for any use case.
</details>

<details>
<summary><strong>Can I use Coolify / CapRover instead of Dokploy?</strong></summary>

Yes. Run `setup.sh` for hardening, then install your preferred PaaS manually. The DOCKER-USER firewall setup in `install-dokploy.sh` can serve as a reference for configuring Docker networking securely.
</details>

<details>
<summary><strong>Does it work on other Ubuntu versions?</strong></summary>

Tested on 24.04 LTS only. Ubuntu 22.04 is **not supported** (different SSH service management).
</details>

---

## 📁 Project Structure

| File | Purpose |
|------|---------|
| `setup.sh` | Server hardening (7 steps, standalone) |
| `install-dokploy.sh` | Docker + Dokploy installer (run after setup.sh) |
| `cleanup.sh` | Remove the default user |
| `check.sh` | Post-install security audit |
| `purge.sh` | Remove setup files from server |
| `LICENSE` | MIT license |

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch
3. Make sure `shellcheck -S warning setup.sh install-dokploy.sh cleanup.sh check.sh purge.sh` passes
4. Open a PR using the provided template

---

## 📄 License

MIT — see [LICENSE](LICENSE)

<p align="center">
  <sub>Built with <a href="https://github.com/charmbracelet/gum">gum</a> (Charmbracelet) · Tested on Ubuntu 24.04 LTS</sub>
</p>
