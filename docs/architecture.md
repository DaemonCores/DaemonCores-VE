# Proxmox-Atomic Architecture

**Atomic / bootc (OSTree) image for Proxmox VE, based on Debian 13 (Trixie)**

This document describes the architecture of Proxmox-Atomic: its layered composition, the CI/CD build pipeline, the runtime first-boot flow, and key design decisions.

---

## 1. Project Overview

Proxmox-Atomic is a bootc-compliant OSTree image that delivers Proxmox VE as an atomic, rollback-capable operating system. It is built as a **layer on top of [debian-bootc](https://github.com/DaemonCores/debian-bootc)**, inheriting the full bootc/OSTree infrastructure from the base image and adding only the Proxmox hypervisor layer.

The project follows the **bootc model**: the entire OS is built in a standard container pipeline (`podman build`), pushed to a container registry (GHCR), and applied atomically to the host using ostree as the on-disk storage engine. Updates are transactional and fully rollback-capable from the bootloader.

---

## 2. Layered Architecture

Proxmox-Atomic uses a **two-layer architecture**:

| Layer | Source | Responsibility |
|---|---|---|
| **Base** | `ghcr.io/daemoncores/debian-bootc:latest` | bootc, ostree, composefs, bootupd, GRUB (Fedora rhboot fork), dracut, firstboot-user-setup, ifupdown2 (repacked), systemd-timesyncd (repacked), Secure Boot signing, APT repository |
| **Proxmox layer** | This repository | Proxmox VE 9, proxmox-default-kernel, chrony, dnsmasq, systemd-zram-generator, proxmox-firstboot, pve-domain-set, removepvepopup, fanctl, powerctl |

### What the base layer provides

- **bootc / ostree** — atomic OS management, content-addressed filesystem, rollback
- **composefs** — fs-verity integrity protection for deployed OS trees
- **bootupd** — EFI System Partition management independent of ostree
- **GRUB** — Fedora rhboot fork with BLS (`blscfg`, `blsuki`) support
- **dracut** — initramfs with `bootc`, `lvm`, and `ostree` modules
- **firstboot-user-setup** — TUI wizard for hostname, locale, user accounts, root password, sudo, SSH policy
- **ifupdown2** — repacked from Proxmox sources with systemd unit ordering patches
- **Secure Boot** — MOK-enrolled GRUB signed with the debian-bootc signing key
- **APT repository** — signed APT repo on GitHub Pages for all custom packages

### What the Proxmox layer adds

- **Proxmox VE 9** — the hypervisor stack (`proxmox-ve` metapackage)
- **proxmox-default-kernel** — the Proxmox-optimized kernel with ZFS and KVM modules, replacing the generic Debian kernel
- **chrony** — NTP client replacing `systemd-timesyncd` (disabled by Proxmox VE stack)
- **dnsmasq** — lightweight DNS forwarder and DHCP server for guest VMs
- **systemd-zram-generator** — compressed swap via zram
- **proxmox-firstboot** — detects the WAN interface and binds it to `vmbr0`
- **pve-domain-set** — pins the host FQDN to its real IP in `/etc/hosts`
- **removepvepopup** — suppresses the "No valid subscription" web UI dialog
- **fanctl** — self-calibrating IPMI (any vendor) / hwmon temperature-driven fan controller
- **powerctl** — measured CPU performance-per-watt operating point and safe peripheral power management

---

## 3. Build Pipeline

The CI/CD pipeline is orchestrated by `.github/workflows/pipeline.yml` and consists of **three sequential stages**:

```
┌─────────────────────┐     ┌──────────────┐     ┌───────────────────┐
│  bootc-debs-builder │───▶│  bootc-build │───▶│       iso         │
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

### Stage 1: `bootc-debs-builder.yml`

Runs inside a `debian:trixie` container. Its responsibilities:

1. **Install build dependencies** — compilers, Rust toolchain, Meson, etc.
2. **Build custom `.deb` packages** from source (inherited from debian-bootc):
   - `libcomposefs`, `libostree`, `bootupd`, `grub-efi-signed`, `bootc`, `firstboot-user-setup`
   - Repacked `systemd-timesyncd` with an `After=network-online.target` drop-in
3. **Build the Proxmox-Atomic packages:**
   - Repacked `ifupdown2` from Proxmox — bootc ordering fix plus a first-boot `ifupdown2-autoconf` that detects the WAN interface and **probes DHCPv6** before adding any `inet6` stanza
   - Repacked `chrony` with a `chrony.service.d/wait-network.conf` (`After=network-online.target`) drop-in
   - `fanctl` — generic IPMI (any vendor) / hwmon temperature-driven fan controller
   - `powerctl` — measured CPU performance-per-watt operating point and safe peripheral power management
4. **Publish the APT repository** to GitHub Pages using `morph027/apt-repo-action`

The resulting `.deb` artifacts are uploaded as workflow artifacts and consumed by the base image build.

### Stage 2: `bootc-build.yml`

Runs on `ubuntu-latest`. Its responsibilities:

1. **Free disk space** — remove unused toolchains to make room for the image build
2. **Log in to GHCR** — authenticate both Podman (for build/push) and Docker (for cosign signing)
3. **Build the OCI image** using `podman build` from the `Containerfile`
   - On scheduled monthly builds: `--no-cache` is passed, and a `monthly-YYYYMMDD` tag is added
4. **Check runtime dependencies** — verify `bootc` and `libostree` are present and linked
5. **Smoke test** — run `bootc container lint` inside the built image
6. **Push to GHCR** — push `:latest`, `:short-sha`, and optionally `:monthly-YYYYMMDD`
7. **Sign the image** with cosign using keyless Sigstore signing via GitHub Actions OIDC

### Stage 3: `iso.yml`

Runs inside an `almalinux:10` **privileged** container. Its responsibilities:

1. **Install ISO build tools** — `xorriso`, `squashfs-tools`, `lorax`, `mkksiso`, `ImageMagick`, `podman`, `gh-cli`, `cosign`
2. **Download Fedora Server netinstall ISO** — the Anaconda-based installer base
3. **Customize the ISO** — run `scripts/inject-iso.sh` to inject branding (sidebar, topbar, header, product name) and Anaconda module configuration into the squashfs
4. **Verify the container image signature** using `cosign verify` before embedding
5. **Pull and save the OCI image** — for the offline ISO, the image is saved as an OCI archive and embedded in the ISO
6. **Render Kickstart templates** — two templates (`iso-online-config.ks.tpl` and `iso-offline-config.ks.tpl`) are rendered to `/tmp/`
7. **Build online and offline ISOs** using `mkksiso`:
   - **Online ISO** — pulls the image from GHCR at install time
   - **Offline ISO** — embeds the OCI archive; no network required
8. **Patch GRUB configs** — replace Fedora branding with project branding in both EFI and BIOS GRUB configs
9. **Re-implant ISO MD5 checksum** — so media verification still works
10. **Upload ISOs to GitHub Releases** — attached to the `install-iso` release

### Pipeline orchestration

The `pipeline.yml` workflow ties the three stages together with `workflow_call`. Each stage can be toggled independently via `workflow_dispatch` inputs, allowing partial rebuilds (e.g., rebuild only the ISO without recompiling all `.deb` packages).

The pipeline runs automatically on the first of every month (`cron: '0 4 1 * *'`), rebuilding everything from scratch with `--no-cache` to incorporate upstream security updates.

---

## 4. Image Composition (Containerfile)

The `Containerfile` defines the Proxmox layer. It is built `FROM ghcr.io/daemoncores/debian-bootc:latest`.

### Build phases

1. **Environment setup**
   - `STOPSIGNAL SIGRTMIN+3` — required for systemd-in-container compatibility
   - `DEBIAN_FRONTEND=noninteractive` — suppress interactive debconf prompts
   - `SHELL ["/bin/bash", "-euo", "pipefail", "-c"]` — fail fast on any error

2. **GPG key verification**
   - Download and SHA-256 verify both the Proxmox-Atomic APT signing key and the official Proxmox enterprise key before trusting them

3. **Proxmox installation**
   - Install `proxmox-default-kernel`, `proxmox-ve`, `postfix`, `open-iscsi`, `chrony`, `systemd-zram-generator`, `dnsmasq`
   - Remove all generic Debian kernels (`linux-image-amd64`, `os-prober`, and any `linux-image-*` package that is not `proxmox-default-kernel`)
   - Prune stale `/usr/lib/modules` trees so only the active Proxmox kernel's modules remain

4. **Post-install configuration**
   - Copy `src/pvepostinstall/` into the image (`/etc/network/interfaces`, systemd services, scripts)
   - Enable `pve-domain-set.service` and `proxmox-firstboot.service` via symlinks into `multi-user.target.wants`
   - Run `removepvepopup` to patch the subscription check
   - Clean up temporary files and the `policy-rc.d` inhibitor

5. **Health check**
   - `HEALTHCHECK NONE` — bootc images are updated in-place via ostree; no runtime healthcheck applies

---

## 5. First-Boot Flow

When the image boots for the first time (whether from ISO installation or a direct `bootc switch`), the following sequence runs:

```
┌─────────────────────────────┐
│  System boots (GRUB + BLS)  │
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  dracut initramfs           │
│  (bootc, lvm, ostree modules)│
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  ostree deploys rootfs      │
│  (composefs + fs-verity)    │
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  systemd multi-user.target    │
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  firstboot-user-setup       │
│  (TUI wizard on tty1)        │
│  - Hostname                 │
│  - Locale / keyboard          │
│  - Primary user account       │
│  - Root password              │
│  - Sudo privileges            │
│  - SSH root login policy      │
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  proxmox-firstboot.service  │
│  (Condition: no done flag)    │
│  - Detect WAN interface     │
│  - Resolve {{ WAN_DEVICE }}   │
│  - Write /etc/network/interfaces
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  pve-domain-set.service     │
│  - Detect real IPv4           │
│  - Pin FQDN → IP in /etc/hosts│
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  networking + pveproxy      │
│  (Proxmox VE fully online)   │
└─────────────────────────────┘
```

### firstboot-user-setup

Inherited from debian-bootc. Runs as `ExecStartPre` on `getty@tty1.service` before the login prompt appears. Writes `/var/lib/firstboot-user-setup.done` on completion to prevent re-execution. The temporary root password (`BootcDebug@0`) is replaced by the user-supplied password, and `chage -d 0` forces a change on next login.

### proxmox-firstboot

A one-shot systemd service (`proxmox-firstboot.service`) that runs once per machine. It:

1. Runs `ip route get 8.8.8.8` to identify the default-route interface
2. Resolves the `{{ WAN_DEVICE }}` placeholder in `/etc/network/interfaces` to the real interface name
3. Writes `/var/lib/proxmox-firstboot-done` to prevent re-execution

If `8.8.8.8` is unreachable (offline lab), the script exits silently via `|| exit 0` so first boot is not aborted.

### pve-domain-set

A one-shot systemd service (`pve-domain-set.service`) that runs on every boot. It:

1. Detects the first global IPv4 address
2. Removes stale `127.0.1.1` entries for the hostname from `/etc/hosts`
3. Appends a line mapping the real IP to the FQDN and short hostname

This prevents Proxmox VE from binding `pveproxy` and clustering to the loopback address, which would cause certificate mismatches and unreachable Web UI.

---

## 6. Networking

### Bridge layout

The image ships with four pre-configured bridges in `/etc/network/interfaces`:

| Bridge | Purpose | Address | NAT |
|---|---|---|---|
| **vmbr0** | Default LAN / Prod Internet | `10.10.10.10/24` | Yes (MASQUERADE to WAN) |
| **vmbr1** | Default LAN / Prod Offline | `10.11.11.10/24` | No |
| **vmbr10** | Default LAN / Test Internet | `10.100.100.10/24` | Yes (MASQUERADE to WAN) |
| **vmbr11** | Default LAN / Test Offline | `10.101.101.10/24` | No |

### WAN interface

The WAN interface is detected at first boot by `ifupdown2-autoconf` and bound to the `vmbr0` bridge via the `bridge_ports` directive. It is configured for IPv4 DHCP with public DNS resolvers (`194.242.2.2`, `1.1.1.1`). For IPv6, `ifupdown2-autoconf` probes for a DHCPv6 server and only adds an `inet6 auto` stanza (with `2a07:e340::2`, `2606:4700:4700::1111`) when one answers; otherwise it relies on kernel SLAAC. This prevents a `dhclient -6` from hanging for 30s and failing `networking.service` on networks whose Router Advertisement requests DHCPv6 with no server present.

### dnsmasq

`dnsmasq` is configured in `/etc/dnsmasq.conf` to provide DNS forwarding and DHCP services on all four bridges:

- **vmbr0** — `wanprod.local`, range `10.10.10.100–199/24`
- **vmbr1** — `lanprod.local`, range `10.11.11.100–199/24`
- **vmbr10** — `wantest.local`, range `10.100.100.100–199/24`
- **vmbr11** — `lantest.local`, range `10.101.101.100–199/24`

Lease time is 24 hours (`dhcp-range=...,24h`).

### IP forwarding and NAT

`ip_forward` is enabled via `post-up` hooks on `vmbr0` and `vmbr10`. `iptables` NAT rules (`MASQUERADE`) are applied so VMs on these bridges can reach the Internet through the WAN interface.

---

## 7. Storage

### ZFS

The image uses `proxmox-default-kernel` instead of the generic Debian kernel. The Proxmox kernel ships with ZFS modules built-in, so ZFS storage pools can be created and managed directly from the Proxmox Web UI without additional DKMS compilation.

### Kernel module pruning

During the Containerfile build, all generic Debian kernel packages are removed, and `/usr/lib/modules` is pruned so only the active Proxmox kernel's module tree remains. This reduces image size and eliminates module-version mismatches.

### zram swap

`systemd-zram-generator` creates a compressed swap device using zram. On systems with limited RAM, this provides swap-like functionality without the wear and latency of disk-based swap. Configuration is typically placed in `/etc/systemd/zram-generator.conf`.

---

## 8. Secure Boot

### Chain of trust

```
UEFI firmware → shim-signed (Microsoft-signed) → grubx64.efi (debian-bootc-signed) → kernel
```

### Signing key

The `grub-efi-amd64-signed` package (built by debian-bootc) includes:

- A GRUB EFI binary signed with the debian-bootc Secure Boot signing key
- The signing certificate at `/usr/share/debian-bootc/sb_signing.crt`
- A `postinst` script that queues MOK enrollment automatically on package install

### MOK enrollment flow

1. **First boot after installation** — the firmware launches the blue MokManager screen
2. Select **Enroll MOK**
3. Select **Continue**
4. Select **Yes**
5. Enter the enrollment password when prompted
6. Select **Reboot**

The signing key is then enrolled permanently. All subsequent boots are fully verified end-to-end without any further action.

### Verification

```bash
mokutil --sb-state          # confirm Secure Boot is active
mokutil --list-enrolled     # confirm the debian-bootc key is present
```

---

## 9. Documentation Toolchain

| Component | Tool | Output |
|---|---|---|
| Inline docs | POSIX shell header blocks | Source code |
| Static docs | Markdown in `docs/` | GitHub web UI, wiki |
| Wiki sync | CI workflow (`docs-wiki-sync.yml`) | GitHub wiki |
| Reference extraction | `shdoc` (for shell scripts) | Markdown |

The `docs/reference/` directory is auto-generated by CI from inline header blocks and is **not committed** to the repository.

---

## 10. Related Documents

- [`README.md`](../README.md) — Project overview, quick start, technical stack
- [`docs/justifications.md`](justifications.md) — Honest justifications for controversial design choices
- [`Containerfile`](../Containerfile) — Image composition definition
- [debian-bootc](https://github.com/DaemonCores/debian-bootc) — Base image and inherited infrastructure
