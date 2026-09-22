# Design decisions and trade-offs

## Proxmox as a bootc image

DaemonCores-VE assembles the host in CI and deploys it as a versioned image. This makes the operating-system tree transactional and rollback-oriented, but it also means conventional host-side `apt` customization is not the source of truth. Persistent changes belong in a Containerfile, package, or documented mutable configuration path.

The approach is most valuable when hosts are expected to converge on a reviewed image. It is less suitable when every host is intentionally modified by hand.

## Replacing the Debian kernel

The image installs `proxmox-default-kernel` and removes Debian's standard kernel packages and stale module trees. Proxmox features such as ZFS and the supported virtualization stack are expected to track that kernel.

Kernel replacement increases integration risk around boot finalization and module availability. The build aborts when core Proxmox packages are missing, and the runtime test boots the resulting image rather than accepting an image-only build.

## Targeted package repacks

Several upstream packages are repacked because their default behaviour assumes a mutable Debian installation rather than an OSTree deployment.

Each repack should remain narrow, carry a `+bootc` version suffix, and have a runtime or file-level test. Broad source forks would make update review and patch-drift detection harder.

## Template Toolkit zero-mtime handling

OSTree deployments can expose `/usr` files with an epoch mtime. Template Toolkit treats a falsey mtime as if a template is absent, which can make the Proxmox web interface fail even though the file exists.

The `libtemplate-perl` repack maps an existing zero mtime to a non-zero sentinel while preserving the missing-file case. The CI verifies the installed patch and requests the live web page, covering both implementation and outcome.

## Subscription-status patch

The repacked `pve-manager` changes the no-subscription response used by the web interface. This is a local product choice, not an Enterprise subscription and not a substitute for vendor support or repository access.

The change should stay isolated and easy to revert. Users with a Proxmox subscription should evaluate removing the patch and enabling the appropriate vendor repository.

## Network configuration through service drop-ins

First-boot network generation and hostname reconciliation run as `networking.service` pre- and post-start hooks. Keeping them in the ifupdown2 integration ensures they run at the point where their inputs and outputs matter.

This replaces two standalone services that could drift from the actual network lifecycle. The trade-off is tighter coupling to ifupdown2 and the unit's ordering contract.

## Persisting pmxcfs on ZFS

`dc-config-zfs` can place the pmxcfs database on a configured ZFS dataset. The feature is opt-in because an incorrect dataset or import order could prevent the Proxmox configuration filesystem from starting.

The service must complete before `pve-cluster`. Operators should verify backups and recovery independently; relocating the database is not itself a backup strategy.

## Seeding firewall state after pmxcfs

Files cannot be baked directly into `/etc/pve` because pmxcfs mounts there at runtime. `dc-firewall-seed` stores templates under `/usr/share` and copies them only after pmxcfs is available.

The seed is intended for initial policy. Ongoing cluster policy remains Proxmox-managed state and should not be overwritten blindly on every boot.

## Adaptive zram, fan, and power services

The hardware-control packages calibrate against the running machine rather than shipping one universal threshold. This can adapt better across dissimilar hosts, but it creates a responsibility to reject implausible sensors, unsupported write interfaces, and unsafe configuration.

Virtual-machine tests can validate packaging and service startup. They cannot validate real IPMI commands, embedded controllers, PWM paths, RAPL behaviour, disk policy, or thermal response. Physical qualification is required before enabling write control on a new platform.

## Immutable Proxmox containers

`pvect-ostree` keeps the image root immutable while attaching writable `/etc` and `/var` state for an unprivileged container. `compose2bootc` builds service images around Podman and Quadlet instead of exposing a Docker daemon socket.

This preserves the versioned-image model inside workloads. It also introduces custom storage and lifecycle code that must be tested during Proxmox and OSTree upgrades.

## Keyless image signing

The image workflow uses cosign with GitHub Actions OIDC. The current pipeline does not require a long-lived cosign private key or password.

Verification policy must match the expected repository and reusable-workflow identity. Signature presence alone is not a complete trust policy.

## Privileged installer jobs

Installer generation and image installation require mounts, loop devices, partitioning, and access to block-device tooling. Those jobs run with elevated privileges.

Do not execute untrusted pull-request code in the same permission context, and do not expose release or package credentials to such runs.

## Shared workflows at `@main`

The product currently consumes DaemonCores-CI from its main branch. This keeps active development synchronized, but an incompatible CI change can affect product builds without a product-repository commit.

Versioned workflow tags or commit pins are the appropriate next step when the shared interface is declared stable.
