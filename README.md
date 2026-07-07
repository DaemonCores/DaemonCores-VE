# DaemonCores-VE

**Atomic / bootc (OSTree) image for Proxmox VE, based on Debian 13 (Trixie), built on top of [debian-bootc](https://github.com/DaemonCores/debian-bootc).**

DaemonCores-VE delivers a complete, transactional Proxmox VE deployment that inherits the bootc/OSTree infrastructure from debian-bootc and layers the Proxmox hypervisor stack on top. The entire OS is managed as an OCI container image: build, push, deploy, rollback — no manual package management on the host.

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

DaemonCores-VE is **a layer on top of debian-bootc**, not a fork. The base image (`ghcr.io/daemoncores/debian-bootc:latest`) provides the full bootc/OSTree infrastructure, and this repository adds only the Proxmox VE layer.

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

### What DaemonCores-VE adds

- **Proxmox VE 9** — the hypervisor stack (kernel, pve-manager, corosync, etc.)
- **Proxmox VE kernel** (`proxmox-default-kernel`) replaces the generic Debian kernel
- **chrony** — NTP client, replacing systemd-timesyncd (disabled in the Proxmox VE stack)
- **dnsmasq** — lightweight DNS forwarder and DHCP server
- **systemd-zram-generator** — compressed swap via zram
- **pve-manager (repacked)** — Proxmox VE management stack, patched to suppress the "No valid subscription" web UI dialog
- **libtemplate-perl (repacked)** — Template Toolkit, patched to fix the ostree `mtime=0` bug that otherwise makes the web UI return HTTP 500
- **proxmox-firstboot.service** — detects the WAN interface and injects it into `/etc/network/interfaces`
- **pve-domain-set.service** — sets the host FQDN in `/etc/hosts` from the detected IP
- **fanctl** — generic, self-calibrating temperature-driven fan controller (IPMI for any vendor, plus an hwmon backend for standard PCs)
- **powerctl** — measured CPU performance-per-watt operating point plus safe peripheral power management (SATA ALPM, PCI runtime PM, GPU cap, ZFS-aware disk spin-down, load-driven swappiness)

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

ifupdown2 is sourced from the Proxmox repository and repacked with targeted patches:

- `ifupdown2-pre.service` is ordered `After=ostree-remount.service` to ensure the ostree read-only root is mounted before networking attempts to start.
- An `ifupdown2-autoconf` helper writes `/etc/network/interfaces` on first boot (if not yet customised): it detects the WAN interface, configures IPv4 DHCP, and **probes for a DHCPv6 server** — the `inet6 auto` stanza is only added when one actually answers. This avoids a `dhclient -6` that would otherwise hang 30s and fail `networking.service` on networks whose Router Advertisement requests DHCPv6 with no server; kernel SLAAC still provides IPv6 addressing regardless.

### Proxmox VE

[Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/) is the hypervisor layer added by this repository. It provides:

- KVM-based virtualisation with a web-based management interface
- LXC container support
- Ceph and ZFS storage integration
- High-availability clustering via corosync
- Integrated backup and restore

The image ships the `proxmox-ve` metapackage, the Proxmox kernel (`proxmox-default-kernel`), `postfix`, and `open-iscsi`. The generic Debian kernel is removed during build.

### chrony

[chrony](https://chrony-project.org/) is the NTP client. It replaces `systemd-timesyncd` because the Proxmox VE stack disables timesyncd in favour of chrony for better time synchronisation in clustered environments. It is repacked with a `chrony.service.d/wait-network.conf` drop-in (`After=`/`Wants=network-online.target`) so chronyd does not start before the network is up and fail its initial time sync on a fast boot.

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

### fanctl

A lightweight bash daemon that regulates server fan speed from temperature over the local IPMI interface (`/dev/ipmi0`). It self-calibrates: it discovers the temperature sensors and their own Upper-Critical thresholds, measures the real fan/temperature response, and holds the hottest controlling sensor near a target, recalibrating on sustained drift. Fan writing uses an auto-detected vendor profile (Dell iDRAC, Supermicro, …); an hwmon backend (`/sys/class/hwmon/*/pwm*`) covers standard PCs without IPMI, and any unsupported platform falls back to read-only monitoring. Safety is temperature-based: a single failed fan is tolerated, and only a near-critical temperature forces maximum cooling. Configured in `/etc/fanctl/fanctl.conf`; calibration persists in `/var/lib/fanctl/`.

### powerctl

A bash daemon that keeps the CPU at its **measured** performance-per-watt efficiency knee. It sweeps the factory frequency steps under load, reads real package power from RAPL, picks the knee, and floats `scaling_max_freq` between the knee and the factory maximum in real time — driven by workload compute-boundedness (perf IPC) so frequency is only spent when it buys work. Everything stays inside the factory range (no undervolt, no overclock). It also applies safe peripheral power management, each knob auto-disabling when unsupported: governor/EPP, SATA link power (ALPM), PCI runtime PM, PCIe ASPM, GPU power cap (NVIDIA + AMD), C-state re-enabling, ZFS-aware idle-disk spin-down, and load-driven `vm.swappiness`. Configured in `/etc/powerctl/powerctl.conf`; calibration persists in `/var/lib/powerctl/`.

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
cosign verify ghcr.io/DaemonCores/DaemonCores-VE:latest \
  --certificate-identity-regexp \
    "https://github.com/DaemonCores/DaemonCores-CI/.github/workflows/bootc-build.yml@refs/heads/main" \
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

The DaemonCores-VE layer runs in the second and third stages: the OCI image build (`bootc-build.yml`) and the ISO generation (`install-iso.yml`). The first stage (`bootc-debs-builder.yml`) is inherited from debian-bootc and builds all custom packages.

### Why GitHub Actions are not pinned to commit SHAs

Pinning actions to commit SHAs provides supply-chain immutability against tag mutation, but shifts the entire maintenance burden onto the repository owner: every dependency update requires a manual SHA rotation. In practice this leads to perpetually outdated pins — which provide false security rather than real security.

This repository instead relies on **Dependabot** (`.github/dependabot.yml`) for weekly automated pull requests covering both GitHub Actions and the Docker base image. Updates are reviewed and merged explicitly, providing full auditability without manual tracking overhead. All actions used are from well-established, high-visibility namespaces (`actions/*`, `sigstore/*`, `morph027/*`) where tag mutation would be immediately detected by the community.

---

## APT repository

The custom packages (bootc, ostree, composefs, bootupd, GRUB, firstboot-user-setup, ifupdown2, timesyncd) are published to a signed APT repository on GitHub Pages by the debian-bootc pipeline. DaemonCores-VE adds its own packages (pve-manager, proxmox kernel, etc.) from the official Proxmox repositories.

The signing key SHA-256 is hardcoded in the Containerfile and verified at build time before the key is trusted.

Add to an existing Debian Trixie system:

```bash
wget -O /usr/share/keyrings/daemoncores-ve-keyring.gpg \
  https://daemoncores.github.io/daemoncores-ve/gpg.key

# Optionally verify the key fingerprint before trusting it:
sha256sum /usr/share/keyrings/daemoncores-ve-keyring.gpg

cat > /etc/apt/sources.list.d/daemoncores-ve.sources << 'EOF'
Types: deb
URIs: https://daemoncores.github.io/daemoncores-ve/
Suites: trixie
Components: main
Enabled: yes
Signed-By: /usr/share/keyrings/daemoncores-ve-keyring.gpg
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

The subscription check is patched inside a **repacked `pve-manager` package**: the `pve-manager` shipped by Proxmox is downloaded, `/usr/share/perl5/PVE/API2/Subscription.pm` is edited so the check reports `status => "active"` instead of `status => "notfound"`, and the result is republished (`+bootc1`) to the DaemonCores-VE APT repository. apt then installs the patched package at image-build time — the same mechanism used for the other repacked packages (`ifupdown2`, `chrony`, `openipmi`). This replaces the former standalone `removepvepopup` script and its apt hook, which are no longer shipped.

### Why it is necessary

The DaemonCores-VE image ships without a Proxmox Enterprise subscription. Without this patch, every login to the web UI would trigger a modal dialog that the user must dismiss manually before doing anything useful.

### Maintained and proven in production

This is **not** an unsupported hack. The change is maintained by the author of DaemonCores-VE and has been running in production for over four years on the author's own servers and on those of friends and collaborators, without a single failure — including across every Proxmox VE update applied in that period. The modification is deliberately minimal and targeted: it flips a single boolean in the Perl code of Proxmox VE (`status => "notfound"` → `status => "active"`), nothing else. Because it is folded into the repacked package, each new image build reapplies it automatically.

### Note on updates

Because the patch lives in the repacked `pve-manager` published to the DaemonCores-VE APT repository, apt prefers the `+bootc1` version over the stock Proxmox package and reapplies it automatically on every image build. The change only touches a single, stable boolean field, so it has re-applied cleanly across versions.

### Alternative

Buying a [Proxmox VE Support Subscription](https://www.proxmox.com/en/services/proxmox-ve-support) is a valid choice if you want a legitimate subscription key, access to the Enterprise repository, and vendor support — and it removes the popup without any local patch. Either path is acceptable; pick the one that fits your deployment. Revert this patch if you switch to a paid subscription.

---

## Web UI HTTP 500 on ostree (Template Toolkit mtime fix)

On a freshly deployed atomic image, the Proxmox VE web UI could return HTTP 500 with `index.html.tpl: not found`, even though the template is present on disk.

### Root cause

ostree canonicalizes every `/usr` file mtime to `0` (epoch) when it deploys the image. Template Toolkit (`libtemplate-perl`) uses a template's mtime as its "does this template exist?" truth value; a zero mtime is falsy, so every template shipped under `/usr` is treated as missing. This is intrinsic to the ostree deployment layer — it appears only after deployment, not in the OCI image (which still carries real mtimes), so it is **not** a Containerfile misconfiguration.

### What the image does

`libtemplate-perl` is repacked (`+bootc1`) with a small patch to `_template_modified` (`Template/Provider.pm`): a real-but-zero mtime is mapped to `1`, while genuinely missing files still return `undef`. This restores correct template existence detection on ostree without disturbing the freshness cache, and fixes the web UI globally — the correction applies to every Template Toolkit template, not just the Proxmox UI.

---

## License

[LGPL-2.1](LICENSE)
