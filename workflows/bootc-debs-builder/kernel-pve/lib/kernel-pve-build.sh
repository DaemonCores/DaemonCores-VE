#!/usr/bin/env bash
# Build script run INSIDE a debian:trixie container by the kernel-pve
# reusable workflow (DaemonCores-CI/.github/workflows/kernel-pve.yml).
#
# Recipe (docs/kernel-nvidia-pve-host-plan.md §2, transverse variants):
#   1. enable the Proxmox trixie repo, resolve the PVE packaging and fetch
#      its kernel tree (the pve repo publishes no source index: the tree is
#      the mirror_ubuntu-kernels submodule of git.proxmox.com/git/pve-kernel.git);
#   2. seed the config from the tree with the PVE packaging config deltas;
#   3. apply the XanMod patch set (lib in the manifest repo, dry-run all
#      first);
#   4. ONE patched tree; every amd64 flavour in KERNEL_FLAVOURS (x64v1,
#      x64v3 — x64v2 optional on request) is a config-fragment change plus a
#      repackage pass over that same tree: no N full kernel builds. arm64 is
#      ONE cross-compiled build.
#   5. debs land in $KERNEL_OUT as artifacts, never auto-installed.
#
# Env read: KERNEL_SERIES, KERNEL_VERSION (resolved from the Proxmox apt
#   repo when empty), KERNEL_ARCH_LEVEL (flavour: x64v1, x64v2, x64v3, arm64
#   — becomes the single KERNEL_FLAVOURS entry; the deb-lane kernel-pve
#   entries of packages.yml carry it), KERNEL_FLAVOURS (multi-flavour
#   override), KERNEL_ARCH (x86_64 | arm64), KERNEL_GPU (space-separated GPU
#   config sets merged from kconfig/gpu/, "all" = every fragment of that
#   directory; default "all" — ONE optimised build carries every vendor
#   transversely), SRC_ROOT (checkout of the manifest repo; default /src —
#   the reusable workflow mounts it there, the deb-lane build passes the
#   repo root), KERNEL_OUT (output dir for the debs; default /debs — the
#   deb builder's standard output, the pipeline publishes it to the APT
#   repo like any other package).
set -euo pipefail

KERNEL_SERIES="${KERNEL_SERIES:?}"
KERNEL_VERSION="${KERNEL_VERSION:-}"
KERNEL_ARCH="${KERNEL_ARCH:?x86_64|arm64}"
# One flavour per deb-lane variant (KERNEL_ARCH_LEVEL from packages.yml);
# the reusable workflow keeps the transverse multi-flavour override.
KERNEL_FLAVOURS="${KERNEL_FLAVOURS:-${KERNEL_ARCH_LEVEL:-x64v1 x64v3}}"
SRC_ROOT="${SRC_ROOT:-/src}"
KERNEL_OUT="${KERNEL_OUT:-/out}"

export DEBIAN_FRONTEND=noninteractive
export ARCH="${KERNEL_ARCH}"

echo "deb [arch=amd64] https://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  > /etc/apt/sources.list.d/pve.list
echo "deb-src [arch=amd64] https://download.proxmox.com/debian/pve trixie pve-no-subscription" \
  >> /etc/apt/sources.list.d/pve.list
# The CDN serving download.proxmox.com (fr.cdn.proxmox.com) presents a cert
# without the download. hostname SNI, so the https fetch fails on some
# networks. The repo is used over plain http anyway; a pre-mounted keyring
# is the supported fallback (host /usr/share/keyrings/proxmox-archive-keyring.gpg).
curl -fsSL https://download.proxmox.com/debian/proxmox-release-trixie.gpg \
  -o /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg \
  || { [[ -s /etc/apt/trusted.gpg.d/proxmox-release-trixie.gpg ]] \
    && echo "WARN: key fetch failed (CDN SNI), using pre-mounted keyring" \
    || { echo "ERROR: no proxmox repo key available" >&2; exit 1; }; }

apt-get update
# Deb-lane callers resolve nothing in advance: the version is read from the
# repo itself (the same query the retired reusable workflow ran as a step).
[[ -n "${KERNEL_VERSION}" ]] || \
  KERNEL_VERSION=$(apt-cache policy proxmox-kernel-7.0 | sed -n 2p | awk '{print $2}')
[[ -n "${KERNEL_VERSION}" ]] || { \
  echo "ERROR: cannot resolve the PVE kernel version" >&2; exit 1; }
echo "PVE kernel packaging version: ${KERNEL_VERSION}"
apt-get install -y --no-install-recommends \
  build-essential dpkg-dev devscripts curl git yq patch \
  bc bison flex libncurses-dev libssl-dev libelf-dev rsync kmod python3 \
  fakeroot ca-certificates
[[ "${KERNEL_ARCH}" = "arm64" ]] && \
  apt-get install -y --no-install-recommends crossbuild-essential-arm64 gcc-aarch64-linux-gnu

mkdir -p "${KERNEL_OUT}" /build
cd /build

