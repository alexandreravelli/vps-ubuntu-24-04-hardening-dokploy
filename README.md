<p align="center">
  <img src="https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <img src="https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/Docker-Ready-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

<h1 align="center">VPS Hardening Script</h1>

<p align="center">
  <strong>Secure your Ubuntu 24.04 VPS and deploy Dokploy -- a self-hostable Platform as a Service (PaaS) -- in minutes.</strong><br>
  Interactive setup with beautiful CLI powered by <a href="https://github.com/charmbracelet/gum">gum</a>.
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> --
  <a href="#what-it-does">What It Does</a> --
  <a href="#security-features">Security</a> --
  <a href="#after-installation">Post-Install</a> --
  <a href="#faq">FAQ</a>
</p>

---

## Quick Start

**Option 1 -- Switch to root first (recommended)**

```bash
sudo -i
```

Then run:

```bash
curl -sSL https://raw.githubusercontent.com/alexandreravelli/vps-hardening-script-ubuntu-24.04-LTS/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

**Option 2 -- One-liner (auto-escalates to root)**

```bash
curl -sSL https://raw.githubusercontent.com/alexandreravelli/vps-hardening-script-ubuntu-24.04-LTS/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

> The script detects if it's not running as root and automatically re-runs itself with `sudo`. It also auto-installs [gum](https://github.com/charmbracelet/gum) for a polished terminal experience -- spinners, styled inputs, progress bars, boxed output.

---

## What It Does

The script walks you through **9 interactive steps** with a visual progress bar:

```
[########------------] Step 4/9 -- Kernel hardening
```

| Step | Action | Time |
|------|--------|------|
| 1 | **Create admin user** -- new sudo user with strong password | ~30s |
| 2 | **Configure SSH key** -- paste existing OR generate new ed25519 pair | ~10s |
| 3 | **Update system** -- apt upgrade, 2GB swap, Quad9 DNS-over-TLS | ~2-3min |
| 4 | **Kernel hardening** -- sysctl (anti-spoofing, SYN flood, ASLR...) | ~5s |
| 5 | **Security tools** -- UFW, Fail2Ban, auditd, AppArmor, auto-updates | ~1-2min |
| 6 | **Firewall** -- deny-by-default, open only needed ports | ~5s |
| 7 | **Harden SSH** -- random port, disable root, key-only auth | ~5s |
| 8 | **Install Docker** -- official APT repo with GPG verification | ~2-3min |
| 9 | **Install Dokploy** -- self-hosted deployment platform | ~1-2min |

**Total: ~8-12 minutes** depending on your VPS.

---

## SSH Key Options

At step 2, you choose:

| Option | What happens |
|--------|-------------|
| **Paste existing key** | You paste your `ssh-ed25519` or `ssh-rsa` public key |
| **Generate new pair** | Script creates an ed25519 pair, shows you the private key to save, installs the public key, then **securely deletes** the private key from the server with `shred` |

> When generating a new key pair, the script asks if you want to **protect it with a passphrase**. This adds an extra layer of security -- even if someone gets your private key file, they can't use it without the passphrase.

---

## Security Features

<details>
<summary><strong>Full security feature list (click to expand)</strong></summary>

| Layer | Feature | Details |
|-------|---------|---------|
| **SSH** | Custom port | Random port 50000-60000 |
| | Root login disabled | `PermitRootLogin no` |
| | Key-only auth | Password auth disabled after confirmation |
| | Brute-force protection | MaxAuthTries 3, LoginGraceTime 30s |
| | Session control | ClientAliveInterval 300s, CountMax 2 |
| | User whitelist | `AllowUsers` restricts to admin only |
| | Forwarding disabled | X11 + TCP forwarding off |
| **Network** | UFW firewall | deny-by-default, only SSH/80/443/3000 |
| | Rate limiting | 6 connections/30s per IP on SSH |
| | Fail2Ban | 3 attempts = 1h ban |
| | DNS-over-TLS | Quad9 (9.9.9.9) + DNSSEC |
| **Kernel** | Anti-spoofing | `rp_filter`, martian logging |
| | SYN flood protection | `tcp_syncookies`, tuned backlog |
| | ICMP hardening | Redirects + broadcasts blocked |
| | ASLR | Full randomization (level 2) |
| | Restricted info | dmesg + kernel pointers restricted |
| **Auth** | Password policy | 12+ chars, mixed case, numbers, symbols |
| | Audit logging | sudo, auth, SSH, user/group changes |
| | AppArmor | Mandatory access control |
| | Auto-updates | Daily security patches |
| **Docker** | Official install | APT repo with GPG, not `curl \| sh` |
| | Log rotation | 10MB max, 3 files |
| **Recovery** | Error trap | Restores SSH access if setup fails |
| | Config backup | `sshd_config.bak` saved before changes |
| | Summary file | `~/.vps_setup_summary` with all details |

