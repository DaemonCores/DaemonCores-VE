# Proxmox-Atomic

**Atomic / bootc (OSTree) image for Proxmox VE, built on Debian 13 (Trixie) and layered on top of [debian-bootc](https://github.com/DaemonCores/debian-bootc).**

Proxmox-Atomic delivers a complete, transactional Proxmox VE deployment as an OCI container image. Build, push, deploy, rollback — no manual package management on the host. The entire OS is atomic and rollback-capable from the bootloader.

This wiki is kept in sync with the repository via CI. For the full project documentation, see the [README](https://github.com/DaemonCores/Proxmox-Atomic/blob/main/README.md).

## Wiki Pages

- [Architecture](architecture.md) — Layered composition, CI/CD build pipeline, runtime first-boot flow, and key design decisions.
- [Justifications](justifications.md) — Honest explanations for controversial or non-obvious design choices (default root password, no-subscription popup removal, privileged container, and more).
