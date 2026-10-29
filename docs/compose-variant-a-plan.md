# Variant A — third guest type `bootc` (VALIDATED architecture, implementation gated)

Status: **IMPLEMENTED via the overlay model (Gabriel spec 2026-10-30)**,
S5-S8 of the pve-manager surface + the qemu-server VM defaults + the
libpve-storage-perl ZFS patches are shipped as `workflows/bootc-debs-builder`
overlay trees / git-format patches in `packages.yml` (one generic build, drift = `patch --fuzz=0
--forward` refusing a hunk). S9/S10 (JS UI wiring, bootc panels) are
**IMPLEMENTED as appended hunks of `pvemanagerlib.js.patch`** (S9: tree
type defaults + ordering, always-grouped bootc section, `treeTypeToClass`
routing, Workspace "Bootc Containers" button, node command-menu
"Create Bootc"; S10: `PVE.bootc.Templates/Create/Editor/Edit/Status`
appended to the bundle — never standalone files, the deb ships no www/
tree). `s10-pending/www/bootc-classes.js` keeps the S10 payload source of
truth for review; its content is byte-identical to what the patch appends.
New in S7 plumbing to serve the UI: `pvect-bootc publish/templates/
compose-read` verbs and `PVE::API2::Bootc` endpoints `compose/{stack}`
(POST publish), reworked `templates` (TSV from the wrapper) and
`template/{stack}/compose`. `pve-cluster` S1-S4 (pmxcfs C + Perl) are
**IMPLEMENTED (2026-10-29)**: deb-tree overlays `pve-cluster/` (S4,
`Cluster.pm`) + `libpve-cluster-api-perl/` (S3 Perl part, `Cluster/Setup.pm`
`gen_local_dirs`) added to the `repacked` class of `packages.yml`, plus a C
source lane `workflows/bootc-debs-builder/pve-cluster-src/` (S1-S3 pmxcfs
patches: `status.h`/`status.c` `VMTYPE_BOOTC`, `memdb.c`
`dir_contain_vm_config`/vmlist scan, `pmxcfs.c` `create_symlinks` top-level
`bootc` link — anchored on the upstream tree at 9.1.7, commit `66c87e0`;
the deb ships binaries so the C hunks cannot ride the deb overlay — see the
lane README). British spelling, house comment style,

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

## Repack mechanics (overlay model, Gabriel spec 2026-10-30)

Packages repackés (entry `packages.yml`): `libtemplate-perl` (+bootc1),
`libpve-storage-perl` (+dcve1), `pve-manager` (+bootc1), `qemu-server`
(+bootc1) — build générique IDENTIQUE dans `packages.yml`, seuls deux
var changent par entrée (`PKG=...`, `VER_SUFFIX=...`):

1. `dpkg-deb -R` de l'upstream téléchargé.
2. `"$CI_SCRIPTS/apply_overlays.sh" workflows/bootc-debs-builder/<pkg> "$O"`
   (script partagé DaemonCores-CI, exporté par `build-deb.sh:run_build`) :
   - le dossier paquet est le MIROIR EXACT de l'arbre du deb — fichiers
     NOUVEAUX copiés tels quels (`pve-manager/usr/...`) ;
   - fichiers MODIFIÉS = `.patch` git-format au CHEMIN MIROIR du fichier
     patché (ex: `pve-manager/usr/share/pve-manager/js/pvemanagerlib.js.patch`
     à côté du vrai fichier)
     (les ancres sont les hunks ; `--fuzz=0 --forward`, dry-run complet
     AVANT toute application → jamais d'arbre à moitié patché ; drift =
     exit 3 + annotation + step summary) ;
   - `*.patch` et `patches.lock.json` ne sont jamais copiés dans le deb.
3. md5sums regénérés, `Version: 1:<ORIG>+<VER_SUFFIX>`, `dpkg-deb --build`.

