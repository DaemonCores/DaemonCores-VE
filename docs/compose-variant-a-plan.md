# Variant A — third guest type `bootc` (VALIDATED architecture, implementation gated)

Status: **PLAN COMPLETE (Gabriel validated variant A 2026-10-30 — B rejected).
NO IMPLEMENTATION YET**: every patch below is written as a house
`patch-defaults.sh` skeleton that **refuses to run** until Gabriel signs off
the whole plan (gate: `DC_VARIANT_A_GO=1`). British spelling, house comment
style, `+dcve1` deb suffix, skip exit 3 on drift, sha256 + `apt-mark hold` and
issue notification — same repack model as the libpve-storage-perl lane.

This document supersedes the variant-B recommendation in
`docs/compose-lxc-proposal.md` (that doc keeps the storage-plugin and
`pvect-ostree` groundwork, which variant A reuses unchanged).

## Principle

`bootc` containers are a **genuine third guest type** beside `qemu` and `lxc`,
not a filter over CTs. They never appear in the LXC tree, never traverse LXC
code, and are managed by `pvect-ostree` the way `qemu-server`/`pve-container`
manage their own guests. `pve-container` is **not** patched (invariant kept);
the core packages extended are `pve-cluster` (C + Perl) and `pve-manager`
(Perl API + JS UI).

Grounding: the hard-wired guest machinery was verified in the upstream trees
(pve-cluster `src/pmxcfs/memdb.c`, `src/pmxcfs/status.c`; pve-manager
`PVE/API2/Cluster.pm`, `PVE/API2/Nodes.pm`).

## Surfaces (S1–S12)

### Group 1 — pve-cluster: guest registry and pmxcfs (C + Perl)

|#| File | What to patch |
|---|---|---|
|S1|`src/pmxcfs/status.h` + `src/pmxcfs/status.c` (C)|`VMTYPE_BOOTC` enum entry; `vmtype_name()` returns `"bootc"`; the conf-dir mapping (`qemu-server`/`lxc`/`openvz` special cases) gains `- bootc`; the `g_return_if_fail(vmtype == VMTYPE_QEMU \|\| ...)` guards in `vmlist_register_vm()`/`vmlist_hash_insert_vm()` accept `VMTYPE_BOOTC`; `cfs_create_vmlist_msg()` serialises it as `type: "bootc"`.|
|S2|`src/pmxcfs/memdb.c` (C)|`dir_contain_vm_config()`: directory `bootc` under `nodes/<node>/` → `VMTYPE_BOOTC`; `vmlist_add_dir()` scan chain in the mem-db initial walk gains a `VMTYPE_BOOTC` branch (the walk currently loops qemu-server / openvz / lxc only); create/rename/delete hooks already dispatch on `dir_contain_vm_config()`, so no extra hook needed.|
|S3|`src/pmxcfs/create_pmxcfs_db.c` + pmxcfs default layout + `PVE/Cluster.pm gen_local_dirs()` (C + Perl)|New per-node conf dir `nodes/<node>/bootc/` and the top-level symlink `bootc → nodes/<NODENAME>/bootc` (mirrors `lxc`). **Anchor to verify at GO** on the installed tree: the link set lives in the pmxcfs startup layout and/or `gen_local_dirs()`; both must be grepped before patching.|
|S4|`PVE/Cluster.pm` (Perl)|`%file_info` gains the `bootc` directory; `cfs_file_version()` regex `(openvz\|lxc\|qemu-server)` extended with `bootc`; `check_vmid_unused()` error wording handles a third type (not `VM`/`CT` binary); `cfs_read_file`/`cfs_write_file` need no change (generic). `next_vmid()`, `complete_vmid()` and friends are already vmlist-driven and type-blind — no change.|

### Group 2 — pve-manager Perl: API and services

|#| File | What to patch |
|---|---|---|
|S5|`PVE/API2/Cluster.pm` (`resources` endpoint)|`type` enum `['node','storage','pool','qemu','lxc','sdn']` gains `'bootc'`; `%$hatypemap` gains nothing (bootc is deliberately **not HA-manageable** — HA must skip it, see S8); the guest resource builder maps vmlist entries `{type: 'bootc'}` to a bootc resource with status read from the guest-status source (S8).|
|S6|`PVE/API2/Nodes.pm`|Node index: `{ name => 'bootc' }` entry beside `lxc`/`qemu`; `$get_filtered_vmlist` (`die "unknown virtual guest type"`) plus `startall`/`stopall` branches route bootc guests to `PVE::API2::Bootc::Status` instead of LXC/Qemu paths. Autostart ordering uses the same `startup/order` field.|
|S7|`PVE/API2/Bootc.pm`, `PVE/API2/Bootc/Status.pm` (NEW modules)|Root `nodes/{node}/bootc` index; `create` (vztmpl + options → `pvect-ostree create`), `Status` (`start`/`stop`/`shutdown`/`status`/`destroy` → `pvect-ostree start/stop/...`), `compose-refresh` (→ `pvect-ostree refresh <vmid>`), all as UPID tasks. Permissions reuse the standard `VM.` privileges (`VM.PowerMgmt`, `VM.Allocate`, ...) against the bootc realm so ACLs behave identically. Conf file: `nodes/<node>/bootc/<vmid>.conf` written by `pvect-ostree create` (registered by S2).|
|S8|`PVE/Service/pvestatd.pm`, `PVE/VZDump.pm` family, HA paths|pvestatd: per-node bootc status (running state) for `/cluster/resources` + RRD, sourced from a status file under the plugin sysroot (same shape pmxcfs conf consumers expect); vzdump/backup-job filtered vmlists **skip** bootc guests (v1: no vzdump of bootc — snapshot/rollback is an ostree deployment flip, documented as out of scope); HA CRM/manager: bootc guests are skipped (not in `hatypemap`); migration: `pvect-ostree refresh` replaces it — `migrateall` and the per-guest migrate path must refuse bootc with a clear error instead of crashing.|

