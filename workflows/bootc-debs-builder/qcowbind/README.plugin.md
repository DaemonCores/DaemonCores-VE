# qcowbind — PROTOTYPE storage plugin (v2)

LXC and KVM volumes as **qcow2 images on a dataset-backed Proxmox storage**.
Design decision (Gabriel, 2026-10-30, replacing the rejected ZFS-dataset
semantics): the qcow2 **is** the volume; the ZFS dataset is only the
container (pool-level compression + snapshots). Rationale: the qcow2 is the
only format where a shrink really returns space (`qemu-img convert --sparse`
/ sparsify); a ZFS refquota never reclaims anything.

## Two volume formats (v2)

Neutral naming throughout — no workload suffix in any format, plugin or
storage name.

| | format `qcow` | format `share` |
|---|---|---|
| Volume file | `<name>.qcow` (content: qcow2) | `<name>.share` (content: qcow2) |
| Consumer | ONE CT | N CTs **and** N VMs (virtiofs) |
| Size source | the CT configuration (`rootfs`/`mpX: …,size=` ) | the VOLUME (sidecar) — **never** a CT/VM conf |
| Resize | standard `pct resize` (plugin mechanics) | once, plugin-side: `qcowbind-resize` — applies to every consumer |
| Shrink | plugin-side convert+swap when unmounted/unbound | same precondition (single resize point) |

Why: a shared volume whose size were written in every consumer's
configuration would diverge the moment two consumers resize it. A share
therefore carries its size ONCE at the volume level; `pct resize` on a share
is refused by the plugin.

Files, relative to this directory:

- `usr/share/perl5/PVE/Storage/Custom/QcowBindPlugin.pm` — the plugin
  (storage type `qcowbind`, content images + rootdir, formats `qcow`+`share`).
- `usr/sbin/qcowbind-bind` — bind helper writing/removing the
  `lxc.mount.entry` bind line in `/etc/pve/lxc/<vmid>.conf`, refusing any
  CT-conf `size=` on a share, and managing the VM virtiofs face.
- `usr/sbin/qcowbind-resize` — THE single resize point for share volumes
  (marks the call with `QCOWBIND_DIRECT_RESIZE=1`; the plugin refuses any
  other caller).
- `t/` — sandboxed spec tests (stubbed PVE; nothing touches a real host).

## Storage registration

```
# /etc/pve/storage.cfg
qcowbind: qco
    path /SSD-600G/qcowbind
    mountdir /mnt/qcowbind
    content images,rootdir
```

- `path` must be on a dataset-backed directory (e.g. under the prepared
  SSD-600G pool, recordsize=64k) so pool snapshots and compression apply.
- `mountdir` is where the plugin mounts each volume host-side for the bind
  layer; `path()` exposes exactly that mountpoint (mp-bind semantics).

## Lifecycle through the standard PVE storage API (native UI)

| UI action | Plugin hook | What happens |
|---|---|---|
| Create volume | `alloc_image` | `qemu-img create -f qcow2` + sidecar `.qbind.json` (records format, size, owner) |
| Destroy volume | `free_image` | refuses while bound to a CT or attached as a VM disk; unmounts, disconnects nbd, removes the file |
| Resize volume | `resize_volume` | **grow**: `qemu-img resize` (safe while mounted). **shrink**: filesystem shrunk inside, volume unmounted + unbound, then `qemu-img convert -O qcow2 --sparse` + `resize` + swap — the only real reclamation path |
| CT start | `activate_volume` | nbd connect (`qemu-nbd -c /dev/nbdX`) + FS mount at `mountdir/<vol>` |
| CT stop | `deactivate_volume` | best-effort umount + nbd disconnect when nothing is bound |

## Multi-CT attach

The plugin owns the host-side mount. Attaching into containers:

```
qcowbind-bind add  121 qco:data.share /var/data
qcowbind-bind add  122 qco:data.share /var/data
qcowbind-bind drop 121 /var/data
```

A per-CT volume with its size in the CT conf:

```
qcowbind-bind add 121 qco:ci-tmp.qcow /var/tmp 5G
```

(produces `mp0: qco:ci-tmp.qcow,mp=/var/tmp,size=5G` — PVE binds the volume
from the plugin mountpoint at CT start and the standard `pct resize` then
applies to it). Each `add` is idempotent keyed on the target path inside
the CT; a share NEVER carries size (refused).

## VM face — virtiofs (v2)

A share is consumable by KVM VMs **without** ever touching the qcow2 as a
disk: the VM mounts the SAME kernel filesystem the CTs bind, through
virtiofs. One host-side mount (`qemu-nbd` + FS mount), one coherent source
of truth for every consumer.

```
qcowbind-bind vm-add  201 qco:data.share data-share
# → writes: virtiofs0: data-share=/mnt/qcowbind/data   (qm set)
qcowbind-bind vm-drop 201 data-share
```

Guard: `_vm_refs()` classifies every VM reference — a `scsiN/virtioN/sataN/`
line carrying the volid or the raw backing image path is a direct disk
attach and is **always refused** (activation, free); a `virtiofsN:` line
pointing at `bind_path()` is sanctioned. A VM and CTs can therefore share
one volume; a VM can never treat it as a disk.

Deployment notes (Gabriel GO — not wired yet):
- requires virtiofsd on the PVE host and a qemu-server build carrying the
  virtiofs VM-attribute support — verify on the custom PVE at deployment;
- guest side: mount the tag (`mount -t virtiofs data-share /data`).

## Guards

1. **No VM-disk attach, ever — virtiofs only for VMs** (see above).
2. **One CT per `qcow`** — the bind list refuses a second CT; a `share`
   accepts any number of writers (sharing is its purpose).
3. **Share resize policy** — `pct resize`/any caller without the
   plugin-side marker dies; the size of a share never lands in a CT conf
   (the bind helper refuses it, and refuses conf lines already carrying a
   `size=` for a share).
4. **Mount-consistency audit** — the sidecar records `mounted`, `nbd`,
   `mount`, `bound_cts`, `format`; `_audit_state()` cross-checks it against
   `findmnt` and the nbd pid at every activation and dies loudly on
   divergence (mounted-but-unrecorded, stale sidecar, live nbd with dead
   mount).

## Volume-name grammar

`<name>.qcow` / `<name>.share` with `name = [a-zA-Z0-9][a-zA-Z0-9._-]*` —
no vmid embedded, no workload suffix. The v1 `qb-<name>.qcow2` grammar is
refused by design (neutral v2 formats only).

## Deliberate deviations (prototype scope)

- vmid-scoped listing and vzdump do not apply (`list_volumes` returns
  empty for a vmid filter).
- Snapshots of the volume itself are not supported (pool-level dataset
  snapshots are the protection layer).
- Growing the image while mounted does NOT grow the guest filesystem: the
  FS inside is the guest's business; the plugin owns image-level operations
  only.

## Validation status

- `t/run-tests.sh` all green (50 plugin assertions + helper spec checks;
  sandboxed stubs, `perl -c` clean against the stubs, `bash -n` clean).
- The `compose2bootc` selftest covers the `.share` emission.
- Not yet exercised on a disposable CT (NOT on 120/121/122/130, NOT on the
  proxy VM); no live deployment before a Gabriel GO (storage/module
  install is a separate, GO-gated lane).