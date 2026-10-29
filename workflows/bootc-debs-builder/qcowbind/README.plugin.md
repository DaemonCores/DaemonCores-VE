# qcowbind — PROTOTYPE storage plugin

Shared multi-CT volumes as **qcow2 images on a dataset-backed Proxmox storage**.
Design decision (Gabriel, 2026-10-30, replacing the rejected ZFS-dataset
semantics): the qcow2 **is** the volume; the ZFS dataset is only the
container (pool-level compression + snapshots). Rationale: the qcow2 is the
only format where a shrink really returns space (`qemu-img convert --sparse`
/ sparsify); a ZFS refquota never reclaims anything.

Files, relative to this directory:

- `usr/share/perl5/PVE/Storage/Custom/QcowBindPlugin.pm` — the plugin
  (storage type `qcowbind`, content images + rootdir).
- `usr/sbin/qcowbind-bind` — bind helper writing/removing the
  `lxc.mount.entry` bind lines in `/etc/pve/lxc/<vmid>.conf`.

## Storage registration

```
# /etc/pve/storage.cfg
qcowbind: qcowbind-ia
    path /SSD-600G/qcowbind
    mountdir /mnt/qcowbind
    content images,rootdir
```

- `path` must be on a dataset-backed directory (e.g. under the prepared
  SSD-600G pool, recordsize=64k) so pool snapshots and compression apply.
- `mountdir` is where the plugin mounts each volume host-side for the CT
  bind layer.

## Lifecycle through the standard PVE storage API (native UI)

| UI action | Plugin hook | What happens |
|---|---|---|
| Create volume | `alloc_image` | `qemu-img create -f qcow2` + sidecar `.qbind.json` |
| Destroy volume | `free_image` | refuses if bound/referenced by a VM, unmounts, disconnects nbd, removes the file |
| Resize volume | `resize_volume` | grow = `qemu-img resize`; shrink = `qemu-img convert --sparse` + `resize` + swap (the only real reclamation path) |
| CT start | `activate_volume` | nbd connect (`qemu-nbd -c /dev/nbdX`) + FS mount at `mountdir/<vol>` |
| CT stop | `deactivate_volume` | best-effort umount + nbd disconnect when nothing is bound |

## Multi-CT attach

The plugin owns the host-side mount. Attaching into containers:

```
qcowbind-bind add  121 qcowbind-ia:qb-ia-ssd.qcow2 /data/ia-ssd
qcowbind-bind add  122 qcowbind-ia:qb-ia-ssd.qcow2 /data/ia-ssd
qcowbind-bind drop 121 /data/ia-ssd
```

Each `add` writes `lxc.mount.entry: <mountdir>/<vol> <path-in-ct> none bind,rw 0 0`
and records the CT in the sidecar `bound_cts` list; the volume stays mounted
while any CT binds it.

## Guards

1. **KVM conflict** — `activate_volume` and `free_image` scan
   `/etc/pve/qemu-server/*.conf` and refuse anything that references the
   volume (volid, raw path or bind mountpoint). A qcowbind volume can never
   also be a VM disk.
2. **Mount inconsistency** — the sidecar records `mounted`, `nbd`, `mount`
   and `bound_cts`; `_audit_state()` cross-checks it against `findmnt` and
   `/sys/block/nbdX/pid` at every activation and dies loudly on divergence
   (mounted-but-unrecorded, stale sidecar, live nbd with dead mount).

## Deliberate deviations (prototype scope)

- Volume names carry no vmid (`qb-<name>.qcow2`): volumes are shared, so
  vmid-scoped listing and vzdump do not apply (`list_volumes` returns empty
  for a vmid filter).
- Snapshots of the volume itself are not supported (the pool-level dataset
  snapshots are the protection layer).
- Shrinking requires: filesystem shrunk inside → all CTs unbound → volume
  unmounted → resize. Enforced by the plugin.

## Validation status

- `perl -c` clean (against PVE stubs).
- Not yet exercised on a disposable CT (PAS sur 120/121/122/130, PAS la VM
  proxy); no live deployment before a Gabriel GO.