# pve-cluster S1-S3 — C source lane (pmxcfs)

This lane holds the pmxcfs C patches (plan `docs/compose-variant-a-plan.md`
surfaces S1-S3). It is deliberately OUTSIDE the `pve-cluster/` overlay dir:
the C sources are not in the deb tree, and `apply_overlays.sh` would see
these patches as drift when repacking the deb. Only the deb-tree overlays
(`pve-cluster/`, `libpve-cluster-api-perl/`) feed the repack builds.

The patches are anchored on the **upstream source tree**
(git://git.proxmox.com/git/pve-cluster.git, commit `66c87e0` = version
9.1.7, the exact version `apt-get download` resolves from
download.proxmox.com pve-no-subscription trixie). Paths mirror the source
tree root (`src/pmxcfs/...`).

Wired (2026-10-30): the lane rides the `source-build` class of
`packages.yml` (variant `pve-cluster`, name `source-build-pve-cluster`)
through the shared `deb_source_build` helper (DaemonCores-CI `dee562b`,
`HELPERS_VER: 3`), which clones the upstream tree, pins the manifest
commit, runs `patch_guard.py` against this `patches.lock.json`,
dry-runs then applies the patches, re-targets the deb-tree Perl
overlays onto `src/PVE/...` (`usr/share/perl5/` → `src/`, `-p3`),
stamps `9.1.7.1+dcve1` in the changelog, installs the build deps from
`debian/control` and drives the upstream staged `make deb`. The build
needs the pve-no-subscription repo in the build environment (buildenv
already carries it; the corosync headers come from the Proxmox
`libcpg-dev`/`libcmap-dev` packages, not patched corosync sources).
Deps resolved: glib, fuse, sqlite3, libqb, rrd/corosync, check.

The build emits the whole family — `pve-cluster`, `pve-cluster-dbgsym`,
`libpve-cluster-perl`, `libpve-cluster-api-perl` (S3-Perl Setup.pm),
`libpve-notify-perl` — at `9.1.7.1+dcve1`. The former `repacked`
variants `pve-cluster` (S4 deb tree) and `libpve-cluster-api-perl` are
retired: one source build now ships S1-S4 in one consistent set, and a
version without epoch is safe because no same-name repacked deb
competes (the upstream top Makefile cannot carry a `:` in filenames).

The `patches.lock.json` here records the sha256 of the PRISTINE
(pre-patch) files at `66c87e0`; `patch_guard.py --tree <source>`
verifies drift the same way as the deb-tree locks. (Fix 2026-10-30:
the original lock recorded the post-patch content and would have
rejected every build.)

Validation done: `patch_guard.py` green on pristine 9.1.7, patch
dry-runs green, and a REAL full build in a Debian trixie container —
all five debs built, lintian warnings only; the built `pmxcfs` carries
`nodes/<n>/bootc`, and `Cluster.pm`/`Setup.pm` carry their bootc hunks.
Runtime S1-S4 tests on the host remain PENDING — never deploy to the
host.

Anchors (verified against 9.1.7 before patching):

* `src/pmxcfs/status.h` — `VMTYPE_BOOTC` slot beside `VMTYPE_LXC`.
* `src/pmxcfs/status.c` — `vminfo_type_to_string()` returns `"bootc"`;
  `vmlist_hash_insert_vm()` / `vmlist_register_vm()` guards accept
  `VMTYPE_BOOTC`; `cfs_create_vmlist_msg()` serialises via the type map,
  no extra change.
* `src/pmxcfs/memdb.c` — `dir_contain_vm_config()` maps `nodes/<n>/bootc`;
  `memdb_recreate_vmlist()` scan chain gains the bootc branch.
* `src/pmxcfs/pmxcfs.c` — `create_symlinks()` adds the top-level
  `bootc → nodes/<node>/bootc` link (S3's C half — grepped: the link set
  lives HERE only, `create_pmxcfs_db.c` builds no hardcoded guest tree and
  needs NO patch).

The Perl half of S3/S4 lives in the deb-tree overlay dirs:
`workflows/bootc-debs-builder/pve-cluster` (S4, `Cluster.pm`) and
`workflows/bootc-debs-builder/libpve-cluster-api-perl` (S3 Perl part,
`Cluster/Setup.pm` `gen_local_dirs()`).