</details>

---

## Safety Measures

The script is designed to **never lock you out**:

- Password auth stays enabled until you confirm SSH key works
- Port 22 stays open until you confirm custom port works
- **Double confirmation** (`CONFIRM`) required before closing port 22
- Won't auto-delete user if you're currently logged in as them
- Error trap automatically restores SSH on port 22 if setup crashes
- Full log saved to `/var/log/vps_setup.log`

---

## After Installation

### Connect to your server

```bash
ssh your-user@your-ip -p YOUR_PORT
```

### Remove default user

```bash
# Interactive (asks which user)
./cleanup.sh

# Direct
./cleanup.sh ubuntu
```

### Run security audit

```bash
./check.sh
```

Outputs a full report:

```
  SSH Configuration
  ------------------
  [PASS] Root login disabled
  [PASS] Password authentication disabled
  [PASS] Custom SSH port: 54821
  ...

  RESULTS
  PASS: 28  FAIL: 0  WARN: 1  TOTAL: 29

  Your server is mostly hardened. Review warnings above.
```

### Lock down Dokploy (after SSL)

```bash
sudo iptables -I DOCKER-USER -p tcp --dport 3000 -j DROP
sudo iptables -I DOCKER-USER -i lo -p tcp --dport 3000 -j ACCEPT
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

---

## Project Structure

```
.
├── setup.sh        # Main hardening script (interactive, gum UI)
├── cleanup.sh      # Remove old default user
├── check.sh        # Post-install security audit
├── LICENSE          # MIT
└── .github/
    ├── workflows/
    │   └── shellcheck.yml   # CI: lint all scripts
    ├── ISSUE_TEMPLATE/
    │   ├── bug_report.md
    │   └── feature_request.md
    └── PULL_REQUEST_TEMPLATE.md
```

---

## Requirements

- Fresh **Ubuntu 24.04 LTS** VPS
- User with **sudo** privileges
- SSH public key ready (or let the script generate one)

---

## FAQ

<details>
<summary><strong>What if I lose my SSH key?</strong></summary>

Use your VPS provider's console/VNC access to login, then reconfigure SSH:

```bash
sudo nano /etc/ssh/sshd_config.d/hardening.conf
# Change PasswordAuthentication to yes
sudo systemctl restart ssh
```
</details>

<details>
<summary><strong>What if I forget my SSH port?</strong></summary>

The port is saved in two places:
- `/root/.vps_hardening_config`
- `~/.vps_setup_summary`

Access via your provider's console to check.
</details>

<details>
<summary><strong>Can I run the script again?</strong></summary>

The script is not idempotent -- it's designed for fresh installs. Use `check.sh` to verify your server's state instead.
</details>

<details>
<summary><strong>Can I skip Dokploy?</strong></summary>

Not currently. If you want a version without Dokploy, comment out step 9 in `setup.sh` and remove port 3000 from the firewall rules.
</details>

<details>
<summary><strong>Does it work on other Ubuntu versions?</strong></summary>

Designed and tested for Ubuntu 24.04 LTS. It may work on 22.04 but is not guaranteed.
</details>

---

## Contributing

1. Fork the repo
2. Create a feature branch
3. Make sure `shellcheck -S warning your_script.sh` passes
4. Open a PR using the provided template

---

## License

MIT -- see [LICENSE](LICENSE)

---

<p align="center">
  <sub>Built with <a href="https://github.com/charmbracelet/gum">gum</a> by Charmbracelet</sub>
</p>