### Group 3 — pve-manager JS: UI

|#| File | What to patch |
|---|---|---|
|S9|`www/manager6/Utils.js`, `pvePanel/Workspace.js`, tree/store|Guest type map (`Utils.guest_types` / shared `pveUtils` type registry) gains `'bootc'`; `ResourceStore`/`ResourceTree` render bootc nodes in their **own top-level section** (never inside the LXC tree); workspace top bar gains the "Bootc Containers" button beside LXC/QEMU.|
|S10|`www/manager6/bootc/*.js` (NEW files)|`Create.js` (portainer-style compose editor → publish → build log + relocations → template pre-selected), `Edit.js` (open the recorded YAML, compose-refresh), `Templates.js` (grid from `pvect-ostree templates` + `pvesm list ostree`, per-row Edit/Clone), `Status.js` (start/stop/destroy, task logs). Wired into S9's section; one new file set, additive.|

### Lifecycle (owned by `pvect-ostree`, not pve-container)

`pvect-ostree` gains `start <vmid>` / `stop <vmid>` / `status <vmid>` /
`create <vmid> <vztmpl> [--options]` so S6/S7/S8 only shell out. `adopt` keeps
its role (seed payload wiring) and is invoked by `start`. This is additive
binary work, no core daemon forked.

## Repack mechanics (same model as libpve-storage-perl)

* Packages: `pve-cluster` (`3:<ORIG>+dcvbootc1`), `pve-manager` (`2:<ORIG>+dcvbootc1`) —
  distinct suffixes so a drift-skip never silently ships one package unpatched.
* C patches are verified by a real `dpkg-buildpackage` (or `make -C src` +
  `perl -c` for the Perl modules) inside the builder; `pmxcfs` is smoke-run
  with `-f` against a throwaway memdb before the deb is published.
* Anchors: every patch greps the exact upstream line (quoted in the
  `patch-defaults.sh` skeletons) and skips with exit 3 + issue report on
  drift — never ships unpatched.
* Deployment on `iartistique` (debug host): snapshot first, apt-mark hold,
  sha256 before/after in `/var/lib/dc-bootc-test/`, restart
  `pve-cluster` (pmxcfs!) + `pvedaemon` + `pveproxy`. Prod transition only
  after full validation and re-GO from Gabriel.

## Skeletons on disk (this batch, NOT wired into packages.yml)

* `workflows/bootc-debs-builder/pve-cluster/patch-defaults.sh`
* `workflows/bootc-debs-builder/pve-manager/patch-defaults.sh`

Both exit with **"variant A not validated yet — refusing to patch"** unless
`DC_VARIANT_A_GO=1` is exported. Their per-surface `patch_s<N>()` functions
contain the anchors and the target edits as documented stubs; wiring
`packages.yml` + filling the stubs is the implementation step, executed only
after Gabriel's GO on this file.

## Validation tests per surface

| Surface | Test |
|---|---|
|S1/S2 (pmxcfs)|Unit: local memdb build + `pmxcfs -f` on a throwaway db; create/edit/delete `nodes/<n>/bootc/<vmid>.conf` through the mounted fs; `/etc/pve/.vmlist` shows `{type: "bootc"}` after edits; lxc/qemu vmlist entries unchanged.|
|S3|`bootc` dir + symlink exist after pmxcfs start; `gen_local_dirs()` idempotent rerun.|
|S4|`perl -c Cluster.pm`; `pvesh get /cluster/nextid` avoids a bootc vmid; duplicate-vmid error wording.|
|S5|`pvesh get /cluster/resources --type bootc` lists the test guest; `--type lxc` output unchanged (byte-diff vs pre-patch snapshot).|
|S6|`pvesh get /nodes/<n>` index contains `bootc`; `startall`/`stopall` with one bootc + one lxc guest: bootc starts via pvect-ostree, lxc path untouched.|
|S7|End-to-end on iartistique: `pvect-ostree create` a test guest `from ostree:vztmpl/ctest01.tar.gz` (existing validated template), start → adopt + composefs mount + http 8080 (state P-02 pending flow reused), stop, destroy, vmid reused.|
|S8|pvestatd running, `/cluster/resources` carries the bootc guest with correct status; vzdump dry-run job list excludes bootc; `migrate` on bootc refuses with the dedicated error; HA disabled on this node in any case.|
|S9|`pveproxy` restarted; UI loads without JS errors (console check over the debug host); bootc section renders; LXC tree unchanged.|
|S10|Create-from-compose on the test stack; Edit Compose → refresh shows a new deployment, old one kept for rollback; Templates grid lists `ctest01`; Clone publishes a new revision name.|
|Cross|Official upstream update re-run of the anchor greps (CI) proves drift detection; `sha256sum` report archived; `pve-container` binary untouched (dpkg -V clean).|

## Explicit non-goals (v1)

* No HA support for bootc guests. No vzdump of bootc guests.
* No live migration of bootc guests (push model = publish + refresh).
* No change to `pve-container` or `qemu-server`.