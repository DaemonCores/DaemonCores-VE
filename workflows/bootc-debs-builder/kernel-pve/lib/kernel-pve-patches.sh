#!/usr/bin/env bash
# Shared XanMod patch application for the PVE kernel build, sourced by the
# kernel-pve reusable workflow in DaemonCores-CI. Ported from debian-bootc's
# workflows/bootc-debs-builder/lib/kernel-patches.sh (download, dry-run on
# the whole set, then apply in manifest order). Nothing is tolerated: a
# patch that cannot be downloaded or does not apply fails the build and the
# last good deb is kept.
#
# Globals read:
#   KERNEL_SERIES  kernel series, e.g. 7.3 (derived from the kernel version
#                  by the caller; a plain two-part version is its own series)
# Arguments:
#   $1 - manifest path (kernel-pve/patches.yml)
#   $2 - stage (common, amd64, arm64)
#   $3 - kernel version, e.g. 7.3.0
#   $4 - kernel source tree
#######################################

#######################################
# Download the patches of one stage, dry-run all of them, then apply them
# in manifest order. Exits non-zero when a download or a patch fails.
#######################################
pve_kernel_apply_patches() {
  local manifest="$1" stage="$2" version="$3" tree="$4"
  local series="${version%.*}"
  # 7.3.y series path from a 7.3.0 version; a plain two-part version is
  # its own series (nothing to strip).
  if [[ "${version}" != *.*.* ]]; then
    series="${version}"
  fi

  local dir
  dir=$(mktemp -d)
  # One name+url per manifest entry, with {series} and {topic} resolved by
  # yq itself (no sed round-tripped substitution).
  local count=0
  while IFS=' ' read -r name url; do
    [[ -n "${name}" && -n "${url}" ]] || continue
    curl --retry 3 -fsSL "${url}" -o "${dir}/${count}.patch" \
      || { echo "ERROR: cannot download patch ${name}: ${url}" >&2; return 1; }
    count=$((count + 1))
  done < <(SERIES="${series}" yq -r '
    .patches[] | select(.stage == strenv(STAGE))
      | . as $e | .name + " " +
        (.url | sub("{series}"; strenv(SERIES)) | sub("{topic}"; $e.topic))' \
      "${manifest}")
  ((count)) || return 0

  local i
  # Every patch must apply before any touch of the tree.
  for i in $(seq 0 $((count - 1))); do
    patch -d "${tree}" -p1 --no-backup-if-mismatch --dry-run \
      <"${dir}/${i}.patch" >/dev/null \
      || { echo "ERROR: patch ${i} does not apply to ${version}" >&2; return 1; }
  done
  for i in $(seq 0 $((count - 1))); do
    patch -d "${tree}" -p1 --no-backup-if-mismatch <"${dir}/${i}.patch" >/dev/null
    echo "applied patch ${i}"
  done
  rm -rf "${dir}"
}