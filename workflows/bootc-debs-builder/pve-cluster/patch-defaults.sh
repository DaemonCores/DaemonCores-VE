#!/bin/bash
#
# patch-defaults.sh - patch a pve-cluster SOURCE tree ($1) for variant A
#   (docs/compose-variant-a-plan.md): bootc = third guest type beside
#   qemu/lxc. Covers surfaces S1-S4. Unlike the deb-file-copy lanes
#   (libpve-storage-perl), pmxcfs is compiled C: the S1-S3 anchors live in
#   `src/pmxcfs/*.c`, which the published deb does NOT ship. The script
#   therefore expects the upstream git source tree (checkout at the version
#   the builder downloaded, done by packages.yml), patches it and the
#   check_build() step compiles it (dpkg-buildpackage; pmxcfs smoke run).
#
# Variant A is a DELIBERATELY INVASIVE core patch. It refuses to run (exit 8,
# not the drift exit 3) unless DC_VARIANT_A_GO=1 is exported.
#
# Guarded like every house repack: an upstream refactor that moves an anchor
# SKIPS the package (exit 3 + CI summary + issue) rather than shipping
# unpatched or half-patched C code (which would be OS-breaking).
set -uo pipefail

T="${1:?usage: patch-defaults.sh <pve-cluster-source-tree>}"
S="$T/src/pmxcfs"

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
  title="⛔ pve-cluster patch drift — re-anchor needed"
  num=$(gh issue list --repo "${GITHUB_REPOSITORY}" --state open \
    --search "in:title \"${title}\"" --json number -q '.[0].number' \
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
#######################################
skip_pkg() {
  local reason="$1"
  echo "::error title=pve-cluster patch drift::${reason}"
  {
    echo "### ⛔ pve-cluster not rebuilt — patch drift"
    echo
    echo "**${reason}**"
    echo
    echo "An upstream refactor moved a variant A anchor, so pve-cluster was"
    echo "**skipped** (both \`pve-cluster\` and \`libpve-cluster-perl\`). The"
    echo "last-good \`+dcve\` build is kept; the unpatched upstream is never"
    echo "shipped. Re-anchor:"
    echo "\`workflows/bootc-debs-builder/pve-cluster/patch-defaults.sh\`."
  } >>"${GITHUB_STEP_SUMMARY:-/dev/stderr}"
  notify_issue "${reason}"
  exit 3
}

anchor() {
  grep -qF -- "$2" "$1" || skip_pkg "variant A anchor not found in $1: '$2'"
}

#######################################
# Plan gate: refuse until Gabriel validates the full variant A plan on disk.
#######################################
check_go() {
  if [[ "${DC_VARIANT_A_GO:-}" != "1" ]]; then
    echo "NOT RUN: pve-cluster variant A - plan not validated yet" \
      "(docs/compose-variant-a-plan.md; gate DC_VARIANT_A_GO=1 after GO)."
    exit 8
  fi
}

#######################################
# Anchors are checked BEFORE any edit. One miss = skip everything.
# Grounded on upstream pve-cluster master @ a749090 (9.1.8, 2026-10-27).
#######################################
check_anchors() {
  anchor "$S/status.h" '#define VMTYPE_LXC 3'
  anchor "$S/status.c" '"qemu-server"; // special case..'
  anchor "$S/status.c" '} else if (vminfo->vmtype == VMTYPE_LXC) {'
  anchor "$S/status.c" 'vmtype == VMTYPE_QEMU || vmtype == VMTYPE_OPENVZ || vmtype == VMTYPE_LXC'
  anchor "$S/memdb.c" 'strcmp(sa[1], "lxc") == 0'
  anchor "$S/memdb.c" 'vmlist_add_dir(memdb, vmlist, node_te->name, VMTYPE_LXC, te)'
  anchor "$S/pmxcfs.c" 'cfs_plug_link_new("lxc", lnktarget)'
  anchor "$T/src/PVE/Cluster/Setup.pm" '$pmxcfs_base_dir/nodes/$nodename/lxc'
  anchor "$T/src/PVE/Cluster.pm" "'/lxc/' => 1,"
  anchor "$T/src/PVE/Cluster.pm" "my \$vmtypestr = \$d->{type} eq 'qemu' ? 'VM' : 'CT';"
}

#######################################
# S1 - status.h/status.c: VMTYPE_BOOTC enum entry (4, after LXC), named
#      "bootc" by vminfo_type_to_string(). cfs_create_vmlist_msg() and
#      vminfo_type_to_path_type() are generic on that function, so the vmlist
#      message serialises `type: "bootc"` and conf paths land in
#      nodes/<node>/bootc/<vmid>.conf with no further change.
#######################################
patch_s1() {
  # status.h: enum entry (anchor already checked in check_anchors).
  sed -i 's/^#define VMTYPE_LXC 3$/#define VMTYPE_LXC 3\n#define VMTYPE_BOOTC 4/' "$S/status.h"
  grep -qF '#define VMTYPE_BOOTC 4' "$S/status.h" \
    || skip_pkg "status.h: VMTYPE_BOOTC not added (anchor matched but edit failed)"

  # status.c: vmtype_name() equivalent - the type string used by the vmlist
  # message and (via vminfo_type_to_path_type) the conf directory.
  perl -0pi -e 's/(\} else if \(vminfo->vmtype == VMTYPE_LXC\) \{\n        return "lxc";\n)/$1    } else if (vminfo->vmtype == VMTYPE_BOOTC) {\n        return "bootc";\n/' "$S/status.c"
  grep -qF 'return "bootc";' "$S/status.c" \
    || skip_pkg "status.c: bootc branch not added to vminfo_type_to_string"

  # Guards in vmlist_hash_insert_vm() + vmlist_register_vm() accept bootc.
  # Exactly the two sites above must carry the guard chain.
  local sites
  sites=$(grep -cF 'vmtype == VMTYPE_QEMU || vmtype == VMTYPE_OPENVZ || vmtype == VMTYPE_LXC' "$S/status.c")
  [[ "$sites" == "2" ]] || skip_pkg "status.c: guest guard chain found in $sites places, expected 2"
  sed -i 's/vmtype == VMTYPE_QEMU || vmtype == VMTYPE_OPENVZ || vmtype == VMTYPE_LXC/vmtype == VMTYPE_QEMU || vmtype == VMTYPE_OPENVZ || vmtype == VMTYPE_LXC || vmtype == VMTYPE_BOOTC/g' "$S/status.c"
  grep -cF 'VMTYPE_BOOTC' "$S/status.c" >/dev/null \
    || skip_pkg "status.c: guards not extended"
}

#######################################
# S2 - memdb.c: dir_contain_vm_config() maps nodes/<n>/bootc to VMTYPE_BOOTC
#      (create/rename/delete hooks dispatch on it - no other hook needed);
#      vmlist_add_dir() initial scan chain gains a bootc branch.
#######################################
patch_s2() {
  perl -0pi -e 's/(        \} else if \(strcmp\(sa\[1\], "lxc"\) == 0\) \{\n            \*vmtype_ret = VMTYPE_LXC;\n            nodename = g_strdup\(sa\[0\]\);\n        \})/$1 else if (strcmp(sa[1], "bootc") == 0) {\n            *vmtype_ret = VMTYPE_BOOTC;\n            nodename = g_strdup(sa[0]);\n        }/' "$S/memdb.c"
  grep -qF 'strcmp(sa[1], "bootc") == 0' "$S/memdb.c" \
    || skip_pkg "memdb.c: dir_contain_vm_config() bootc mapping not added"

  perl -0pi -e 's/(        if \(\(te = g_hash_table_lookup\(node_te->data\.entries, "lxc"\)\)\) \{\n            if \(!vmlist_add_dir\(memdb, vmlist, node_te->name, VMTYPE_LXC, te\)\) \{\n                ret = FALSE;\n            \}\n        \})/$1\n        if ((te = g_hash_table_lookup(node_te->data.entries, "bootc"))) {\n            if (!vmlist_add_dir(memdb, vmlist, node_te->name, VMTYPE_BOOTC, te)) {\n                ret = FALSE;\n            }\n        }/' "$S/memdb.c"
  grep -qF 'g_hash_table_lookup(node_te->data.entries, "bootc")' "$S/memdb.c" \
    || skip_pkg "memdb.c: vmlist_add_dir() bootc scan branch not added"
}

#######################################
# S3 - per-node conf dir + top-level link. The top-level symlink
#      "bootc -> nodes/<NODENAME>/bootc" is built by pmxcfs's
#      create_symlinks() (same place qemu-server/openvz/lxc links are);
#      gen_local_dirs() adds the mountable dir under /etc/pve.
#      create_pmxcfs_db.c only seeds top-level files for the installer -
#      nothing to patch there (verified against master).
#######################################
patch_s3() {
  perl -0pi -e 's/(    lnktarget = g_strdup_printf\("nodes\/\%s\/lxc", nodename\);\n    lnk = cfs_plug_link_new\("lxc", lnktarget\);\n    g_free\(lnktarget\);\n    cfs_plug_base_insert\(bplug, \(cfs_plug_t \*\)lnk\);\n)/$1\n    lnktarget = g_strdup_printf("nodes\/%s\/bootc", nodename);\n    lnk = cfs_plug_link_new("bootc", lnktarget);\n    g_free(lnktarget);\n    cfs_plug_base_insert(bplug, (cfs_plug_t *)lnk);/' "$S/pmxcfs.c"
  grep -qF 'cfs_plug_link_new("bootc", lnktarget)' "$S/pmxcfs.c" \
    || skip_pkg "pmxcfs.c: bootc top-level link not added to create_symlinks()"

  perl -0pi -e 's/(\n        "\$pmxcfs_base_dir\/nodes\/\$nodename\/lxc",)/$1\n        "\$pmxcfs_base_dir\/nodes\/\$nodename\/bootc",/' "$T/src/PVE/Cluster/Setup.pm"
  grep -qF '$pmxcfs_base_dir/nodes/$nodename/bootc' "$T/src/PVE/Cluster/Setup.pm" \
    || skip_pkg "Cluster/Setup.pm: bootc dir not added to gen_local_dirs()"
}

#######################################
# S4 - PVE/Cluster.pm (perl): the observed-file registry gains the bootc dir
#      and check_vmid_unused() handles a third type ("BT", not VM/CT).
#      DEVIATION from the plan note: cfs_file_version() regex is NOT
#      extended with bootc - routing bootc confs through $file_info would
#      die "unknown file type" (no parser/writer registered); the bootc conf
#      is read via the generic IPCC path instead. next_vmid()/complete_*()
#      stay vmlist-driven and type-blind (no change).
#######################################
patch_s4() {
  sed -i "s|    '/lxc/' => 1,|    '/lxc/' => 1,\n    '/bootc/' => 1,|" "$T/src/PVE/Cluster.pm"
  grep -qF "'/bootc/' => 1," "$T/src/PVE/Cluster.pm" \
    || skip_pkg "Cluster.pm: bootc dir not added to the observed registry"

  grep -qF "check_vmid_unused" "$T/src/PVE/Cluster.pm" \
    || skip_pkg "Cluster.pm: check_vmid_unused vanished"
  perl -0pi -e "s/my \\\$vmtypestr = \\\$d->\{type\} eq 'qemu' \? 'VM' : 'CT';/my \\\$vmtypestr = \\\$d->{type} eq 'qemu' \? 'VM' : (\\\$d->{type} eq 'bootc' \? 'BT' : 'CT');/" "$T/src/PVE/Cluster.pm"
  grep -qF "eq 'bootc' ? 'BT'" "$T/src/PVE/Cluster.pm" \
    || skip_pkg "Cluster.pm: check_vmid_unused() bootc wording not added"
  grep -qF "my \$vmtypestr = \$d->{type} eq 'qemu' ? 'VM' : 'CT';" "$T/src/PVE/Cluster.pm" \
    && skip_pkg "Cluster.pm: check_vmid_unused() binary VM/CT line still present" || true
}

#######################################
# Build checks (source lane): dpkg-buildpackage in the builder (needs the
# build-deps from debian/control, installed by packages.yml); perl syntax
# check of the patched Cluster.pm. See plan §Repack mechanics.
#######################################
check_build() {
  # perl -cw can fail on host trees for MISSING MODULES (environment issue,
  # not our edit) - only syntax failures in OUR files must skip the build.
  local out
  for pm in "$T/src/PVE/Cluster.pm" "$T/src/PVE/Cluster/Setup.pm"; do
    out=$(perl -cw "$pm" 2>&1) && continue
    if grep -qF "Can't locate" <<<"$out"; then
      echo "pve-cluster: $pm perl -cw skipped - missing module in this tree ($out)"
    else
      skip_pkg "$(basename "$pm") fails perl -cw after patching: $out"
    fi
  done
  # The C tree is compiled and smoke-run by packages.yml (dpkg-buildpackage +
  # pmxcfs -f on a throwaway memdb) - nothing to do here beyond the perl
  # checks above. A C syntax slip surfaces there, before any deb is published.
}

main() {
  check_go
  check_anchors
  patch_s1
  patch_s2
  patch_s3
  patch_s4
  check_build
  echo "pve-cluster: variant A surfaces S1-S4 patched."
}

main "$@"