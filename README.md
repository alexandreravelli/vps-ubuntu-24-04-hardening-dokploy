<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Docker-Ready-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

<h1 align="center">VPS Hardening Script</h1>

<p align="center">
  <strong>Secure your Ubuntu 24.04 VPS and deploy Dokploy in minutes.</strong><br>
  One script. 9 steps. Hardened OS + Dokploy PaaS in ~10 minutes.<br><br>
  <a href="#-requirements">Requirements</a> · <a href="#-quick-start">Quick Start</a> · <a href="#%EF%B8%8F-what-it-does">What It Does</a> · <a href="#-security">Security</a> · <a href="#-ssh-key-options">SSH Keys</a> · <a href="#-after-installation">Post-Install</a> · <a href="#-faq">FAQ</a>
</p>

<p align="center">
  <img src="assets/welcome-screen.png" alt="VPS Hardening Script welcome screen" width="700">
</p>

---

## 💡 Why?

Most VPS come with a bare OS and no security. Hardening one manually takes hours and is easy to get wrong. This script does it all interactively, with an interactive CLI built on [gum](https://github.com/charmbracelet/gum) for prompts and spinners, and deploys [Dokploy](https://dokploy.com) (self-hosted PaaS) on top.

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
| *custom* | TCP | New SSH port (shown at end of script) | Keep open |

> The exact SSH port is displayed at the end of the script and saved in `~/.vps_setup_summary`. Open **only that port** in your provider's firewall — not the entire 50000-60000 range.

---

## 🚀 Quick Start

Connect to your VPS and run:

```bash
sudo -i  # switch to root (required)
```

```bash
curl -sSL https://raw.githubusercontent.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

> **Not root?** No worries -- the script detects this and auto-escalates with `sudo`.

---

## ⚙️ What It Does

**9 interactive steps** · **~10 minutes** · All prompts handled via CLI — no config files to edit

```
[========            ] Step 4/9 -- Kernel hardening
```

| # | Step | What happens | Time |
|---|------|-------------|------|
| 1 | **User** | Create admin with sudo + strong password policy (12+ chars) | ~30s |
| 2 | **SSH Key** | Paste existing key or generate ed25519 with optional passphrase | ~10s |
| 3 | **System** | apt upgrade, auto-sized swap (2GB ≤4GB RAM / 4GB ≤16GB / skipped >16GB), Quad9 DNS-over-TLS + DNSSEC, UTC timezone | ~2-3min |
| 4 | **Kernel** | sysctl: anti-spoofing, SYN flood protection, ASLR, dmesg restrict | ~5s |
| 5 | **Tools** | UFW, Fail2Ban, auditd, AppArmor, unattended-upgrades, log retention policy | ~1-2min |
| 6 | **Firewall** | UFW deny-by-default, allow custom SSH port + 80 + 443 + 3000 | ~5s |
| 7 | **SSH** | Random port 50000-60000, key-only auth, no root login | ~5s |
| 8 | **Docker** | Official APT repo + GPG + Docker Swarm + `docker-firewall.service` (DOCKER-USER deny-by-default, persisted across Docker restarts) | ~2-3min |
| 9 | **Dokploy** | Self-hosted PaaS, ready at `http://your-ip:3000` | ~1-2min |

> ⚠️ **After step 9**, the script asks you to test your SSH connection on the new port. Only after typing `CONFIRM` will it close port 22 and disable password auth.

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
| Session control | ClientAliveInterval 300s, ClientAliveCountMax 2 |
| User whitelist | `AllowUsers` restricts to admin only |
| Forwarding disabled | X11 + TCP forwarding off |

</details>

<details>
<summary><strong>🌐 Network and firewall</strong></summary>

| Feature | Details |
|---------|---------|
| UFW firewall | deny-by-default, allow custom SSH port + 80 + 443 + 3000 |
| DOCKER-USER chain | deny-by-default for Docker containers, allow 80 + 443 + internal networks — persisted via `docker-firewall.service` (survives Docker restarts) |
| Rate limiting | 6 connections/30s per IP on custom SSH port |
| Fail2Ban | 3 attempts = 1h ban |
| DNS-over-TLS | Quad9 (9.9.9.9) + DNSSEC |

</details>

<details>
<summary><strong>🧠 Kernel hardening</strong></summary>

| Feature | Details |
|---------|---------|
| Anti-spoofing | `rp_filter`, martian logging |
| SYN flood protection | `tcp_syncookies`, tuned backlog |
| ICMP hardening | Redirects + broadcasts blocked |
| ASLR | Full randomization (level 2) |
| Restricted info | dmesg + kernel pointers restricted |

</details>

<details>
<summary><strong>👤 Authentication and monitoring</strong></summary>

| Feature | Details |
|---------|---------|
| Password policy | 12+ chars, mixed case, numbers, symbols |
| Audit logging | sudo, auth, SSH, user/group changes |
| AppArmor | Mandatory access control |
| Auto-updates | Daily security patches |
| Log retention | Configurable: 90d / 365d / 2y / custom (journald, auditd, logrotate, Docker) |

</details>

<details>
<summary><strong>🐳 Docker</strong></summary>

| Feature | Details |
|---------|---------|
| Official install | APT repo with GPG, not `curl \| sh` |
| Docker Swarm | Initialized automatically (required for Traefik/Dokploy) |
| Log rotation | 10MB max, scaled to retention policy (3/7/14 files) |

</details>

<details>
<summary><strong>🛡️ Recovery and safety</strong></summary>

| Feature | Details |
|---------|---------|
| Error trap | Restores SSH access on port 22 if setup fails |
| Config backup | `sshd_config.bak` saved before changes |
| Summary file | `~/.vps_setup_summary` with all details |
| Double confirmation | `CONFIRM` required before closing port 22 |
| No lockout | Password auth stays on until SSH key is verified |
| Log | Full log saved to `/var/log/vps_setup.log` |

</details>

---

## 🔑 SSH Key Options

At step 2, you choose:

| Option | What happens |
|--------|-------------|
| **Paste existing key** | You paste your `ssh-ed25519` (recommended) or `ssh-rsa` (legacy) public key |
| **Generate new pair** | Script creates an ed25519 pair, displays the private key for you to save, installs the public key, then **securely deletes** the private key with `shred` |

> When generating a new key pair, the script asks if you want to **protect it with a passphrase**. Even if someone gets your private key file, they can't use it without the passphrase.

---

## 📋 After Installation

### Connect to your server

```bash
ssh your-user@your-ip -p <SSH_PORT>
# Full command is saved in ~/.vps_setup_summary
```

> **IPv6 server?** Use brackets: `ssh your-user@[2001:db8::1] -p <SSH_PORT>` — the script handles this automatically in its output.

### Remove default user

> `cleanup.sh` and `check.sh` are automatically downloaded to your home directory during setup.

```bash
sudo ./cleanup.sh          # interactive
sudo ./cleanup.sh ubuntu   # direct
```

### Run security audit

```bash
sudo ./check.sh
```

```
  [PASS] Root login disabled
  [PASS] Password authentication disabled
  [PASS] Custom SSH port: 54821
  ...
  PASS: 28  FAIL: 0  WARN: 1  TOTAL: 29
```

### Secure Dokploy

1. Create your admin account at `http://your-ip:3000`
2. **Enable MFA** on your Dokploy account (Settings > Security)
3. Configure your domain + SSL in Dokploy
4. Close port 3000 (only needed for initial setup):

```bash
# Remove from UFW (host firewall)
sudo ufw delete allow 3000/tcp
# Remove from Docker's firewall chain
sudo iptables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT
sudo ip6tables -D DOCKER-USER -p tcp --dport 3000 -j ACCEPT 2>/dev/null || true
```

> No `netfilter-persistent save` needed — port 3000 is not in the persistent `docker-firewall.service`, so it won't come back after reboot.

> If using an external firewall, also close port 3000 in your provider's control panel.

### Best Practices

- **Enable Isolated Deployment** on each project (Settings > Project > Isolated Deployment) — prevents containers across projects from communicating with each other.

---

## 📁 Project Structure

```
.
├── setup.sh        # Main hardening script (interactive CLI)
├── cleanup.sh      # Remove the default user
├── check.sh        # Post-install security audit
└── LICENSE
```

---

## ❓ FAQ

<details>
<summary><strong>What if I lose my SSH key?</strong></summary>

Use your VPS provider's console/VNC access, then:

```bash
sudo nano /etc/ssh/sshd_config.d/hardening.conf
# Change PasswordAuthentication to yes
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

Yes. Comment out step 9 in `setup.sh` and remove port 3000 from the firewall rules.
</details>

<details>
<summary><strong>Does it work on other Ubuntu versions?</strong></summary>

Tested on 24.04 LTS only. Ubuntu 22.04 is **not supported** (different SSH service management).
</details>

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch
3. Make sure `shellcheck -S warning setup.sh cleanup.sh check.sh` passes
4. Open a PR using the provided template

---

## 📄 License

MIT — see [LICENSE](LICENSE)

<p align="center">
  <sub>Built with <a href="https://github.com/charmbracelet/gum">gum</a> (Charmbracelet) · Tested on Ubuntu 24.04 LTS</sub>
</p>
