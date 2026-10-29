#!/bin/bash
#
# patch-defaults.sh - patch an extracted pve-cluster tree ($1) for variant A
#   (docs/compose-variant-a-plan.md): bootc = third guest type beside
#   qemu/lxc. Covers surfaces S1-S4 of the plan.
#
# Variant A is a DELIBERATELY INVASIVE core patch. It must never apply to a
# production tree before Gabriel's GO on the full plan: this script refuses
# to run (exit 8, not the drift exit 3) unless DC_VARIANT_A_GO=1. Setting
# the variable also implies wiring an entry in packages.yml (distinct +dcve
# suffix, see plan §Repack mechanics).
#
# Guarded like every house repack: an upstream refactor that moves an anchor
# SKIPS the package (exit 3 + CI summary + issue) rather than shipping
# unpatched or half-patched C code (which would be OS-breaking).
set -uo pipefail

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
#######################################
check_anchors() { :; }  # filled at implementation: S1-S4 grep anchors listed in the plan table

#######################################
# S1 - status.h/status.c: VMTYPE_BOOTC enum, vmtype_name(), dir mapping,
#      vmlist_register_vm()/vmlist_hash_insert_vm() guards, vmlist msg.
#      Anchor (status.c): vmtype == VMTYPE_QEMU || vmtype == VMTYPE_OPENVZ || vmtype == VMTYPE_LXC
#      Anchor (status.c): return "qemu-server"; // special case..
#      Anchor (status.h): VMTYPE enum block.
#######################################
patch_s1() { :; }

#######################################
# S2 - memdb.c: dir_contain_vm_config() gains bootc -> VMTYPE_BOOTC;
#      vmlist_add_dir() initial scan chain gains a VMTYPE_BOOTC branch.
#      Anchor (status.c): dir_contain_vm_config(...) mapping body
#      (the mapping lives with the VMTYPE dir special cases; grep both files).
#      Anchor (memdb.c): vmlist_add_dir(memdb, vmlist, node_te->name, VMTYPE_LXC, te)
#######################################
patch_s2() { :; }

#######################################
# S3 - create_pmxcfs_db.c/default layout + PVE/Cluster.pm gen_local_dirs():
#      nodes/<node>/bootc dir + top-level bootc symlink (mirrors lxc).
#      ANCHOR TO VERIFY AT GO on the installed tree - both the pmxcfs
#      layout builder and gen_local_dirs() must be grepped first (plan note).
#      Anchor (Cluster.pm): gen_local_dirs() mkdir loop.
#######################################
patch_s3() { :; }

#######################################
# S4 - PVE/Cluster.pm (perl): %file_info gains the bootc dir;
#      cfs_file_version() regex (openvz|lxc|qemu-server) extended;
#      check_vmid_unused() third-type wording. next_vmid/complete_* are
#      type-blind (no change).
#      Anchor (Cluster.pm): m!^nodes/[^/]+/(openvz|lxc|qemu-server)/(\d+)\.conf$!
#      Anchor (Cluster.pm): my $vmtypestr = $d->{type} eq 'qemu' ? 'VM' : 'CT';
#######################################
patch_s4() { :; }

#######################################
# Build checks: dpkg-buildpackage with C patches (pmxcfs smoke-run -f on a
# throwaway memdb), perl -c for the patched modules - see plan §Repack.
#######################################
check_build() { :; }

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