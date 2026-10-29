# KERNEL + NVIDIA PVE-host migration plan (xanmod multi-arch CI + host driver)

Status: PLAN awaiting GO (Gabriel 30/10: the plan, including the kernel
strategy complement, must be validated before ANY further kernel/nvidia
implementation). Non-risky drafting (docs + patch manifest + lib +
workflow skeletons) is committed; the build has never been run and the
host/GPU/VM paths are PENDING, GO-gated.

## 0. Verification — is the kernel the CI/debian-bootc blocker?

Answer: **NO, verified from source.**

- `debian-bootc` carries its own kernel pipeline independent of the images:
  kernel.org tarball + CachyOS BORE patch (`kernel/patches.yml`, stage
  `common`), rolling `track:` that only moves a version forward when every
  patch source provides its file, patch_guard on the pristine tree, and the
  last-good published deb is kept on any failure
  (`docs/kernel-patches.md`, `docs/gotchas/kernel-series-without-bore-patch.md`).
- One real gotcha exists (CachyOS 7.3 series has only `bore-cachy`, so the
  tracker stays on 7.2.x), but it is a deliberate *pin by the tracker*, not a
  CI blockage.
- `DaemonCores-VE` images install `proxmox-default-kernel` (stock Debian
  package) and prune `/usr/lib/modules` — the VE pipeline never builds a
  kernel (`docs/ci-catchup-plan.md` Écart 5 is about the Containerfile arm64
  matrix, not the kernel).

Consequence (branch chosen per directive): the kernel is NOT the blocker, so
the host-side kernel work goes **proxmox kernel source + XanMod patches**, at
the granularity of a dedicated CI job — not a merger with the debian-bootc
kernel lane (XanMod is monolithic there and collides with BORE; the two
pipelines stay separate).

## 1. Facts harvested (read-only, 2026-10-30)