Drift double garde: `apply_overlays.sh` (le patch tool lui-même) et
`patches.lock.json` (sha256 des fichiers touchés, vérifiables par
`patch_guard.py --tree <arbre-vierge>`; à câbler dans le CI de la même
manière que kernel-patches si besoin).

### État des surfaces

* pve-manager S5 (Cluster.pm), S6 (Nodes.pm), S7 (modules Bootc +
  wrapper `pvect-bootc`), S8 (pvestatd `update_bootc_status` finalisé —
  RRD pve2-vm statut+nom seulement, pas de compteurs; vzdump skip bootc) :
  **livrés** (`.patch` + fichiers nouveaux). Ancrages régénérés contre
  l'arbre trixie `pve-manager 9.2.9` (download.proxmox
  pve-no-subscription) — c'est le tree exact que `apt-get download`
  résout dans le builder.
* S9/S10 : **livrés** dans le hunk `pvemanagerlib.js.patch` (S9 câblage
  tree/Workspace/menu + S10 classes `PVE.bootc.*` appended au bundle;
  `s10-pending/www/bootc-classes.js` = source du payload, reportée dans
  le hunk). Les stubs S9/S10/S10-check de l'ancien .sh n'ont JAMAIS eu de
  corps (aucun câblage JS) — remplacés par les hunks ci-dessus.
* pve-cluster S1-S4 : **livrés 2026-10-29** — hunks générés contre
  l'arbre vierge ; Perl : `Cluster.pm` (S4) ancré sur le deb
  `pve-cluster 9.1.7`, `Cluster/Setup.pm` `gen_local_dirs` (S3-Perl) sur le
  deb `libpve-cluster-api-perl 9.1.7` ; C (S1/S2/S3-C) = lane source
  `workflows/bootc-debs-builder/pve-cluster-src/` ancrée sur le git
  upstream `pve-cluster` au commit `66c87e0` (= 9.1.7) — les hunks C ne
  peuvent pas rouler dans l'overlay du deb (binaires). Validé : dry-run +
  application réelle sur arbres vierges, `patch_guard.py` sur les 3 locks,
  `perl -c` (stubs PVE) sur les 2 fichiers Perl, compilation objets réelle
  (`gcc -c`) des 3 unités C patchées avec les en-têtes
  glib/fuse/sqlite/libqb/rrd/corosync. Build deb complet
  (dpkg-buildpackage) : **PENDING** (environnement de packaging requis).
  Anchor vérifié au GO : le set de liens top-level vit dans
  `src/pmxcfs/pmxcfs.c::create_symlinks` (pas create_pmxcfs_db.c — le
  binaire importe un arbre, aucun répertoire invité codé en dur).
* qemu-server : les 7 patchs VM-defaults (ovmf/cpu/firewall/writethrough/
  agent/efidisk/q35) portés verbatim en hunks.
* `libpve-storage-perl` : 2 hunks ZFS, suffix +dcve1 conservé.

Débats: les patchs ont été VALIDÉS en appliquant réellement
apply_overlays.sh sur les arbres vierges `dpkg-deb -R` téléchargés
(pve-manager/qemu-server/libpve-storage-perl 9.2.9/9.1.9 + libtemplate-perl
2.27-1+b8), avec perl -c (stubs PVE) / `node --check` et patch_guard.

* Deployment on `iartistique` (debug host): snapshot first, apt-mark hold,
  sha256 before/after in `/var/lib/dc-bootc-test/`, restart
  `pve-cluster` (pmxcfs!) + `pvedaemon` + `pveproxy`. Prod transition only
  after full validation and re-GO from Gabriel.

## Skeletons on disk → IMPLEMENTED

The variant A pve-manager/qemu-server surfaces live as the overlay trees and
git-format patches under `workflows/bootc-debs-builder/` (see
Repack mechanics above); the gate script (`DC_VARIANT_A_GO`) is gone — the
surfaces are built unconditionally now, guarded by patch-tool drift instead.

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