# DaemonCores-VE

<p align="center">
  <img src="https://raw.githubusercontent.com/DaemonCores/.github/refs/heads/main/assets/banner.svg" alt="AstralEmu Banner" width="100%"/>
</p>

<p>
  <strong align="left">Simplify and Innovate for Everyone.</strong>
  <a href="https://github.com/DaemonCores/debian-bootc/wiki"><img align="right" src="https://img.shields.io/badge/Wiki-FFFFFF?style=for-the-badge&logoColor=white" alt="Documentation"/></a>
  <a href="https://github.com/orgs/DaemonCores/discussions"><img align="right" src="https://img.shields.io/badge/Community-000000?style=for-the-badge&logoColor=white" alt="Community"/></a>
  <a href="https://github.com/DaemonCores/debian-bootc"><img align="right" src="https://img.shields.io/badge/Base_debian_for_all_project-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian Bootc"/></a>
  
  <em>Identify gaps and fill them, make improvements where possible, but above all, empower developers to offer more to users.</em>
</p>

---

DaemonCores-VE builds Proxmox VE as a transactional bootc/OSTree operating-system image on top of [`debian-bootc`](https://github.com/DaemonCores/debian-bootc).

The project replaces an in-place host build with a versioned OCI image: packages and host policy are assembled in CI, the result is installed and boot-tested under QEMU, and successful images are published for atomic deployment and rollback.

DaemonCores-VE is under active development. The current deployment target is amd64 hardware. Review the release workflow and test results before installing it on a host that carries important workloads.

## What this repository adds

The base image supplies Debian 13, bootc, OSTree, composefs, bootupd, the bootloader path, first-boot setup, and the generic installer infrastructure. This repository adds:

- Proxmox VE and the Proxmox kernel;
- a bootc-aware ifupdown2 configuration and first-boot bridge generation;
- repacked Proxmox and Debian packages required by the OSTree runtime;
- default VM policy for OVMF, Q35, guest agent, NIC firewall, and disk caching;
- host services for ZFS configuration persistence, firewall seeding, zram swap, power control, and fan control;
- tools for deploying bootc images as immutable Proxmox containers;
- conversion of Compose applications into bootc/Quadlet container images.

## Project packages

| Package | Responsibility |
| --- | --- |
| `pve-manager` | Applies the project web-interface defaults and subscription-status patch. |
| `qemu-server` | Applies backend VM defaults and EFI provisioning behaviour. |
| `libtemplate-perl` | Handles OSTree's zero file mtimes correctly so Proxmox templates remain discoverable. |
| `ifupdown2` | Adds boot ordering, interface autoconfiguration, and hostname/IP reconciliation. |
| `chrony` and `openipmi` | Add service guards and network ordering suitable for the image. |
| `proxmox-kernel-helper` | Removes boot operations that conflict with the bootc-managed boot path. |
| `dc-zramctl` | Manages calibrated, pressure-aware zram swap. |
| `dc-firewall-seed` | Copies initial firewall policy into pmxcfs after it is mounted. |
| `dc-config-zfs` | Optionally relocates the pmxcfs database to a configured ZFS dataset. |
| `fanctl` | Controls supported IPMI, embedded-controller, or hwmon fan backends. |
| `powerctl` | Calibrates and applies host power-management policy within hardware limits. |
| `pvect-ostree` | Deploys bootc/OCI images as unprivileged, immutable Proxmox containers. |
| `compose2bootc` | Converts a Compose stack into a bootc image using Podman and Quadlet. |

Exact defaults and operational constraints live with each package under `workflows/bootc-debs-builder/`.

## Build and validation

The repository calls the shared [`DaemonCores-CI`](https://github.com/DaemonCores/DaemonCores-CI) pipeline. A complete run:

1. optionally rebuilds the `debian-bootc` base;
2. builds and publishes the project Debian packages;
3. assembles the Proxmox image from `Containerfile`;
4. installs the image to a virtual disk and boots it with QEMU/KVM;
5. verifies the Proxmox cluster filesystem, services, web UI, package patches, zram, firewall seed, and shipped tools;
6. publishes and signs the image after those tests pass;
7. produces online and offline installer ISOs.

The monthly schedule performs a complete rebuild. Push builds use change detection, while manual runs can select individual stages and optionally trigger the upstream base pipeline first.

## Installation

Installer artifacts are published in the [`install-iso`](https://github.com/DaemonCores/DaemonCores-VE/releases/tag/install-iso) release when the ISO stage succeeds.

- The online ISO pulls `ghcr.io/daemoncores/daemoncores-ve:latest` during installation.
- The offline ISO embeds an OCI archive.
- The installer asks for the target disk and preserves an existing compatible `var` Btrfs subvolume during reinstall.
- First boot runs the inherited console setup flow before normal host operation.

The selected installation disk is repartitioned. Test the image and installation path in a virtual machine before using physical hardware.

## Host configuration

The default network configuration is generated by the ifupdown2 package's `networking.service` drop-ins. `ifupdown2-autoconf` selects the WAN interface and writes the bridge configuration; `domain-set` reconciles the host entry after networking starts. The former standalone `proxmox-firstboot.service` and `pve-domain-set.service` are no longer part of the codebase.

Optional host services expose configuration under `/etc/<package>/`. Read the package defaults before enabling hardware control or relocating Proxmox configuration.

## Required repository configuration

| Secret | Purpose |
| --- | --- |
| `PAT_PKG` | Pull and publish GHCR images. |
| `APT_GPG_KEY` | Sign the DaemonCores-VE APT repository. |
| `SB_SIGNING_KEY` | Used by the inherited boot stack when the Secure Boot package is rebuilt. |
| `SB_SIGNING_CERT` | Certificate paired with the Secure Boot key. |

Container images are signed keylessly with cosign through GitHub Actions OIDC. No `COSIGN_PRIVATE_KEY` or `COSIGN_PASSWORD` secret is used by the current image workflow.

## Documentation

- [Architecture](docs/architecture.md)
- [Design decisions and trade-offs](docs/justifications.md)
- [Support](SUPPORT.md)
- [Security policy](SECURITY.md)

---

<p>
  <strong align="left">Made with ⭐ by the DaemonCores community</strong>
  <a href="https://github.com/DaemonCores/debian-bootc/wiki"><img align="right" src="https://img.shields.io/badge/Wiki-FFFFFF?style=for-the-badge&logoColor=white" alt="Documentation"/></a>
  <a href="https://github.com/orgs/DaemonCores/discussions"><img align="right" src="https://img.shields.io/badge/Community-000000?style=for-the-badge&logoColor=white" alt="Community"/></a>
  <a href="https://github.com/DaemonCores/debian-bootc"><img align="right" src="https://img.shields.io/badge/Base_debian_for_all_project-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian Bootc"/></a>
</p>
