# Security Policy

## Supported Versions

This project targets fresh Ubuntu 24.04 LTS VPS servers.

| Version | Supported |
|---------|-----------|
| `release-1.0.13` and newer | Yes |
| Older releases | Best effort only |

Fresh installations should always use the latest tagged release instead of `main`.

## Reporting a Vulnerability

Please do not open a public GitHub issue for security vulnerabilities.

If you believe you found a vulnerability, report it privately using GitHub Security Advisories when available, or contact the maintainer directly:

- GitHub: `@alexandreravelli`
Include as much detail as possible:

- Affected script and release tag
- Ubuntu version and VPS provider
- Exact command or configuration involved
- Expected behavior vs actual behavior
- Potential impact
- Safe reproduction steps, if available

## Scope

Security-sensitive areas include:

- SSH access and lockout prevention
- UFW and Docker `DOCKER-USER` firewall rules
- Docker and Dokploy installation behavior
- sudoers and user cleanup logic
- GPG fingerprint verification
- Audit logging and hardening checks
- Any command executed as root

## Disclosure Process

The maintainer will try to acknowledge reports within 72 hours.

For confirmed vulnerabilities, the preferred process is:

1. Validate impact and affected releases.
2. Prepare a fix privately.
3. Publish a patched release tag.
4. Document the issue and mitigation in the release notes.

## Hardening Disclaimer

This project provides a pragmatic baseline. It does not guarantee complete security for every VPS, provider, workload, or threat model. Always review the scripts before running them on production infrastructure.
