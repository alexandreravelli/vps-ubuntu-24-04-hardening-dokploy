# Contributing

Thanks for helping improve this project.

This repository contains root-level hardening scripts for fresh Ubuntu 24.04 VPS servers, so changes should be conservative, easy to review, and explicit about their operational impact.

## Development Rules

Before opening a pull request:

1. Keep changes focused and small.
2. Explain any SSH, firewall, sudo, Docker, or kernel hardening impact clearly.
3. Avoid unrelated refactors in security-sensitive changes.
4. Update the README when user-facing behavior changes.
5. Update release notes or CHANGELOG entries for meaningful changes.
6. Do not commit secrets, private keys, server IPs, tokens, or personal VPS logs.

## Required Checks

Run these locally before submitting:

```bash
bash -n setup.sh cleanup.sh check.sh install-dokploy.sh purge.sh allow-docker-port.sh remove-docker-port.sh
shellcheck -x -s bash -S warning setup.sh cleanup.sh check.sh install-dokploy.sh purge.sh allow-docker-port.sh remove-docker-port.sh
git diff --check
```

If your change touches Gum installation, verify that the Charm GPG fingerprint remains identical across:

- `setup.sh`
- `cleanup.sh`
- `check.sh`
- `purge.sh`

## Testing Guidance

For behavior changes, prefer validation on a fresh Ubuntu 24.04 LTS VPS.

At minimum, document:

- VPS provider
- Ubuntu version
- Release tag or commit tested
- Commands executed
- Result of `sudo ./check.sh`

For Docker or Dokploy changes, also verify:

```bash
sudo docker ps
sudo ufw status verbose
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER
```

## Pull Request Checklist

A good pull request includes:

- Clear description of the problem and solution
- Risk assessment for SSH/firewall/root-level behavior
- Test commands and results
- README updates when needed
- No generated noise or unrelated formatting churn

## Release Process

Releases use immutable tags named like:

```text
release-1.0.13
```

When preparing a release:

1. Update script `VERSION` values.
2. Update README release links.
3. Update `CHANGELOG.md`.
4. Run all required checks.
5. Commit to `main` through a pull request.
6. Create and push the release tag.
7. Publish GitHub release notes using the project standard sections:
   - Overview
   - Changes
   - Safety Impact
   - Compatibility
   - Validation
   - Upgrade Notes