| Fact | Value | Source |
|------|-------|--------|
| docker.iartistique kernel | `7.3.0-x64v3-xanmod1` (Debian 13, `/boot` carries only this kernel) | `uname -r`, `ls /boot` |
| GPU in docker.iartistique | RTX 2080 Ti Rev. A (TU102, all 4 PCI functions) in passthrough | `lspci` on the VM |
| NVIDIA driver in the VM | **none at the OS level**: no nvidia packages in dpkg, no `/proc/driver/nvidia`, no `/dev/nvidia*` | dpkg/lspci probes |
| PVE host iartistique | Debian 13 base, `proxmox-kernel-7.0.14-14-pve-signed` + `proxmox-kernel-7.0.2-6` installed, `proxmox-kernel-helper 1:9.2.0+bootc1`, PVE 9.2 suite; **running kernel = `6.12.107+deb13-amd64` (Debian's)**, `pveproxy`/`pve-cluster` INACTIVE, `/etc/pve` absent, `qm`/`pct` not in `/usr/sbin` | dpkg + probes |
| XanMod 7.3 upstream | `gitlab.com/xanmod/linux-patches`, directory `linux-7.3.y-xanmod` with per-topic subdirs (`xanmod` 18 numbered patches, `clearlinux`, `mm`, `net`, `binder`, `userns`, `zen`, `kconfig`, `pci_acso`, `valve`) | GitLab tree API, checked live |

**Anomalies to flag to Gabriel (outside this lane's scope but load-bearing):**
1. The PVE host currently boots Debian's own 6.12 kernel, not the installed
   `proxmox-kernel-7.0.14-14-pve`; `pveproxy` and `pve-cluster` are inactive
   and `/etc/pve` (pmxcfs) is not mounted. Either the host is mid-rewrap to the
   bootc image (a `+bootc1` helper suffix exists) or the PVE daemons were
   decommissioned during a migration step that is not recorded in the state
   master. Every qemu/passthrough manipulation below assumes this is resolved
   and visible again (`/etc/pve`, `qm list`, `qm config 100`).
2. **No NVIDIA driver is installed in the docker VM** despite the passthrough.
   The "driver nvidia" to expatriate may therefore live in a container image
   or another VM, not in the VM OS. Confirm with Gabriel which artefact
   actually serves the GPU before any host-side packaging.
3. The docker VM's xanmod kernel has no dpkg provenance for `/boot` files
   (dpkg -S returns nothing readable) — likely installed outside dpkg or the
   kernel .deb name differs; do not rely on reconstructing it from the VM.

## 2. Design — kernel PVE + XanMod, multi-arch CI job (build only, no host impact)

Layout (follows the debian-bootc kernel conventions, ported, not reinvented):

```
DaemonCores-VE/workflows/bootc-debs-builder/kernel-pve/
  patches.yml          — manifest: xanmod topic subdirs per {series}, build-time fetch
  lib/kernel-pve-patches.sh — guard + dry-run + apply (ports lib/kernel-patches.sh)
  lib/kernel-pve-build.sh   — in-container build script
DaemonCores-CI/.github/workflows/kernel-pve.yml — reusable build (dispatch/wkly)
DaemonCores-VE/.github/workflows/kernel-pve.yml — thin caller
```

**Strategy (Gabriel, 30/10 — supersedes any finer-grained variant matrix):**
NO rebuild per fine architecture. debian-bootc stays without
rebuild-per-arch (transverse modules). On the PVE side the kernel variants
are TRANSVERSE: 2-3 packages built from the SAME source and config —
- `x64v1` (default), `x64v3` (Gabriel's machine), and optionally `x64v2`;
- the variant is chosen AT FIRST BOOT by x86-64-v3 detection, not at
  package install time;
- ARM = ONE cross-compiled build in the same job, no microarch matrix;
- backport to debian-bootc afterwards (same helper/patches, transverse
  variant packages; low porting cost).

Build recipe per variant (self-contained, outside of the deb pipeline —
touching `packages.yml` is deliberately avoided until the host lane is
validated):

1. Base: `debian:trixie` + Proxmox no-subscription repo → `apt-get source`
   the installed `proxmox-kernel-7.0` packaging (no invented upstream URL, the
   version tracks whatever the host runs).
2. Extract the packaging's kernel tree, merge the host `.config` seed
   (captured from the host during the non-risky window) + XanMod kconfig
   fragment (`linux-7.3.y-xanmod/kconfig`).
3. Apply XanMod patch set in topic order (xanmod, then clearlinux), guard +
   dry-run first, drift = hard fail. ONE tree prepared; every x86 variant is
   then a config-fragment + repackage pass over the SAME tree (no N full
   kernel builds).
4. `make bindeb-pkg` → deb published as workflow artifact per flavour;
   debs are NEVER auto-installed on the host. All debs install side by side
   (distinct pack names `linux-pve-xanmod-{flavour}`); GRUB picks per boot.
5. Flavours built (from one tree/job, in order):

| Flavour | arch | Microarch flags | Notes |
|---------|------|-----------------|-------|
| x64v1 | amd64 | baseline | default |
| x64v3 | amd64 | x86-64-v3 | flavour of the current VM kernel, Gabriel's machine |
| x64v2 | amd64 | x86-64-v2 | OPTIONAL — built only on request |
| arm64 | arm64 | defconfig | single build, cross-compiled in the same job |

6. First-boot variant choice: a bootc/karg or an initramfs probe checking
   `grep x86-64-v3 /proc/cpuinfo` (or CPUID leaf) that selects the
   `linux-pve-xanmod-x64v3` entry over the `x64v1` default; the default stays
   x64v1 when detection is inconclusive. The exact mechanism (grub default
   entry vs. bootc kernel args vs. a system generator) is decided at GO with
   the image lane.

Non-goals for this lane: LTS/rebase tracking automation (the PVE kernel
version is the anchor), secure-boot signing (unsigned debs, host boots a
manual kernel), and integration into the deb pipeline cache/waves.

## 3. Design — NVIDIA driver, host side (passthrough → host-driver, GO-gated)

The intent: after the passthrough is cut, the PVE host (bootc) owns the GPU
and serves LXC guests (portail-runner-gpu 122) via host driver + device
files + library bind mounts, following the standard Proxmox NVIDIA LXC
pattern.

Steps, each with its own gate:

1. **N-PENDING (coordination)**: cut the passthrough of the docker VM. Only
   possible when no CI/gpu-lane is running and with Gabriel's GO. Capture the
   VM's GPU config (`qm config <vmid> | grep hostpci`) BEFORE — blocked by
   anomaly 1 above (host PVE stack not visible).
2. **N-PENDING**: on the host, ensure the PVE host image boots a kernel that
   NVIDIA can build against (the PVE+xanmod deb from §2, flavour x64v3 to
   match the VM's proven setup, or the stock `proxmox-kernel` — pick at GO).
3. **N-PENDING**: install the NVIDIA driver in the host image: `dkms` build of
   the NVIDIA module against `/lib/modules/<pve kernel>/build`, or the
   `nvidia-driver` Debian package with `dkms` (Debian packaging is
   trixie-compatible). On the bootc host this lands in the image build, not a
   host-local apt run — a new deb overlay package (mirror rule of the house)
   or an extra `dnf/bootc` layer, decided at GO with the image lane.
4. **N-PENDING**: LXC sharing config for CT 122 (`/dev/nvidia*` device
   passthrough + `libnvidia-container`-style lib bind mounts), P-08 in the
   state master.
5. Validation: `nvidia-smi` on the host AND inside CT 122 with a CUDA job;
   VM docker.iartistique must stay untouched (read-only invariant) — the
   passthrough removal is the ONLY write that touches the GPU chain.

## 4. File of operations (ordered)

- [x] K-01 blocker verification (§0) — done, source-based.
- [x] K-02 facts harvest (§1) — read-only probes done.
- [x] K-03 non-risky drafting (this commit): patches.yml manifest, lib
      scripts, reusable CI workflow + thin caller, plan doc — NOT RUN; the
      kernel build itself waits for the GO on this plan.
- [ ] K-04 PENDING Gabriel: GO on this plan (incl. the transverse-variant
      strategy §2), then resolve host anomaly 1 (PVE stack visibility),
      then first CI run of the kernel-pve workflow (build only, artifact).
- [ ] K-06 PENDING GO: host bootc kexec/reboot on the new kernel (§3 step 2)
      — irreversible reboot, coordinate with the proxy-cutover window
      (watchdog P-09 in force).
- [ ] K-07 PENDING GO (with GPU-idle window): cut passthrough (§3 step 1),
      then driver install and CT-122 sharing.
- [ ] K-08 backport to debian-bootc: same helper/patch lib, transverse
      variant packages (low porting cost) — after the PVE lane validates.
- [ ] K-09 state master updated.