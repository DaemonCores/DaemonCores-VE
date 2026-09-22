# Architecture

## Layer model

DaemonCores-VE is a downstream operating-system image, not a fork of the Debian base.

| Layer | Source | Responsibility |
| --- | --- | --- |
| Debian | `debian:trixie` through `debian-bootc` | Userspace and Debian package ecosystem. |
| bootc base | `ghcr.io/daemoncores/debian-bootc:latest` | OSTree layout, boot stack, update mechanism, first-boot setup, and installer contract. |
| Proxmox layer | This repository | Proxmox VE, host packages, default policy, and runtime integration. |

The final image retains the base image's bootc and OSTree labels and replaces the normal Debian kernel with `proxmox-default-kernel`.

## Image assembly

The `Containerfile` performs three main phases:

1. copy temporary APT sources and service-start suppression into the build;
2. verify the DaemonCores-VE and Proxmox repository keys, install Proxmox and project packages, then remove non-Proxmox kernels;
3. copy host defaults, enable required services through image-safe symlinks, and remove build-only configuration.

The image includes `proxmox-ve`, `postfix`, `open-iscsi`, `chrony`, `ksmtuned`, `dnsmasq`, `proxmox-firewall`, and the DaemonCores packages described in the repository README.

## Package pipeline

`workflows/bootc-debs-builder/packages.yml` defines the package graph. The shared CI builds packages in dependency waves and publishes a signed APT repository.

The package set has two categories:

- targeted repacks of upstream packages where bootc or OSTree changes runtime assumptions;
- DaemonCores host tools implemented and packaged in this repository.

The image consumes those packages through `src/pvepreinstall/etc/apt/sources.list.d/daemoncores-ve.sources` after verifying the repository key digest.

## First boot and networking

The base first-boot wizard collects hostname, locale, keyboard, account, root-password, sudo, and SSH policy information on tty1.

Networking integration is now attached to `networking.service` through files shipped by the ifupdown2 repack:

- `ExecStartPre=/usr/sbin/ifupdown2-autoconf` generates the initial interface and bridge configuration when necessary;
- `ExecStartPost=/usr/sbin/domain-set` reconciles `/etc/hosts` with the active hostname and address;
- additional drop-ins define ordering and timeouts for the bootc environment.

This replaces the old standalone `proxmox-firstboot.service` and `pve-domain-set.service` design.

The image ships a bootstrap hostname and host entry so pmxcfs can initialize on the first boot before the final values are known.

## Proxmox runtime

The booted reference image is expected to provide:

- a mounted pmxcfs at `/etc/pve`;
- active `pve-cluster`, `pveproxy`, `pvedaemon`, `pvestatd`, and firewall services;
- a working HTTPS interface on port 8006;
- the Proxmox kernel and module tree as the active kernel path;
- chrony and KSM services;
- zram-only swap managed by `dc-zramctl` in the default test profile.

## Host policy packages

### VM defaults

The repacked `qemu-server` and `pve-manager` packages align backend and UI defaults. The test manifest verifies OVMF, Q35, `x86-64-v2-AES`, NIC firewall, writethrough caching, guest-agent defaults, and EFI-vars provisioning.

### Web interface compatibility

The `libtemplate-perl` repack handles files whose mtime is zero in an OSTree deployment. The `pve-manager` repack also carries the project subscription-status behaviour. Both are checked against the installed files and the running web interface.

### Memory and storage

`dc-zramctl` manages zram swap. `dc-config-zfs` is opt-in and can place the pmxcfs database on a configured ZFS dataset so host configuration is not tied to the operating-system disk.

The installer uses a Btrfs pool for system state and can preserve the `var` subvolume during a compatible reinstall. ZFS data disks are outside that installer-managed layout.

### Firewall

`dc-firewall-seed` waits for pmxcfs, then copies the packaged cluster and node firewall templates into `/etc/pve`. The templates cannot be placed directly at that path in the image because `/etc/pve` becomes a FUSE mount.

### Hardware control

`fanctl` and `powerctl` detect available control backends and read configuration from `/etc/fanctl/` and `/etc/powerctl/`. Their safe operation depends on hardware detection, valid sensor data, and reviewed configuration. Unsupported write paths must remain disabled.

### Immutable container workloads

`pvect-ostree` deploys bootc/OCI content through OSTree and composefs for use as an unprivileged Proxmox container root. `compose2bootc` converts Compose service definitions into a bootc image whose services run as Podman Quadlets.

## Validation

Before publication, the shared `image-test` action installs the image to a virtual disk, boots it under QEMU/KVM, and runs the manifest in `workflows/image-tests/tests.yml`.

The manifest checks:

- the bootc deployment and composefs/overlay root;
- pmxcfs and the core Proxmox services;
- the live web interface;
- every expected repacked-package version and patch marker;
- VM backend and GUI defaults;
- zram, firewall seed, KSM, and the custom command-line tools.

These tests validate the reference virtual machine. IPMI, fan, power, ZFS, storage-controller, and production network behaviour still require hardware qualification.

## Publication and installation

Successful images are pushed to GHCR and signed with the GitHub Actions OIDC identity. The ISO workflow builds online and offline amd64 media and uploads them to the `install-iso` release.

The installer selects one OS disk, creates the boot and Btrfs layout, and deploys the image using `bootc install to-filesystem`. It does not configure external ZFS pools or migrate existing Proxmox clusters.
