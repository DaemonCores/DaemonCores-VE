# Proxmox-Atomic

**Atomic / bootc (OSTree) image for Proxmox VE, based on Debian 13 (Trixie), built on top of [debian-bootc](https://github.com/DaemonCores/debian-bootc).**

Proxmox-Atomic delivers a complete, transactional Proxmox VE deployment that inherits the bootc/OSTree infrastructure from debian-bootc and layers the Proxmox hypervisor stack on top. The entire OS is managed as an OCI container image: build, push, deploy, rollback — no manual package management on the host.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Relationship with debian-bootc](#relationship-with-debian-bootc)
- [Is this repository abandoned?](#is-this-repository-abandoned)
- [Technical stack](#technical-stack)
- [CI/CD pipeline](#cicd-pipeline)
- [APT repository](#apt-repository)
- [Secure Boot](#secure-boot)
- [Required secrets](#required-secrets)
- [Quick start](#quick-start)
- [Default root password](#default-root-password)
- [No-subscription popup removal](#no-subscription-popup-removal)
- [License](#license)

---

## Why this exists

Proxmox VE is an excellent open-source hypervisor platform, but it is traditionally installed via an ISO or apt and then managed manually on each host. There is no official atomic/OSTree deployment path, which means updates are applied in-place with no atomic rollback capability.

This project solves that by building Proxmox VE as a **bootc image**:

1. **Proxmox VE is installed on top of a bootc-compliant Debian base** — the same atomic, rollback-capable OS model that powers Fedora CoreOS and RHEL Image Mode.
2. **The entire image is built in a standard container pipeline**, pushed to GHCR, and applied atomically using ostree as the on-disk storage engine.
3. **Installer ISOs** (both online and offline) are generated automatically via the CI pipeline, providing a single-boot deployment path for bare-metal and VM hosts.
4. **First-boot user setup** handles hostname, locale, user accounts, and root password via a TUI wizard, so the image is usable out of the box without manual post-install configuration.

---

## Relationship with debian-bootc

Proxmox-Atomic is **a layer on top of debian-bootc**, not a fork. The base image (`ghcr.io/daemoncores/debian-bootc:latest`) provides the full bootc/OSTree infrastructure, and this repository adds only the Proxmox VE layer.

### What comes from debian-bootc

- **bootc** — atomic OS management via OCI container images
- **ostree** — content-addressed filesystem with atomic deployments and rollback
- **composefs** — fs-verity integrity protection for the deployed OS tree
- **bootupd** — EFI System Partition management independent of ostree
- **GRUB** — Fedora rhboot fork with BLS (Boot Loader Specification) support
- **dracut** — initramfs with `bootc`, `lvm`, and `ostree` modules
- **ifupdown2** — repacked from Proxmox sources with systemd unit ordering patches
- **systemd-timesyncd** — repacked with `After=network-online.target` drop-in
- **firstboot-user-setup** — TUI wizard for hostname, locale, user creation, root password, sudo, and SSH policy
- **Anaconda + Kickstart** — online and offline ISO installer generation with LVM on XFS
- **cosign / Sigstore** — keyless container image signing via GitHub Actions OIDC
- **Secure Boot** — MOK-enrolled GRUB with debian-bootc signing key
- **APT repository** — signed APT repo on GitHub Pages for all custom packages

### What Proxmox-Atomic adds

- **Proxmox VE 9** — the hypervisor stack (kernel, pve-manager, corosync, etc.)
- **Proxmox VE kernel** (`proxmox-default-kernel`) replaces the generic Debian kernel
- **chrony** — NTP client, replacing systemd-timesyncd (disabled in the Proxmox VE stack)
- **dnsmasq** — lightweight DNS forwarder and DHCP server
- **systemd-zram-generator** — compressed swap via zram
- **removepvepopup** — suppresses the "No valid subscription" web UI dialog
- **proxmox-firstboot.service** — detects the WAN interface and injects it into `/etc/network/interfaces`
- **pve-domain-set.service** — sets the host FQDN in `/etc/hosts` from the detected IP

---

## Is this repository abandoned?

**No.** The repository may appear inactive between Debian or Proxmox releases by design.

### Monthly automated rebuilds

The CI pipeline runs automatically on the first of every month and rebuilds the full distribution image from scratch with `--no-cache`, incorporating all upstream Debian and Proxmox security updates as they land. All custom `.deb` packages are rebuilt from source on the same schedule by the underlying debian-bootc pipeline.

### Release lifecycle

The current target is **Debian 13 Trixie** with **Proxmox VE 9**. A new release cycle will begin when Debian 14 is published. Between now and then, the only expected changes are:

- Monthly automated security rebuilds (triggered by CI schedule).
- Version bumps for upstream components (bootc, ostree, bootupd, composefs, GRUB) when new releases are available.
- Proxmox VE version bumps when Proxmox publishes new releases.

The absence of frequent commits is a sign of stability, not abandonment.

---

## Technical stack

### bootc

[bootc](https://github.com/bootc-dev/bootc) treats the entire operating system as an OCI container image. Rather than managing packages individually on a running system, the OS is built in a standard container pipeline, pushed to a registry, and applied atomically to the host using ostree as the on-disk storage engine. Updates are transactional and fully rollback-capable from the bootloader.

**Why:** Brings GitOps-style OS management — the same model that powers Fedora CoreOS and RHEL Image Mode — to Debian, with the stability and package ecosystem that Debian provides.

### ostree

[OSTree](https://ostreedev.github.io/ostree/) is the filesystem layer underneath bootc. It stores OS trees in a content-addressed object store modelled after Git, deploys them via hard links for storage efficiency, and makes every deployment atomic. It manages `/usr`, `/etc`, and `/boot` while delegating `/var` and `/home` to normal mutable storage — which is why `/home`, `/root`, `/srv`, `/mnt`, and `/opt` are symlinked into `/var` in this image.

This build inherits composefs support, dracut integration, and read-only sysroot configuration from debian-bootc.

### composefs

[composefs](https://github.com/composefs/composefs) provides integrity protection for ostree deployments using [fs-verity](https://www.kernel.org/doc/html/latest/filesystems/fsverity.html). Every file in the deployed OS tree is verified against a cryptographic hash at read time, making it impossible to tamper with the system at rest without detection.

Enabled in `prepare-root.conf` by the base image.

### bootupd

[bootupd](https://github.com/coreos/bootupd) manages the EFI System Partition independently of the ostree-managed root filesystem. In a bootc system the EFI binaries (shim, GRUB) live outside the ostree tree and cannot be updated through the normal container image update path. bootupd bridges this gap by tracking and updating EFI binaries as a separate managed component.

Inherited from debian-bootc.

### GRUB — Fedora rhboot fork

The standard Debian `grub-efi-amd64-signed` package does not include the `blscfg` and `blsuki` modules required by ostree and bootc for [BLS](https://uapi-group.org/specifications/specs/boot_loader_specification/) (Boot Loader Specification) kernel entry management. The base image compiles GRUB from the [Fedora rhboot/grub2](https://github.com/rhboot/grub2) fork at a pinned commit, producing a `grubx64.efi` with full BLS support.

### dracut

[dracut](https://github.com/dracut-ng/dracut-ng) generates the initramfs embedded in the deployed image. It is configured with the `bootc`, `lvm`, and `ostree` modules, `zstd` compression, and `hostonly=no` so the initramfs works on any hardware. The initramfs is built inside the container during the `bootc` package post-install hook (`bootc-finalize`), so the deployed image is fully self-contained.

Inherited from debian-bootc.

### ifupdown2 (Proxmox repack)

ifupdown2 is sourced from the Proxmox repository and repacked with two targeted patches by debian-bootc:

- `ifupdown2-pre.service` is ordered `After=ostree-remount.service` to ensure the ostree read-only root is mounted before networking attempts to start.
- An `ifupdown2-autoconf` helper performs DHCP autoconfiguration on first boot if the interfaces file has not yet been customised.

### Proxmox VE

[Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/) is the hypervisor layer added by this repository. It provides:

- KVM-based virtualisation with a web-based management interface
- LXC container support
- Ceph and ZFS storage integration
- High-availability clustering via corosync
- Integrated backup and restore

The image ships the `proxmox-ve` metapackage, the Proxmox kernel (`proxmox-default-kernel`), `postfix`, and `open-iscsi`. The generic Debian kernel is removed during build.

### chrony

[chrony](https://chrony-project.org/) is the NTP client. It replaces `systemd-timesyncd` because the Proxmox VE stack disables timesyncd in favour of chrony for better time synchronisation in clustered environments.

### dnsmasq

[dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) provides lightweight DNS forwarding and DHCP services. It is configured in `/etc/dnsmasq.conf` and enabled by default.

### systemd-zram-generator

[systemd-zram-generator](https://github.com/systemd/zram-generator) creates a compressed swap device using zram. On systems with limited RAM, this provides swap-like functionality without the wear and latency of disk-based swap.

### firstboot-user-setup

A TUI wizard modelled after the Raspberry Pi OS `userconfig` service. Runs on the first boot before the login prompt and guides through:

- Hostname (validated against RFC 952)
- System locale (`dpkg-reconfigure locales`)
- Keyboard layout (`dpkg-reconfigure keyboard-configuration`)
- Primary user account — username, full name, password (8 chars minimum)
- Root password
- Sudo privileges
- SSH root login policy

Runs as `ExecStartPre` on `getty@tty1.service` and writes `/var/lib/firstboot-user-setup.done` on completion to prevent re-execution.

Inherited from debian-bootc.

### Anaconda + Kickstart

The installer ISOs are built from the Fedora Server netinstall ISO with Anaconda as the installation engine. Two Kickstart templates are provided:

| ISO | Source | Use case |
|-----|--------|----------|
| `online` | Pulls `ghcr.io/<repo>:latest` from the registry at install time | Networked install, always latest image |
| `offline` | OCI archive embedded in the ISO | Air-gapped install, pinned image version |

Both templates configure LVM on XFS, delegate user setup to `firstboot-user-setup`, and set a temporary root password that is replaced on first boot.

The ISO branding (sidebar, topbar, header, product name) and Anaconda module configuration are injected into the squashfs installer environment by `scripts/inject-iso.sh`.

### cosign / Sigstore

The container image is signed with [cosign](https://github.com/sigstore/cosign) via keyless Sigstore signing using the GitHub Actions OIDC identity. The signature is stored in the same GHCR namespace as the image.

Verify a pulled image:
```bash
cosign verify ghcr.io/DaemonCores/Proxmox-Atomic:latest \
  --certificate-identity-regexp \
    "https://github.com/DaemonCores/Proxmox-Atomic/.github/workflows/bootc-build.yml@refs/heads/main" \
  --certificate-oidc-issuer \
    "https://token.actions.githubusercontent.com"
```

---

## CI/CD pipeline

```
┌─────────────────────┐     ┌──────────────┐     ┌───────────────────┐
│  bootc-debs-builder │───▶│ bootc-build  │───▶│       iso         │
│                     │     │              │     │                   │
│  Compile from src:  │     │  Build OCI   │     │  Download Fedora  │
│  - libcomposefs     │     │  image from  │     │  netinstall ISO   │
│  - libostree        │     │  Containerfile│    │  Inject branding  │
│  - bootupd          │     │              │     │  Render kickstart │
│  - grub-efi-signed  │     │  Push to     │     │  Build online ISO │
│  - bootc            │     │  GHCR        │     │  Build offline ISO│
│  - firstboot-setup  │     │              │     │                   │
│  - ifupdown2 repack │     │  Sign with   │     │                   │
│  - timesyncd repack │     │  cosign      │     │  Upload to        │
│                     │     │              │     │  GitHub Releases  │
│  Publish APT repo   │     │  Smoke test: │     │                   │
│  to GitHub Pages    │     │  bootc lint  │     │                   │
└─────────────────────┘     └──────────────┘     └───────────────────┘
```

The **Full Pipeline** workflow (`pipeline.yml`) orchestrates all three stages with optional per-stage toggles, useful for rebuilding only the component that changed without running the full 30+ minute pipeline.

The Proxmox-Atomic layer runs in the second and third stages: the OCI image build (`bootc-build.yml`) and the ISO generation (`install-iso.yml`). The first stage (`bootc-debs-builder.yml`) is inherited from debian-bootc and builds all custom packages.

### Why GitHub Actions are not pinned to commit SHAs

Pinning actions to commit SHAs provides supply-chain immutability against tag mutation, but shifts the entire maintenance burden onto the repository owner: every dependency update requires a manual SHA rotation. In practice this leads to perpetually outdated pins — which provide false security rather than real security.

This repository instead relies on **Dependabot** (`.github/dependabot.yml`) for weekly automated pull requests covering both GitHub Actions and the Docker base image. Updates are reviewed and merged explicitly, providing full auditability without manual tracking overhead. All actions used are from well-established, high-visibility namespaces (`actions/*`, `sigstore/*`, `morph027/*`) where tag mutation would be immediately detected by the community.

---

## APT repository

The custom packages (bootc, ostree, composefs, bootupd, GRUB, firstboot-user-setup, ifupdown2, timesyncd) are published to a signed APT repository on GitHub Pages by the debian-bootc pipeline. Proxmox-Atomic adds its own packages (pve-manager, proxmox kernel, etc.) from the official Proxmox repositories.

The signing key SHA-256 is hardcoded in the Containerfile and verified at build time before the key is trusted.

Add to an existing Debian Trixie system:

```bash
wget -O /usr/share/keyrings/proxmox-atomic-keyring.gpg \
  https://daemoncores.github.io/proxmox-atomic/gpg.key

# Optionally verify the key fingerprint before trusting it:
sha256sum /usr/share/keyrings/proxmox-atomic-keyring.gpg

cat > /etc/apt/sources.list.d/proxmox-atomic.sources << 'EOF'
Types: deb
URIs: https://daemoncores.github.io/proxmox-atomic/
Suites: trixie
Components: main
Enabled: yes
Signed-By: /usr/share/keyrings/proxmox-atomic-keyring.gpg
EOF

apt update
```

---

## Secure Boot

This image supports UEFI Secure Boot via the standard MOK (Machine Owner Key) mechanism provided by `shim-signed`.

### Chain of trust

UEFI firmware → shim-signed (Microsoft-signed) → grubx64.efi (debian-bootc-signed) → kernel

The `grub-efi-amd64-signed` package includes:
- A GRUB EFI binary signed with the debian-bootc Secure Boot signing key.
- The signing certificate at `/usr/share/debian-bootc/sb_signing.crt`.
- A `postinst` script that queues MOK enrollment automatically on package install.

### Enrollment

MOK enrollment is queued automatically. On the **first reboot** after installation, the firmware will launch the blue MokManager screen:

1. Select **Enroll MOK**
2. Select **Continue**
3. Select **Yes**
4. Enter the enrollment password when prompted
5. Select **Reboot**

The signing key is then enrolled permanently. All subsequent boots are fully verified end-to-end without any further action.

### Verify enrollment

```bash
mokutil --sb-state          # confirm Secure Boot is active
mokutil --list-enrolled     # confirm the debian-bootc key is present
```

---

## Required secrets

| Secret | Workflow | Purpose |
|--------|----------|---------|
| `PAT_PKG` | `bootc-build.yml` | Authenticate Podman and Docker to push to GHCR |
| `APT_GPG_KEY` | `bootc-debs-builder.yml` | Sign the APT repository published to GitHub Pages |
| `COSIGN_PRIVATE_KEY` | `bootc-build.yml` | Private key for container image cosign signing |
| `COSIGN_PASSWORD` | `bootc-build.yml` | Password for the cosign private key |
| `SB_SIGNING_KEY` | `bootc-debs-builder.yml` | Private key for GRUB EFI Secure Boot signing |
| `SB_SIGNING_CERT` | `bootc-debs-builder.yml` | Certificate for GRUB EFI Secure Boot signing |

---

## Quick start

1. Fork this repository.
2. Add `PAT_PKG`, `APT_GPG_KEY`, `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD`, `SB_SIGNING_KEY`, and `SB_SIGNING_CERT` in **Settings → Secrets → Actions**.
3. Run **Actions → Full Pipeline** with all three stages enabled.
4. Download the produced ISO from the `install-iso` release.
5. Boot the ISO on the target machine and follow the first-boot wizard.

For monthly automated rebuilds, the `pipeline.yml` schedule (`0 4 1 * *`) will trigger automatically once the repository is active.

---

## Default root password

The kickstart installer sets a temporary default root password `BootcDebug@0`. This is a **deliberate fallback**: if the first-boot user-setup wizard fails to run or is interrupted, the system remains accessible via root login so you are not locked out of your own machine. The password is replaced by the wizard on first successful boot, and the root account is forced to change password via `chage -d 0`.

This default is identical to debian-bootc. The root password is never meant to survive first boot.

---

## No-subscription popup removal

The Proxmox VE web interface displays a "You do not have a valid subscription for this server" dialog on every login when no Enterprise subscription is present. This is expected behaviour for the no-subscription repository tier.

### What the image does

The `removepvepopup` script patches `/usr/share/perl5/PVE/API2/Subscription.pm` so the subscription check reports `status => "active"` instead of `status => "notfound"`, then restarts `pveproxy.service` so the change takes effect in the web UI. This script is run during the container build (`RUN removepvepopup` in the Containerfile).

### Why it is necessary

The Proxmox-Atomic image ships without a Proxmox Enterprise subscription. Without this patch, every login to the web UI would trigger a modal dialog that the user must dismiss manually before doing anything useful.

### Maintained and proven in production

This is **not** an unsupported hack. `removepvepopup` is a script maintained by the author of Proxmox-Atomic. It has been running in production for over four years on the author's own servers and on those of friends and collaborators, without a single failure — including across every Proxmox VE update applied in that period. The modification is deliberately minimal and targeted: it flips a single boolean in the Perl code of Proxmox VE (`status => "notfound"` → `status => "active"`), nothing else. In the bootc/atomic model the patch is reapplied at image build time, so each new deployment restores it automatically.

### Note on updates

A `pve-manager` update overwrites the patched Perl file, so the popup reappears until the script runs again. Under the bootc model this is handled by the next image build; on a running system an `apt` update of `pve-manager` would temporarily restore the popup until the script is re-run. The patch has consistently re-applied cleanly across versions because it only touches a single, stable boolean field.

### Alternative

Buying a [Proxmox VE Support Subscription](https://www.proxmox.com/en/services/proxmox-ve-support) is a valid choice if you want a legitimate subscription key, access to the Enterprise repository, and vendor support — and it removes the popup without any local patch. Either path is acceptable; pick the one that fits your deployment. Revert this patch if you switch to a paid subscription.

---

## License

[LGPL-2.1](LICENSE)
