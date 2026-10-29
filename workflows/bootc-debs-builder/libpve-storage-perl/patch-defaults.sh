#!/bin/bash
#
# patch-defaults.sh - patch an extracted libpve-storage-perl tree ($1):
#   - mount every zpool created through the Proxmox API/GUI under /mnt/<pool>.
#     On a bootc image / is a read-only OSTree root, so the upstream default
#     root-level mountpoint (/pool) is unusable and breaks zspool storages for
#     images/rootdir volumes and their snapshot/clone/backup lifecycle.
#     (Upstream Proxmox 8.0+ moved PVE::API2::Disks::ZFS out of pve-manager,
#     so the create path lives here, NOT in pve-manager.)
#   - align the ZFSPoolPlugin path() fallback mountpoint (used when the pool
#     carries no explicit mountpoint) with /mnt so it can never resolve onto
#     the read-only root either.
#
# Guarded exactly like the pve-manager/qemu-server repacks: if an upstream
# refactor moved a patch anchor, the package is SKIPPED (exit 3) rather than
# shipped unpatched (which would drop the patches and is treated as
# OS-breaking). On skip the reason is surfaced in the CI step summary
# (markdown) and an open/append GitHub issue (notification), WITHOUT failing
# the pipeline; the last-good +bootc build stays.
set -uo pipefail

O="${1:?usage: patch-defaults.sh <extracted-libpve-storage-perl-dir>}"
P="$O/usr/share/perl5/PVE"
ZFS="$P/API2/Disks/ZFS.pm"
POOL="$P/Storage/ZFSPoolPlugin.pm"

#######################################
# Open or update the drift-tracking GitHub issue (best effort, never fatal).
# Globals:
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID
# Arguments:
#   $1 - drift reason included in the issue body.
#######################################
notify_issue() {
  local reason="$1" title num
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || return 0
  title="⛔ libpve-storage-perl patch drift — re-anchor needed"
  num=$(gh issue list --repo "${GITHUB_REPOSITORY}" --state open \
    --search "in:title \\\"${title}\\\"" --json number -q '.[0].number' \
    2>/dev/null || true)
  if [[ -n "${num}" ]]; then
    gh issue comment "${num}" --repo "${GITHUB_REPOSITORY}" \
      --body "Run \`${GITHUB_RUN_ID:-?}\`: ${reason}" 2>/dev/null || true
  else
    gh issue create --repo "${GITHUB_REPOSITORY}" --title "${title}" \
      --body "${reason} (run \`${GITHUB_RUN_ID:-?}\`)" 2>/dev/null || true
  fi
}

#######################################
# Skip the package build without shipping unpatched upstream. Emits a CI error
# annotation, appends a markdown report to the step summary, and notifies via a
# GitHub issue. Does NOT fail the job: the last-good +bootc build is retained.
# Globals:
#   GITHUB_STEP_SUMMARY
# Arguments:
#   $1 - human-readable drift reason.
# Returns:
#   Exits 3 so the caller skips the deb build.
#######################################
skip_pkg() {
  local reason="$1"
  echo "::error title=libpve-storage-perl patch drift::${reason}"
  {
    echo "### ⛔ libpve-storage-perl not rebuilt — patch drift"
    echo
    echo "**${reason}**"
    echo
    echo "An upstream refactor moved a patch anchor, so libpve-storage-perl was"
    echo "**skipped**. The last-good \`+bootc\` build is kept; the unpatched"
    echo "upstream is never shipped. Re-anchor the patch in"
    echo "\`workflows/bootc-debs-builder/libpve-storage-perl/patch-defaults.sh\`."
  } >>"${GITHUB_STEP_SUMMARY:-/dev/stderr}"
  notify_issue "${reason}"
  exit 3
}

#######################################
# Pool creation (API/GUI "Create: ZFS" dialog): insert -m /mnt/<pool> before
# the pool name in the zpool create command. Options must precede the pool
# name (that is how zpool create parses them).
# Globals:
#   ZFS
#######################################
patch_zpool_mountpoint() {
  # Anchors deliberately avoid embedded single quotes: 'ashift=$ashift",
  # $name];' identifies the create command uniquely without quoting gymnastics.
  grep -qF '"ashift=$ashift", $name];' "${ZFS}" \
    || skip_pkg "zpool create anchor not found (API2/Disks/ZFS.pm changed)"
  sed -i \
    's@my $cmd = \[$ZPOOL, '"'"'create'"'"', '"'"'-o'"'"', "ashift=$ashift", $name\];@my $cmd = [$ZPOOL, '"'"'create'"'"', '"'"'-o'"'"', "ashift=$ashift", '"'"'-m'"'"', "/mnt/$name", $name];@' \
    "${ZFS}"
  grep -qF '"/mnt/$name", $name];' "${ZFS}" \
    || skip_pkg "zpool create -m patch did not apply (API2/Disks/ZFS.pm)"
}

#######################################
# ZFSPoolPlugin path() fallback: when a pool carries no mountpoint property
# (mountpoint=none/legacy or an externally imported pool), path() must not
# resolve volumes onto the read-only bootc root.
# Globals:
#   POOL
#######################################
patch_path_fallback() {
  grep -qF 'my $mountpoint = $scfg->{mountpoint} // "/$scfg->{pool}";' \
    "${POOL}" \
    || skip_pkg "path() fallback anchor not found (Storage/ZFSPoolPlugin.pm changed)"
  sed -i 's@// "/$scfg->{pool}";@// "/mnt/$scfg->{pool}";@' "${POOL}"
  grep -qF 'my $mountpoint = $scfg->{mountpoint} // "/mnt/$scfg->{pool}";' \
    "${POOL}" \
    || skip_pkg "path() fallback patch did not apply (Storage/ZFSPoolPlugin.pm)"
}

#######################################
# Compile-check the two patched modules. The package is only extracted here,
# not installed, so add its own tree to @INC to resolve the sibling PVE::
# modules it ships (Diskmanage, Storage). The remaining runtime deps
# (libpve-common-perl and friends) are apt-installed by the packages.yml
# build step before this script runs.
# Globals:
#   ZFS, POOL
#######################################
check_perl() {
  PERL5INC="$(dirname "$(dirname "$ZFS")")"
  perl -I "${PERL5INC}" -c "${ZFS}" >/dev/null 2>&1 \
    || skip_pkg "API2/Disks/ZFS.pm fails perl -c after patching"
  perl -I "${PERL5INC}" -c "${POOL}" >/dev/null 2>&1 \
    || skip_pkg "Storage/ZFSPoolPlugin.pm fails perl -c after patching"
}

#######################################
# Apply the ZFS mountpoint patches in order.
#######################################
main() {
  patch_zpool_mountpoint
  patch_path_fallback
  check_perl
  echo "libpve-storage-perl: ZFS mountpoint patches applied."
}

main "$@"