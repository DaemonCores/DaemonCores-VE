# Justifications

**Honest explanations for controversial or non-obvious design choices in Proxmox-Atomic.**

This document follows the same transparency principle as debian-bootc: every decision that could be questioned is documented here with its rationale, its risks, and the alternatives.

---

## 1. Default Root Password (`BootcDebug@0`)

### What we do

The Kickstart installer sets a temporary default root password: `BootcDebug@0`.

### Why it exists

This is a **deliberate fallback**, not an oversight. The `firstboot-user-setup` wizard (inherited from debian-bootc) runs on first boot before the login prompt and asks the user to set a root password. If that wizard fails to run — because the TTY is unavailable, the service crashes, or the boot is interrupted — the system would be completely inaccessible without a known fallback credential.

The password serves the same role as the default passwords on Raspberry Pi OS, cloud images, and virtually every other pre-installed Linux image: it guarantees you are not locked out of your own machine before you've had a chance to configure it.

### What happens on first boot

1. The `firstboot-user-setup` wizard prompts for a root password
2. The user-supplied password replaces `BootcDebug@0`
3. `chage -d 0` is applied, forcing the root account to change its password on the next login
4. The temporary password never survives first boot

### Risks

- If the wizard is bypassed and the user does not log in as root, the temporary password remains active until someone does. This is why the wizard is wired into `getty@tty1.service` as `ExecStartPre` — it is nearly impossible to reach a login prompt without passing through it.
- The password is documented in the README and in this file. This is intentional: security through obscurity would be worse. The password is meant to be temporary and replaced, not secret.

### Alternative

Remove the fallback entirely and trust that `firstboot-user-setup` will never fail. We rejected this because a single failure mode (e.g., serial console without `tty1`) would render the installed system unrecoverable without physical access to the boot media.

This default is **identical to debian-bootc**. The root password is never meant to survive first boot.

---

## 2. No-Subscription Popup Removal (`removepvepopup`)

### What we do

The `removepvepopup` script patches `/usr/share/perl5/PVE/API2/Subscription.pm` so the subscription check reports `status => "active"` instead of `status => "notfound"`, then restarts `pveproxy.service`.

### Why it is necessary

The Proxmox-Atomic image ships **without a Proxmox Enterprise subscription**. Without this patch, every login to the Proxmox VE web UI triggers a "You do not have a valid subscription for this server" modal dialog that the user must dismiss manually before doing anything useful. In an atomic/bootc deployment model where the OS is rebuilt from a container image, requiring manual dismissal of a popup on every login is not acceptable.

### Proven track record

This is **not** an experimental or unsupported hack. `removepvepopup` is maintained by the author of Proxmox-Atomic and has been running in production for over four years on the author's own servers and on those of friends and collaborators, without a single failure — including across every Proxmox VE update applied in that period. The modification is deliberately minimal and targeted: it flips a single boolean in the Perl code of Proxmox VE (`status => "notfound"` → `status => "active"`), nothing else. That simplicity is the reason the patch has remained stable and easy to maintain across versions. In the bootc/atomic model the patch is reapplied at image build time, so each new deployment restores it automatically.

### Note on updates

A `pve-manager` update overwrites the patched Perl file, so the popup reappears until the script runs again. Under the bootc model this is handled by the next image build; on a running system a `pve-manager` update via `apt` would temporarily restore the popup until the script is re-run. Because the patch only touches a single, stable boolean field, it has consistently re-applied cleanly across versions. Running this on a production server that already holds a paid subscription would mask legitimate subscription warnings — in that case prefer the subscription path instead.

### Alternative

