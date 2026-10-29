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

Rebuild flow (when wired, PENDING): clone at the commit, apply this tree
with `patch --fuzz=0 --forward -p1 -d <source>`, then
`dpkg-buildpackage -b` (build deps: libglib2.0-dev, libfuse-dev,
libsqlite3-dev, corosync, libqb-dev, librrd-dev, check — see
`debian/control`; Debian trixie lacks the `corosync/cpg.h` family in
`libcorosync-common-dev`, take them from the corosync sources). The
`patches.lock.json` here records the sha256 of the pristine source files
the patches touch; `patch_guard.py --tree <source>` verifies drift the
same way as the deb-tree locks.

Validation done: the dry-run/apply round-trip plus `patch_guard.py` guard
on a pristine 9.1.7 checkout, AND a real object compile of the three
patched units (`gcc -c -DHAVE_CONFIG_H -D_FILE_OFFSET_BITS=64` with
glib/fuse/sqlite/qb/rrd/corosync headers against 9.1.7) — `status.c`,
`memdb.c`, `pmxcfs.c` all compile clean. Full `make`/deb packaging lane is
still PENDING (needs the packaging build environment).

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