# The pve-no-subscription repo carries NO source/Sources index (verified:
# dists/trixie/pve-no-subscription is binaries only), so `apt-get source`
# can never resolve. The packaging's kernel tree is the git submodule
# `submodules/ubuntu-kernel` of git.proxmox.com/git/pve-kernel.git; master
# tracks the published packaging (7.0.14-26 for the current release).
KERNEL_MAJMIN=$(echo "${KERNEL_VERSION}" | cut -d. -f1,2)
[[ -d /build/pkg-src ]] || git clone --depth 1 --recurse-submodules --shallow-submodules \
  https://git.proxmox.com/git/pve-kernel.git /build/pkg-src
PKG_VER=$(sed -n 's/^proxmox-kernel-.* (\([^ )]*\)).*/\1/p' /build/pkg-src/debian/changelog | head -1)
[[ "${PKG_VER}" == "${KERNEL_VERSION}-"* ]] || \
  echo "WARN: packaging master is ${PKG_VER}, requested kernel version ${KERNEL_VERSION}"
SRCDIR=/build/linux-${KERNEL_VERSION}
[[ -e "${SRCDIR}" ]] || cp -a /build/pkg-src/submodules/ubuntu-kernel "${SRCDIR}"
# Keep the git worktree linkage: `make deb-pkg` builds the source package
# with check-git and refuses to run outside a git repository (first real
# run: "creating source package requires git repository"). The pointer is
# made absolute because the tree is copied out of pkg-src; the XanMod
# setlocalversion patch (0017) drops the git tag suffix, so the release
# stays 7.0.14-<LOCALVERSION>.
if [[ -f "${SRCDIR}/.git" ]]; then
  gd=$(sed 's/^gitdir: *//' "${SRCDIR}/.git")
  # The relative pointer was written for the ORIGINAL location
  # (pkg-src/submodules/ubuntu-kernel, base /build/pkg-src): ../../.git
  # from there is pkg-src/.git. Map it to its absolute spot; the module
  # git dir travels with pkg-src, the worktree stays the copied tree.
  [[ "${gd:0:1}" == "/" ]] || gd="/build/pkg-src/${gd#../../}"
  if [[ -d "${gd}" ]]; then
    echo "gitdir: ${gd}" > "${SRCDIR}/.git"
    # The module config carries core.worktree pointing at the original
    # location (check-git needs `rev-parse --show-cdup` empty from the
    # tree top): repoint it at the copied tree.
    git --git-dir="${gd}" config core.worktree "${SRCDIR}"
    git -C "${SRCDIR}" rev-parse --git-dir >/dev/null 2>&1 \
      || rm -f "${SRCDIR}/.git"   # give up quietly; deb-pkg would fail below with the real error
  else
    rm -f "${SRCDIR}/.git"
  fi
fi

# Config seed priority: a pre-mounted /build/.config.pve-seed (captured from
# the host: /boot/config-<kernel> of the running PVE kernel — the tree's
# Ubuntu base carries no assembled .config) wins; otherwise the tree base
# .config + the PVE packaging deltas; otherwise defconfig.
KERNEL_CFG_ORG=$(cat /build/pkg-src/debian/rules.d/config-common.opts \
  /build/pkg-src/debian/rules.d/config-amd64.opts 2>/dev/null || true)
if [[ ! -f /build/.config.pve-seed ]]; then
  if [[ -f "${SRCDIR}/.config" ]]; then
    cp "${SRCDIR}/.config" /build/.config.pve-seed
    "${SRCDIR}/scripts/config" --file /build/.config.pve-seed ${KERNEL_CFG_ORG} \
      && echo "seed config: ubuntu base + PVE packaging deltas"
  else
    echo "WARN: no seed and no base .config in the tree; build starts from defconfig"
  fi
else
  echo "seed config: pre-mounted host config"
fi

# Patch once on the shared tree (dry-run the entire set before any touch).
. "${SRC_ROOT}/workflows/bootc-debs-builder/kernel-pve/lib/kernel-pve-patches.sh"
pve_kernel_apply_patches \
  "${SRC_ROOT}/workflows/bootc-debs-builder/kernel-pve/patches.yml" \
  common "${KERNEL_VERSION}" "${SRCDIR}"

KCFG_DIR="${SRC_ROOT}/workflows/bootc-debs-builder/kernel-pve/kconfig"
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
    case "${flavour}" in
      x64v2) FLAVOUR_KCFLAGS="-march=x86-64-v2";;
      x64v3) FLAVOUR_KCFLAGS="-march=x86-64-v3";;
      x64v4) FLAVOUR_KCFLAGS="-march=x86-64-v4";;
      *)     FLAVOUR_KCFLAGS="";;
    esac
    cd "${SRCDIR}"
    build_cmd=(make -j"$(nproc)")
    [[ -n "${FLAVOUR_KCFLAGS}" ]] && build_cmd+=(KCFLAGS="${FLAVOUR_KCFLAGS}")
    "${build_cmd[@]}" deb-pkg
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

cp /build/*.deb "${KERNEL_OUT}/"
ls -la "${KERNEL_OUT}"
