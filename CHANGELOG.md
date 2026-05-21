# Changelog

All notable changes to this project are documented here.

This project uses release tags named `release-<version>`.

## [1.0.16] - 2026-05-21

### Added
- Added a persistent `vps-hardening-sysctl.service` to re-apply critical sysctl runtime values after boot/cloud-init.
- Added `check.sh` visibility for the sysctl reapply service.

### Changed
- Writes kernel hardening values to `zz-vps-hardening.conf` so the hardening file sorts after common distro sysctl defaults.

### Fixed
- Fixed runtime drift where `net.ipv4.conf.*.log_martians` and `fs.suid_dumpable` could revert after setup/reboot even though the hardening check expected them.

## [1.0.15] - 2026-05-21

### Added
- Added effective SSH configuration checks using `sshd -T` so `check.sh` detects cloud-init or other drop-ins that override `hardening.conf`.
- Added detection of conflicting SSH authentication directives in `/etc/ssh/sshd_config.d/*.conf`.
- Added cloud-init password-auth persistence control via `ssh_pwauth: false`.

### Changed
- `setup.sh` now neutralizes conflicting SSH auth drop-ins safely, with backups, before final key-only SSH hardening.
- `setup.sh` now copies local post-install scripts during local checkout installs, preventing fresh-install tests from pulling older release scripts.
- Auto-lockdown now validates effective SSH password authentication before closing recovery access.

### Fixed
- Fixed false PASS reports where `check.sh` said password authentication was disabled while OpenSSH still allowed password login.
- Fixed rollback behavior to restore backed-up SSH drop-ins and avoid removing unrelated `ssh.socket.d` drop-ins.
- Fixed old-user cleanup detection so sudo-launched cleanup does not confuse the active user with `root`.

## [1.0.14] - 2026-05-16

### Added
- Added `allow-docker-port.sh` to persist one intentional public Docker port through UFW and Docker `DOCKER-USER`.
- Added `remove-docker-port.sh` to remove one intentional public Docker port from UFW and Docker `DOCKER-USER`.
- Added strict Docker `DOCKER-USER` rule order validation in `check.sh` to detect broad `ACCEPT` rules before the final `DROP`.
- Added explicit failures when Dokploy setup port `3000` is still allowed through `DOCKER-USER`.

### Changed
- `check.sh` now reads `/etc/vps-hardening/docker-public-ports.conf` so configured Docker public ports are not reported as unexpected firewall rules.

## [1.0.13] - 2026-05-16

### Added
- Added GitHub Actions validation to keep the Charm/Gum GPG fingerprint aligned across scripts.
- Added `--version` / `-v` support to `install-dokploy.sh`.
- Added explicit `check.sh` audit for Dokploy setup port `3000` exposure through Docker `DOCKER-USER` rules.

### Changed
- Refactored `setup.sh` into named execution phases while preserving the existing fresh VPS setup flow.
- Improved `ssh.socket` validation to confirm that a real `ListenStream` exists for the configured SSH port.
- Treats active `crowdsec` + `crowdsec-firewall-bouncer` as a valid Fail2Ban alternative.
- Updated scripts and README references to `1.0.13`.

### Fixed
- `check.sh` now fails when `AllowUsers` is configured but empty instead of reporting a false pass.

## [1.0.12] - 2026-05-15

### Changed
- Clarified Docker CLI strict mode documentation.
- Documented that manual Docker commands should use `sudo docker`.
- Clarified expected successful `check.sh` output.
- Added optional `nmap` guidance to verify public exposure.
- Clarified that Dokploy port `3000` is temporary and should be closed after HTTPS/domain setup.
- Updated scripts and README references to `1.0.12`.

## [1.0.11] - 2026-05-15

### Changed
- Enabled strict Docker CLI access by default.
- Stopped adding the admin user to the `docker` group during Docker + Dokploy installation.
- Added a `check.sh` audit for users in the `docker` group.
- Documented strict Docker CLI mode in the README.
- Updated scripts and README references to `1.0.11`.

### Security
- Reduced local privilege escalation risk by keeping Docker daemon access behind sudo authentication.

## [1.0.10] - 2026-05-15

### Fixed
- Resolved ShellCheck `SC2155` in `cleanup.sh` by splitting `backup_dir` declaration and assignment.
- Updated scripts and README references to `1.0.10`.

## [1.0.9] - 2026-05-15

### Changed
- Improved post-install hardening drift handling.

## [1.0.8] - 2026-05-15

### Changed
- Improved Dokploy installer welcome copy.

## [1.0.7] - 2026-05-15

### Changed
- Added sudo SSH and IPv6 audit checks.

[1.0.16]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.16
[1.0.15]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.15
[1.0.14]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.14
[1.0.13]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.13
[1.0.12]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.12
[1.0.11]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.11
[1.0.10]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.10
[1.0.9]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.9
[1.0.8]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.8
[1.0.7]: https://github.com/alexandreravelli/vps-ubuntu-24-04-hardening-dokploy/releases/tag/release-1.0.7
