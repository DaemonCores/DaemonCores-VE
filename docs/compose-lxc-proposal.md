# Compose → LXC (« pct compose ») — design note

Status: PROPOSAL (option 3, validated by Gabriel 2026-10-29; the standalone
`pct-compose` wrapper is refused — everything goes through the PVE storage
plugin and the `pvect-ostree` binary). British spelling, house comment style.

## Principle (option 3)

There is no new orchestrator binary. The published artefact is a **template on
the `ostree` storage** (storeid `ostree`, type `pvect-ostree`), and the
standard Proxmox path is the entry point:

    pct create <vmid> ostree:vztmpl/<stack>.tar.zst [--unprivileged 1 ...]

The chain compose → build → smoke → publish lives in the plugin and in
`pvect-ostree` subcommands; the UI drives standard storage APIs plus those
subcommands. No fork of `pve-container`, no `pct` wrapper.

## Storage model

A published stack is a *seed template* plus book-keeping, all under the
plugin's own sysroot (no `storage.cfg` path guessing):

```
/var/lib/pvect-ostree/sysroot/vztmpl/<stack>.tar.zst          seed template
/var/lib/pvect-ostree/sysroot/vztmpl/<stack>.RELOCATIONS.txt  relocation report
/var/lib/pvect-ostree/compose/<stack>/docker-compose.yml      recorded source
```

* The seed tar is tiny: `pvect-ostree/payload.env` carries `STACK`, `IMGREF`,
  `COMPOSE`. `pct create` extracts it into the allocated subvol exactly like a
  normal Debian template — the standard code path is exercised end to end.
* The real rootfs is still the composefs deployment, mounted by the existing
  `pvect-ostree` machinery; the seed content is discarded (hidden, then wiped)
  at first activation.

### `pvect-ostree` subcommands (added)

| Subcommand | Role |
|---|---|
| `build <compose.yml> [--name N]` | runs `compose2bootc convert` (transpile, build, lint, smoke-gated test). Records the compose source under `/var/lib/pvect-ostree/compose/<name>/`. Fails before any publication if the smoke test fails. |
| `publish <compose.yml> [--name N] [--timer]` | `build` + write the seed template and `RELOCATIONS.txt` into `<sysroot>/vztmpl/`. Idempotent; a re-publish creates the next template revision. `--timer` installs the 7-day `compose2bootc-rebuild@` timer. |
| `templates [name]` | table of published templates: stack, image ref, ctime, compose source path. |
| `refresh <vmid>` | rebuilds from the recorded compose source (`reg_load` → `build` → existing `update`, so the previous deployment stays for rollback). Existing CTs are untouched until the update actually happens. |
| `adopt <vmid>` | wires a CT created from a template: reads the seed payload, deploys the image to stateroot `ct<vmid>`, writes the registry entry, mounts the composefs view (called by the plugin; also callable by hand). |

Registry entries gain a `COMPOSE=` line so `refresh` and the UI know the source.

### `OstreeComposefsPlugin.pm` changes

* `plugindata` gains `vztmpl` content.
* `parse_volname`/`filesystem_path` handle `vztmpl/<file>` under
  `<sysroot>/vztmpl/`.
* `list_volumes` override: lists the seed templates (standard `vztmpl` shape,
  so `pvesm list ostree` and the GUI template pickers work unchanged).
* `activate_volume`: if the CT is not yet registered but the subvol carries a
  seed payload, run `pvect-ostree adopt <vmid>` before mounting. This is what
  makes `pct create <vmid> ostree:vztmpl/<stack>.tar.zst` a working, native
  entry point.

### Flows

* Create CT from compose (CLI):
  `pvect-ostree publish /path/compose.yml --name web` then
  `pct create 8100 ostree:vztmpl/web.tar.zst --unprivileged 1` — the plugin
  adopts it at (re)start; `pvect-ostree normalise` is applied by `adopt`.
* Update a CT's compose (Edit Compose): rewrite
  `/var/lib/pvect-ostree/compose/<stack>/docker-compose.yml`, then
  `pvect-ostree refresh <vmid>` → new image, new deployment, rollback kept.
* Global template view: `pvect-ostree templates` + `pvect-ostree list` give the
  (template → CTs) lineages via `IMGREF`; clone = publish the edited compose
  under a new `--name`, so it never touches existing CTs.

## Guest-type separation (Gabriel, 2026-10-29 — priority over the UI plan above)

Requirement: compose2bootc/pvect-ostree containers must be **entirely
separated** from the official Proxmox LXC so official updates cannot collide
with our customisations.

