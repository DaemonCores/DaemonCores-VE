# DaemonCores-VE — CI catch-up plan (audit vs DaemonCores-CI / debian-bootc)

Audit date: 2026-10-30. Baselines: `DaemonCores-CI` @ `27c5d8b`, `debian-bootc` @ `d70173b`,
`DaemonCores-VE` @ `1a82a05`. Compared what VE consumes from the shared CI
(workflows, packages.yml schema, versioning, publish/hashes.json, image build,
install-iso stage, next-version, manifest-expand, kickstart) against what the
shared CI and debian-bootc provide today.

## What VE already honours (no action)

- Thin-callers `.github/workflows/pipeline.yml` and `docs-wiki-sync.yml` point at
  `DaemonCores-CI/full-pipeline.yml@main` — current contract (triggers +
  concurrency in the caller, orchestration in the shared workflow).
- The debs builder is manifest-driven: `bootc-debs-builder.yml`, `manifest-expand`
  and `build-one-deb` read the CALLER's `workflows/bootc-debs-builder/packages.yml`
  and tolerate the simple schema VE uses (`name/upstream/sources/build/env`).
  The new keys debian-bootc now uses (`track`, `when`, `variants`,
  `variant-*`, `deb-glob`, `secret-env`) are all optional. No schema migration
  needed for VE's packages.
- `hashes.json` publication and the `debs-cache` dedupe flow live in
  `bootc-debs-end@main` — consumed automatically.
- ISO media upload to the `install-iso` release is in the shared `iso-builder.yml`.

## Écart 1 — image build contract: missing `Containerfile.base` (BROKEN) — FIXED

The current `bootc-build.yml` requires every repo to expose a `Containerfile.base`
at the root: the per-matrix build job (1) hashes its `FROM` into the content
hash and (2) runs a dedicated base build step tagged
`localhost/debian-bootc-base`, then passes `--build-arg
BASE_IMAGE=localhost/debian-bootc-base` to the product build. VE has no
`Containerfile.base`, and its `Containerfile` does `FROM
ghcr.io/daemoncores/debian-bootc:latest` directly: the content-hash step greps a
nonexistent file and the base build step finds no manifest — every image job for
VE fails at the two first steps.

Fix applied:
- new `Containerfile.base`: `FROM ghcr.io/daemoncores/debian-bootc:latest` with
  the pass-through `ARG BASE_IMAGE` contract, so the external base (and its
  digest, part of the content hash) stays the published debian-bootc image.
- `Containerfile` switched to `ARG BASE_IMAGE=localhost/debian-bootc-base` +
  `FROM ${BASE_IMAGE}` (debian-bootc model).

## Écart 2 — build-env manifest path (BROKEN) — FIXED

`bootc-debs-builder.yml` → `build-env.yml@main` defaults its manifest to
`workflows/env.yml`; VE kept it at `workflows/build-env/env.yml`, so the
`:buildenv` stage fails with a missing file, and the debs stage (which needs
`:buildenv-<arch>`) fails with it. Fixed by moving the file to
`workflows/env.yml` (and updating `docs/architecture.md`).

## Écart 3 — image-test manifest path — FIXED

The shared `image-test@main` action defaults to `workflows/tests.yml`; VE kept
the manifest at `workflows/image-tests/tests.yml`, so every boot-test step fails
to find the manifest even once the images build again. Fixed by moving it to
`workflows/tests.yml`. The manifest schema itself is compatible
(`boot_timeout`, per-test `run`/`expect`/`diag`); `boot_timeout: 900` can be
tightened later once the Proxmox-stacked boot time is measured (see Pending).

## Écart 4 — release/versioning thin caller — FIXED

debian-bootc has `.github/workflows/release.yml` (edge on push, stable on
dispatch) against `DaemonCores-CI/release.yml@main`; VE has none. Added the same
thin caller.

## Écart 5 — arm64 builds of VE images (PENDING — Gabriel)

`bootc-build.yml` discovers every root `Containerfile*` and always emits an amd64
AND an arm64 matrix entry (native runners, no cross-build). VE's product
Containerfile is not arch-parameterised: it installs `proxmox-default-kernel`
and the whole Proxmox stack and prunes `/usr/lib/modules` — the arm64 entry will
go red every push unless the Containerfile gains an `ARG ARCH` switch (or the VE
product is declared amd64-only somehow in the shared builder). Gabriel's call —
either arm64 VE support is in scope, or a shared-matrix opt-out knob is added
to the CI. Not improvised here.

## Écart 6 — APT key rotation story for VE's own repository (PENDING — Gabriel)

The CI convention is that images derive the pinned APT-key sha256 at build time
from the `APT_GPG_KEY` secret (`apt-key-hash.sh`); debian-bootc's
`Containerfile.base` takes `BOOTC_APT_URL`/`BOOTC_GPG_SHA256` build-args so a
rotation never needs a commit, and debian-bootc has a `rotate-apt-key.yml` thin
caller. VE still hardcodes `DAEMONCORES_VE_GPG_SHA256` (plus the Proxmox
archive key) in its `Containerfile`: a key rotation of its own repo (or an
upstream Proxmox keyring replacement) breaks the image build. Options to
decide: (a) mirror the debian-bootc build-arg model for VE's own repo key and
add the `rotate-apt-key.yml` thin caller; (b) keep pinned hashes and treat a
new key as an intentional Containerfile change. Not improvised here.

## Écart 7 — lint gate (NOT ADOPTED for now)

debian-bootc runs `lint.yml@main`, but the caller contract requires a
`Makefile` with `admission check docs-check` targets. VE has no Makefile; adding
one is a product repo decision, not a catch-up necessity. PENDING (low priority).

## Écart 8 — kickstart / installer image (OBSOLETE vs in-flight; PENDING)

The `DaemonCores-CI/kickstart/iso-config.ks.tpl` Anaconda-style installer is a
historic stage; the current path is `bootc-image-builder` driven by the shared
`iso-builder.yml`, which pulls the caller's `<latest|iso|iso-minimal>`-tagged
images. VE ships no `Containerfile.iso` / `Containerfile.minimal`, so the shared
ISO stage will pull tags that do not exist and go red once the image stage is
green again. Building those installer Containerfiles (live cage + bootc-installer
env, fisherman payload from the debian-bootc APT repo) is a project of its own;
kept PENDING rather than half-implemented. Note: `iso-builder.yml` references
`latest-${ARCH}-autoupdate` tags which today's `bootc-build.yml` tag matrix does
not emit — the ISO stage contract may be mid-flight on the CI side; verify against
`DaemonCores-CI` again before starting Écart 8.

## Écart 9 — parallel restructure lane (NOT TOUCHED, coordination note)

The lane restructuring `pve-manager` / `qemu-server` / `libpve-storage-perl`
toward the "arbre miroir + .patch git + helper shared CI_SCRIPTS" spec is in
progress in this repo (dirty `workflows/bootc-debs-builder/pve-manager/*`,
`pve-cluster/`, `pvect-ostree`, and `packages.yml`). This catch-up work touches
none of those paths and rebase-on-top was planned: lane commits land first, then
these fixes are rebased or pushed after. debian-bootc's tree (its
`packages.yml`, `ifupdown2postinstall`) is likewise being worked on — untouched.