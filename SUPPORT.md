# Support

## Where to Get Help

### Documentation

The [Proxmox-Atomic Wiki](https://github.com/DaemonCores/Proxmox-Atomic/wiki) contains the latest documentation, build instructions, and troubleshooting guides.

### GitHub Issues

If you encounter a bug or want to request a feature, please use the GitHub issue forms:

- [Bug Report](https://github.com/DaemonCores/Proxmox-Atomic/issues/new?template=bug_report.yml)
- [Feature Request](https://github.com/DaemonCores/Proxmox-Atomic/issues/new?template=feature_request.yml)

Before opening an issue, please search existing issues to avoid duplicates.

## What Is Supported

We provide community support for:

- Building and deploying the Proxmox-Atomic image.
- ISO installer generation (online and offline).
- First-boot configuration and the `firstboot-user-setup` wizard.
- General bootc/ostree lifecycle operations (`bootc update`, `bootc rollback`, etc.).
- The APT repository and package updates.

## What Is NOT Supported

The following are explicitly out of scope for community support:

- **Upstream Proxmox VE bugs**: Issues that are reproducible on a standard Proxmox VE installation (without bootc/ostree) should be reported to [Proxmox](https://bugzilla.proxmox.com/) directly.
- **Hardware-specific issues unrelated to the image**: Driver or firmware problems that are not specific to the atomic deployment model.
- **The `removepvepopup` hack**: This is a convenience patch to suppress the no-subscription dialog. It is not endorsed by Proxmox Server Solutions GmbH and is not supported by this project beyond its current implementation. If it breaks after a `pve-manager` update, you may need to re-apply the patch yourself or consider purchasing an official [Proxmox VE Support Subscription](https://www.proxmox.com/en/services/proxmox-ve-support).
- **Paid Enterprise subscription issues**: This project targets the no-subscription repository tier.

## Response Expectations

This is a community-maintained project. Responses to issues and discussions are best-effort and may take several days depending on maintainer availability.

For urgent or security-sensitive matters, please refer to [SECURITY.md](SECURITY.md).