**DELIBERATION CLOSED (Gabriel): variant A is VALIDATED — a genuine third
guest type beside LXC/QEMU, not a filter over CTs. Variant B is rejected as
an illusion of isolation.** The full variant A plan (surfaces S1-S10, house
patch skeletons in `workflows/bootc-debs-builder/{pve-cluster,pve-manager}/`,
per-surface validation tests, GO gate) lives in
**`docs/compose-variant-a-plan.md`** — read it with this file (the plugin/
storage-plugin and `pvect-ostree` groundwork below is reused unchanged by
variant A). Nothing is implemented until Gabriel's GO on that file; the two
patch skeletons exit 8 without `DC_VARIANT_A_GO=1`.

### Variant A — a genuine third guest type (registry-level)

Patch the core: `pve-manager` (resource type lists, tree, panels, API index),
`pve-cluster` (vmid pool/ticket realm), guest status and HA plumbing accept
`ct`/`qemu` plus a new `bootc` type. pve-container stays untouched but every
type-aware check (task permissions, backup jobs, HA manager, node resources,
migration) needs reviewing to avoid crashes on a type the core does not know.

* Separation: conceptually perfect, `bootc` types never appear in LXC trees.
* Update-collision risk: **high** — we patch the same core files Proxmox ships
  (`pve-manager` JS for the tree/panels, `pve-cluster` for vmid enumeration);
  every upstream update re-collides patch-by-patch, and a missed check
  (backup, tasks, HA) breaks at runtime, not at install time.
* Cost: large patch set across many files; each rebase is an audit.

### Variant B — UI-level type (recommended)

The CTs remain standard pct resources (so the whole core path is exactly the
official one: vmid, tasks, HA, backup, migration — zero core risk), but every
bootc CT is identifiable by **its storage (`ostree`) plus a dedicated tag**
(e.g. `tag: bootc`), and the web UI gets a top-level section **"Bootc
Containers"**, beside the LXC/QEMU buttons, never inside the LXC tree: its own
create-from-compose flow, edit-compose panel, template grid and clone button.
All compose2bootc/pvect-ostree specificity lives in the storage plugin + the
`pvect-ostree` binary (steps 1).

* Separation: everything *custom* is separated; the underlying guest object is
  a normal LXC and can still be seen by the official tools (an auditor's CT is
  a genuine pct — a feature for supportability).
* Update-collision risk: **low** — the pve-manager patch is additive (one new
  JS view + one small API2 module), not the deep surgery variant A needs.
* Consequence: someone *can* still open a bootc CT through the classic LXC
  view (read-only risk of confusion, not corruption — the immutable composefs
  posture is enforced on the host side by the plugin, not by the UI).

Recommendation (OBSOLETE — superseded 2026-10-30): variant B was
recommended here, but Gabriel has since **chosen variant A** — see
`docs/compose-variant-a-plan.md` for the validated plan.

## Web UI (pve-manager patch, steps 2–4 — not implemented yet)

Same two-file constraint as the existing GUI defaults/subscription patch:
one API2 module + one `www/manager6/lxc` JS file, applied by
`patch-defaults.sh`.

* `PVE/API2/Storage/Compose.pm` (new, patched into pve-manager):
  * `GET/POST nodes/{node}/storage/{storeid}/compose` — build/publish a
    composed YAML (build/publish subcommands as a task UPID), and
    `GET .../compose/{stack}/status` for the build log + `RELOCATIONS.txt`
    summary (polled by the UI).
  * `POST nodes/{node}/lxc/{vmid}/compose-refresh` — Edit Compose on an
    existing bootc CT → `pvect-ostree refresh`.
* Creator window (`www/manager6/lxc/CreateWizard` patch): a "Compose" tab —
  portainer-style textarea with minimal YAML validation, calls publish, shows
  the build log and the relocation summary, then pre-fills the template field
  with `ostree:vztmpl/<stack>.tar.zst` so the CT is created by the normal
  wizard (standard API, nothing bespoke).
* CT options panel: "Edit Compose" button for CTs whose registry entry has a
  `COMPOSE=` source (loads the recorded YAML into the same editor, then
  compose-refresh).
* Template view: a "Compose Templates" grid backed by `pvesm list ostree`
  (standard storage API) plus `pvect-ostree templates` for the (template →
  CTs) mapping; per-row buttons: Edit Compose (re-publish new revision) and
  Clone Template (publish under a new name, then open the create wizard with
  the new template pre-selected).

## Steps

1. **Step 1 (this batch)** — `pvect-ostree build/publish/templates/refresh/adopt`
   + plugin `vztmpl` support; tested on `iartistique`.
2. Step 2 — API2 module + create-wizard "Compose" tab (after Gabriel's green
   light on the conversation).
3. Step 3 — CT "Edit Compose" + refresh endpoint.
4. Step 4 — template view (list/edit/clone).

## Invariants respected

No fork of `pve-container`; the trigger lives in the plugin/binary; the UI only
uses standard storage APIs plus one small API2 module. Secrets never leave the
host (EnvironmentFile mechanism unchanged). Smoke must pass before publish —
a stack never reaches a template with a failing image.