Buying a [Proxmox VE Support Subscription](https://www.proxmox.com/en/services/proxmox-ve-support) is a valid choice if you want a legitimate subscription key, access to the Enterprise repository, and vendor support — and it removes the popup without any local patch. Either path is acceptable; pick the one that fits your deployment. Revert this patch if you switch to a paid subscription.

---

## 3. Privileged Container in ISO Workflow

### What we do

The ISO generation job (`.github/workflows/iso.yml`) runs inside an `almalinux:10` container with `options: --privileged`.

### Why it is necessary

The ISO build process requires `mount -o loop` to extract and repack the Fedora netinstall ISO's squashfs and EFI partitions. In a standard unprivileged container, loop device access is blocked by the kernel's mount namespace restrictions. `--privileged` grants the necessary capabilities (`CAP_SYS_ADMIN`) and device access to perform loop mounts.

### What we do to mitigate the risk

- The privileged container is **isolated to a single dedicated job** (`build-iso`). No other jobs in the pipeline run privileged.
- The job does not process untrusted input. The only external data fetched is:
  - The Fedora netinstall ISO from `archives.fedoraproject.org`
  - The OCI image from GHCR (verified with `cosign verify` before embedding)
  - The `cosign` RPM from GitHub Releases (SHA-256 verified)
- The container image is pinned to `almalinux:10`, not `latest`.
- The job runs on GitHub-hosted `ubuntu-latest` runners, which are ephemeral and destroyed after the job completes.

### Alternative

Run the ISO build on a self-hosted runner with `/dev/loop*` pre-configured and pass `--device /dev/loop0` instead of `--privileged`. This would require maintaining a self-hosted runner infrastructure, which we consider higher overhead than accepting the isolated privileged container for this single job.

---

## 4. Debian Trixie (Testing) as Base

### What we do

Proxmox-Atomic is built on Debian 13 (Trixie), which is currently the **testing** distribution, not stable.

### Why testing instead of stable

1. **Kernel recency** — Proxmox VE requires a relatively recent kernel for ZFS and KVM features. Debian Stable (Bookworm, 12) ships a kernel that is too old for Proxmox VE 9's requirements. Trixie provides a kernel new enough to satisfy the dependency chain.
2. **bootc/ostree evolution** — The bootc and ostree ecosystems are evolving rapidly. bootc 1.x, composefs integration, and dracut module changes are all landing in Debian testing before they reach stable. Building on stable would mean backporting a significant fraction of the base infrastructure, defeating the purpose of using a standard Debian base.
3. **Proxmox VE 9 targets Trixie** — The upstream Proxmox repositories already publish packages for Trixie. Building on stable would require mixing repositories or waiting for the next stable release.

### Risks

- Testing packages can change without notice. The monthly automated rebuilds (`cron: '0 4 1 * *'`) mitigate this by rebuilding from scratch with the latest testing snapshot.
- Security updates in testing are not as strictly coordinated as in stable. The trade-off is accepted for the features gained.

### Alternative

Wait for Debian 14 (the next stable release) and freeze on it. This would delay the project by 1–2 years. The current approach is to track Trixie and migrate to the next stable release when it is published.

---

## 5. Kernel Replacement (Removing Debian Standard Kernels)

### What we do

The Containerfile removes all generic Debian kernels (`linux-image-amd64`, `os-prober`, and any `linux-image-*` package that is not `proxmox-default-kernel`) and prunes `/usr/lib/modules` so only the Proxmox kernel remains.

### Why we replace the kernel

1. **ZFS integration** — The Proxmox kernel (`proxmox-default-kernel`) ships with ZFS modules built-in. The generic Debian kernel requires ZFS to be compiled via DKMS, which is incompatible with the bootc model: DKMS modules must be rebuilt on every kernel update, and bootc images are meant to be immutable and self-contained.
2. **KVM optimizations** — The Proxmox kernel includes scheduler and I/O optimizations specifically tuned for virtualization workloads.
3. **Single kernel image** — bootc systems are designed to have exactly one kernel per deployment. Having multiple kernel packages complicates the bootloader configuration and increases image size.

### Risks

- If Proxmox discontinues `proxmox-default-kernel` or changes its packaging, the build breaks. The monthly rebuilds catch such breakage early.
- The Proxmox kernel may lag behind the Debian kernel in non-virtualization features (e.g., new hardware support). For a hypervisor host, this is usually acceptable.

### Alternative

Keep the generic Debian kernel and compile ZFS via DKMS at boot. Rejected because it violates the bootc immutability principle and would require runtime compilation, which is fragile and slow.

---

## 6. No SHA Pinning for GitHub Actions

### What we do

GitHub Actions in this repository use version tags (e.g., `actions/checkout@v7`, `sigstore/cosign-installer@v3`) instead of pinning to specific commit SHAs.

### Why we use tags instead of SHAs

Pinning actions to commit SHAs provides supply-chain immutability against tag mutation, but shifts the **entire maintenance burden onto the repository owner**: every dependency update requires a manual SHA rotation. In practice this leads to perpetually outdated pins — which provide false security rather than real security.

This repository instead relies on **Dependabot** (`.github/dependabot.yml`) for weekly automated pull requests covering both GitHub Actions and the Docker base image. Updates are reviewed and merged explicitly, providing full auditability without manual tracking overhead. All actions used are from well-established, high-visibility namespaces (`actions/*`, `sigstore/*`, `morph027/*`) where tag mutation would be immediately detected by the community.

### Risks

- A compromised action in a trusted namespace could inject malicious code. Dependabot would surface the update, but a human must review it before merge.
- Tag mutation by a malicious insider at GitHub or a third-party action maintainer is theoretically possible. The namespaces chosen have high community scrutiny.

### Alternative

Pin every action to a SHA and maintain a manual rotation schedule. Rejected because the maintenance overhead is not justified for a project with a single maintainer and monthly rebuild cadence. The Dependabot + review model provides a better trade-off.

---

## 7. `COSIGN_EXPERIMENTAL: 1`

### What we do

The ISO workflow sets the environment variable `COSIGN_EXPERIMENTAL=1` before running `cosign verify`.

### Why it is enabled

`COSIGN_EXPERIMENTAL=1` enables experimental features in the cosign CLI. Historically, this flag was required for keyless Sigstore verification workflows (OIDC-based certificate identity verification) before they were promoted to stable in later cosign versions. The project started using cosign when keyless signing was still experimental, and the flag was retained for compatibility with the specific cosign version pinned in the ISO workflow.

The flag may become unnecessary as cosign matures, but its presence is harmless: it simply opts in to features that are stable in newer releases and experimental in older ones.

### Risks

- Experimental features may change behaviour across cosign versions. The cosign version is pinned via the SHA-256 verified RPM download in the ISO workflow, so the behaviour is deterministic within a given build.
- The flag could mask deprecation warnings. Monthly rebuilds surface any CLI changes.

### Alternative

Remove the flag and rely on the stable cosign verification path. This would require verifying that the pinned cosign version supports keyless verification without the flag. Given that the flag is harmless and the version is pinned, we have not prioritized removing it.

---

## Summary Table

| Decision | Justification | Risk Level | Alternative |
|---|---|---|---|
| Default root password | Fallback if firstboot wizard fails | Low (temporary, replaced immediately) | Remove fallback; risk lockout |
| `removepvepopup` | Maintained by author, 4+ years production, single-boolean patch | Low (single stable field, re-applied at build time) | Buy Proxmox subscription |
| Privileged ISO container | Required for `mount -o loop` | Low (isolated to single job, ephemeral runner) | Self-hosted runner with loop devices |
| Debian Trixie (testing) | Kernel recency, bootc evolution, Proxmox VE 9 target | Medium (testing instability) | Wait for Debian 14 stable |
| Kernel replacement | ZFS built-in, KVM optimizations, bootc immutability | Low (Proxmox kernel is stable) | Keep Debian kernel + DKMS ZFS |
| No SHA pinning for Actions | Dependabot + review > manual SHA rotation | Low (trusted namespaces) | Pin all SHAs manually |
| `COSIGN_EXPERIMENTAL: 1` | Historical requirement for keyless verification | Very low (pinned cosign version) | Verify stable path and remove |

---

## Related Documents

- [`README.md`](../README.md) — Full project documentation
- [`docs/architecture.md`](architecture.md) — Architecture overview, build pipeline, first-boot flow
- [`Containerfile`](../Containerfile) — Image composition definition
