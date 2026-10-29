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
  # Series directory: active series live at linux-<maj>.y-xanmod, archived
  # (EOL) series under eol/ (e.g. the 7.0.x tree of the PVE packaging).
  case "${series}" in
    7.0) series_dir="eol/linux-7.0.y-xanmod";;
    *)   series_dir="linux-${series}.y-xanmod";;
  esac

  local dir
  dir=$(mktemp -d)
  # One name+url per manifest entry. The manifest is read with yq for the
  # stage filter only; the {seriesdir}/{topic} placeholders are resolved in
  # bash afterwards because the yq builds across distributions do not share
  # a feature set (strenv() is not available everywhere).
  local name url topic count=0
  while read -r name url topic; do
    [[ -n "${name}" && -n "${url}" ]] || continue
    url="${url//\{seriesdir\}/${series_dir}}"
    url="${url//\{topic\}/${topic}}"
    curl --retry 3 -fsSL "${url}" -o "${dir}/${count}.patch" \
      || { echo "ERROR: cannot download patch ${name}: ${url}" >&2; return 1; }
    count=$((count + 1))
  done < <(yq -r '.patches[] | select(.stage == "'"${stage}"'") | .name + " " + .url + " " + (.topic // "")' \
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