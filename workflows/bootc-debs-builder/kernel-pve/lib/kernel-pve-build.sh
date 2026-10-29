#!/usr/bin/env bash
# Build script run INSIDE a debian:trixie container by the kernel-pve
# reusable workflow (DaemonCores-CI/.github/workflows/kernel-pve.yml).
#
# Recipe (docs/kernel-nvidia-pve-host-plan.md §2, transverse variants):
#   1. enable the Proxmox trixie repo and apt-get source the PVE kernel
#      packaging (the version is passed in, resolved by the workflow);
#   2. merge the XanMod kconfig fragment;
#   3. apply the XanMod patch set (lib in the manifest repo, dry-run all
#      first);
#   4. ONE patched tree; every amd64 flavour in KERNEL_FLAVOURS (x64v1,
#      x64v3 — x64v2 optional on request) is a config-fragment change plus a
#      repackage pass over that same tree: no N full kernel builds. arm64 is
#      ONE cross-compiled build.
#   5. debs land in $KERNEL_OUT as artifacts, never auto-installed.
#
# Env read: KERNEL_SERIES, KERNEL_VERSION, KERNEL_FLAVOURS (amd64),
#   KERNEL_ARCH (x86_64 | arm64), KERNEL_GPU (space-separated GPU config sets
#   merged from kconfig/gpu/, "all" = every fragment of that directory;
#   default "all" — ONE optimised build carries every vendor transversely).
#   /src = checkout of the manifest repo.
set -euo pipefail

KERNEL_SERIES="${KERNEL_SERIES:?}"
KERNEL_VERSION="${KERNEL_VERSION:?}"
KERNEL_ARCH="${KERNEL_ARCH:?x86_64|arm64}"
KERNEL_FLAVOURS="${KERNEL_FLAVOURS:-x64v1 x64v3}"

export DEBIAN_FRONTEND=noninteractive
export ARCH="${KERNEL_ARCH}"

echo "deb [arch=amd64] https://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve.list
echo "deb-src [arch=amd64] https://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  >> /etc/apt/sources.list.d/pve.list
curl -fsSL https://download.proxmox.com/debian/proxmox-release-trixie.gpg \
  -o /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg

apt-get update
apt-get install -y --no-install-recommends \
  build-essential dpkg-dev devscripts curl git yq patch \
  bc bison flex libncurses-dev libssl-dev libelf-dev rsync kmod python3
[[ "${KERNEL_ARCH}" = "arm64" ]] && \
  apt-get install -y --no-install-recommends crossbuild-essential-arm64 gcc-aarch64-linux-gnu

mkdir -p /out /build
cd /build
apt-get source "proxmox-kernel-7.0"

# The packaging unpacks to a linux-* dir; find the tree we patch and build.
SRCDIR=$(find /build -maxdepth 1 -type d -name 'linux-*' | head -1)
[[ -n "${SRCDIR}" ]] || { echo "ERROR: no kernel source tree in /build" >&2; exit 1; }

# Patch once on the shared tree (dry-run the entire set before any touch).
. /src/workflows/bootc-debs-builder/kernel-pve/lib/kernel-pve-patches.sh
pve_kernel_apply_patches \
  /src/workflows/bootc-debs-builder/kernel-pve/patches.yml \
  common "${KERNEL_VERSION}" "${SRCDIR}"

KCFG_DIR=/src/workflows/bootc-debs-builder/kernel-pve/kconfig
merge_config() {
  # Fragments are append + olddefconfig (the debian-bootc kernel config
  # merge pattern): the fragment wins, olddefconfig resolves the rest.
  cat "$1" >> "${SRCDIR}/.config"
  make -C "${SRCDIR}" olddefconfig
}

# GPU sets (transverse vendor support, ONE build, no matrix): every set in
# KERNEL_GPU (default "all") is merged AFTER the flavour fragments so a GPU
# delta wins over the generic config. "all" follows the files actually
# present in kconfig/gpu/, so adding a vendor is a file, not a script edit.
for gs in ${KERNEL_GPU:-all}; do
  if [[ "${gs}" == "all" ]]; then
    for frag in "${KCFG_DIR}/gpu/"*.cfg; do
      [[ -f "${frag}" ]] && merge_config "${frag}"
    done
  else
    frag="${KCFG_DIR}/gpu/${gs}.cfg"
    [[ -f "${frag}" ]] && merge_config "${frag}" || \
      { echo "ERROR: unknown GPU set '${gs}' (no kconfig/gpu/${gs}.cfg)" >&2; exit 1; }
  fi
done

if [[ "${KERNEL_ARCH}" = "x86_64" ]]; then
  for flavour in ${KERNEL_FLAVOURS}; do
    # Reuse the same prepared tree: reset the config, then the flavour
    # fragment (microarch CFLAGS) over the xanmod fragment.
    if [[ -f "${SRCDIR}/../.config.pve-seed" ]]; then
      cp "${SRCDIR}/../.config.pve-seed" "${SRCDIR}/.config"
    fi
    for frag in x86-common.cfg "${flavour}.cfg"; do
      [[ -f "${KCFG_DIR}/${frag}" ]] && merge_config "${KCFG_DIR}/${frag}"
    done
    cd "${SRCDIR}"
    make -j"$(nproc)" deb-pkg
  done
else
  # ONE generic arm64 kernel, cross-compiled (the PVE arm64 defconfig comes
  # from the packaging when the sources carry one; arm64 defconfig is the
  # fallback).
  if [[ -f "${SRCDIR}/../.config.pve-seed" ]]; then
    cp "${SRCDIR}/../.config.pve-seed" "${SRCDIR}/.config"
  else
    make -C "${SRCDIR}" defconfig
  fi
  [[ -f "${KCFG_DIR}/xanmod.cfg" ]] && merge_config "${KCFG_DIR}/xanmod.cfg"
  [[ -f "${KCFG_DIR}/arm64-common.cfg" ]] && merge_config "${KCFG_DIR}/arm64-common.cfg"
  cd "${SRCDIR}"
  make -j"$(nproc)" deb-pkg
fi

cp /build/*.deb /out/
ls -la /out
