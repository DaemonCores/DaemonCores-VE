# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Proxmox-Atomic, please report it privately.

- **Email**: `guillou.gabriel@gmail.com` (PGP key available on request)
- **GitHub Private Vulnerability Reporting**: Use [GitHub Security Advisories](https://github.com/DaemonCores/Proxmox-Atomic/security/advisories/new)

Please do **not** open public issues for security vulnerabilities.

## Supported Versions

| Version | Supported          |
|---------| ------------------ |
| latest  | :white_check_mark: |
| < latest| :x:                |

Only the latest published image is actively maintained with security updates. Users are expected to pull the latest image or rebuild from the latest source.

## Response Timeline

- **Acknowledgement**: Within 48 hours of receiving a report.
- **Initial Assessment**: Within 5 business days.
- **Patch and Disclosure**: Coordinated with the reporter. We aim to release a fix within 30 days of acceptance, or sooner for critical issues.

## Disclosure Process

1. Reporter submits vulnerability privately.
2. Maintainers confirm receipt and begin assessment.
3. If accepted, a fix is developed in a private branch.
4. A GitHub Security Advisory is drafted.
5. The fix is merged, a new image is built, and the advisory is published simultaneously.

## Known Risks

### Default Root Password

The kickstart installer sets a temporary default root password `BootcDebug@0` as a deliberate fallback. This password is intended to be replaced by the `firstboot-user-setup` wizard on the first successful boot. Leaving this password unchanged beyond first boot is a known security risk. See the [README](README.md#default-root-password) for details.

### `removepvepopup` Modification

The `removepvepopup` script patches a Proxmox VE Perl source file (`/usr/share/perl5/PVE/API2/Subscription.pm`) to suppress the no-subscription dialog. This modification:

- Is **not supported** by Proxmox Server Solutions GmbH.
- Can be overwritten by `pve-manager` package updates.
- Relies on internal API paths that may change without notice.

See the [README](README.md#no-subscription-popup-removal) for risks and the official subscription alternative.
