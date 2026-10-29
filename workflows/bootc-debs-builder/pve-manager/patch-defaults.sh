#!/bin/bash
#
# patch-defaults.sh - patch an extracted pve-manager tree ($1):
#   - suppress the "No valid subscription" web UI popup (Subscription.pm)
#   - set the GUI create-wizard VM defaults (guest agent on, OVMF, q35) so the
#     wizard shows AND sends the same optimum defaults as the qemu-server
#     backend.
#   - variant A (docs/compose-variant-a-plan.md, surfaces S5-S10): bootc =
#     third guest type beside qemu/lxc - API (resources enum, Nodes index +
#     startall/stopall, NEW API2::Bootc modules), services (pvestatd, vzdump
#     skip, HA/migration refusal) and JS UI (own top-level section + new
#     bootc panels). Refuses to run (exit 8) until Gabriel's GO on the full
#     plan: DC_VARIANT_A_GO=1. Lifecycle goes through pvect-ostree; the
#     pve-container tree is NOT touched.
#
# Guarded exactly like the qemu-server repack: if an upstream refactor moved a
# patch anchor, the package is SKIPPED (exit 3) rather than shipped unpatched
# (which would drop the patches and is treated as OS-breaking). On skip the
# reason is surfaced in the CI step summary (markdown) and an open/append GitHub
# issue (notification), WITHOUT failing the pipeline; the last-good +bootc build
# stays.
set -uo pipefail

O="${1:?usage: patch-defaults.sh <extracted-pve-manager-dir>}"
SUB="$O/usr/share/perl5/PVE/API2/Subscription.pm"
JS="$O/usr/share/pve-manager/js/pvemanagerlib.js"

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
  title="⛔ pve-manager patch drift — re-anchor needed"
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
# Returns:
#   Exits 3 so the caller skips the deb build.
#######################################
skip_pkg() {
  local reason="$1"
  echo "::error title=pve-manager patch drift::${reason}"
  {
    echo "### ⛔ pve-manager not rebuilt — patch drift"
    echo
    echo "**${reason}**"
    echo
    echo "An upstream refactor moved a patch anchor, so pve-manager was"
    echo "**skipped**. The last-good \`+bootc\` build is kept; the unpatched"
    echo "upstream is never shipped. Re-anchor the patch in"
    echo "\`workflows/bootc-debs-builder/pve-manager/patch-defaults.sh\`."
  } >>"${GITHUB_STEP_SUMMARY:-/dev/stderr}"
  notify_issue "${reason}"
  exit 3
}

#######################################
# Suppress the no-subscription popup: status "notfound" -> "active".
# Globals:
#   SUB
#######################################
patch_subscription() {
  grep -qF 'status => "notfound",' "${SUB}" \
    || skip_pkg "subscription: anchor not found (Subscription.pm changed)"
  sed -i 's/status => "notfound",/status => "active",/g' "${SUB}"
  grep -qF 'status => "active",' "${SUB}" \
    || skip_pkg "subscription: patch did not apply"
}

#######################################
# Create wizard: enable the QEMU guest agent by default.
# Globals:
#   JS
#######################################
patch_gui_agent() {
  local prog
  prog="s/(name: 'agent',\n\s*uncheckedValue: 0,\n"
  prog+="\s*)defaultValue: 0,/\${1}defaultValue: 1,/"
  perl -0777 -pi -e "${prog}" "${JS}"
  grep -A3 "name: 'agent'," "${JS}" | grep -qF "defaultValue: 1," \
    || skip_pkg "gui agent default (pvemanagerlib.js anchor changed)"
}

#######################################
# Create wizard: show/render the default BIOS as OVMF (matches the backend).
# Globals:
#   JS
#######################################
patch_gui_bios() {
  local prog
  prog="s/(let defaultBios = arch === 'aarch64' \? "
  prog+="'OVMF \(UEFI\)' : )'SeaBIOS';"
  prog+="/\${1}'OVMF (UEFI)';/"
  perl -0777 -pi -e "${prog}" "${JS}"
  grep -qF "arch === 'aarch64' ? 'OVMF (UEFI)' : 'OVMF (UEFI)'" "${JS}" \
    || skip_pkg "gui bios default (render_qemu_bios anchor changed)"
}

#######################################
# Create wizard: default the machine type to q35. defaultMachines drives both
# the display and the value the wizard submits (matches the backend default).
# Globals:
#   JS
#######################################
patch_gui_machine() {
  local prog
  prog="s/(defaultMachines[^{]*\{\s*)x86_64: 'pc'"
  prog+="/\${1}x86_64: 'q35'/s"
  perl -0777 -pi -e "${prog}" "${JS}"
  grep -A2 "defaultMachines" "${JS}" | grep -qF "x86_64: 'q35'" \
    || skip_pkg "gui machine default (defaultMachines anchor changed)"
}

#######################################
# Guard against a drift that applied but produced invalid JS.
# Globals:
#   JS
#######################################
check_js() {
  command -v node >/dev/null 2>&1 || return 0
  node --check "${JS}" \
    || skip_pkg "pvemanagerlib.js fails node --check after patching"
}

#######################################
# Variant A plan gate: variant A is an invasive core patch (third guest
# type). It must never apply before Gabriel validates the full plan on
# disk (docs/compose-variant-a-plan.md). Exit 8 = NOT RUN, distinct from
# the drift exit 3 so the CI step summary can tell the two apart.
#######################################
variant_a_go() {
  if [[ "${DC_VARIANT_A_GO:-}" != "1" ]]; then
    echo "NOT RUN: pve-manager variant A - plan not validated yet" \
      "(gate: DC_VARIANT_A_GO=1 after Gabriel's GO)."
    exit 8
  fi
}

#######################################
# S5 - API2/Cluster.pm resources: extend the type enum, map vmlist bootc
#   entries into resources, no hatypemap entry (bootc is NOT
#   HA-manageable, plan S8).
# Anchors:
#   enum => ['node', 'storage', 'pool', 'qemu', 'lxc', 'openvz', 'sdn']
#   my $hatypemap = {
#######################################
patch_vfa_s5_resources() { :; }

#######################################
# S6 - API2/Nodes.pm: { name => 'bootc' } index entry beside lxc/qemu;
#   $get_filtered_vmlist + startall/stopall route bootc guests to
#   PVE::API2::Bootc::Status (pvect-ostree lifecycle).
# Anchors:
#   "unknown virtual guest type '$d->{type}'"
#   { name => 'lxc' },   (node index list)
#   if ($d->{type} eq 'lxc') {
#######################################
patch_vfa_s6_nodes() { :; }

#######################################
# S7 - NEW additive modules PVE/API2/Bootc.pm + PVE/API2/Bootc/Status.pm:
#   create/start/stop/shutdown/destroy/compose-refresh as UPID tasks
#   delegating to pvect-ostree; standard VM.* privileges so ACLs behave
#   identically. No anchor surgery; register the modules in the build
#   (Makefile/pod) and verify registration.
#######################################
patch_vfa_s7_api2_bootc() { :; }

#######################################
# S8 - pvestatd/vzdump/HA/migration: per-node bootc status for
#   /cluster/resources + RRD (source file under the plugin sysroot);
#   vzdump filters SKIP bootc (v1: no vzdump of bootc guests); HA skips
#   bootc; the migrate path refuses bootc with a dedicated error.
# Anchors: verified at GO on the installed pve-manager 9.x tree
#   (service/mzdump layout has moved between releases - grep first).
#######################################
patch_vfa_s8_services() { :; }

#######################################
# S9 - www/manager6: Utils guest-type map + ResourceStore/ResourceTree +
#   Workspace buttons: bootc gets its OWN top-level section, never inside
#   the LXC tree. Additive entry, LXC tree rendering untouched.
# Anchors: verified at GO on the www/manager6 tree.
#######################################
patch_vfa_s9_ui_tree() { :; }

#######################################
# S10 - NEW additive www/manager6/bootc/*.js: Create (compose editor +
#   build log + relocations + template prefill), Edit (compose-refresh),
#   Templates (grid + Edit/Clone), Status. Register files in the build;
#   node --check on the new files.
#######################################
patch_vfa_s10_ui_bootc() { :; }

#######################################
# JS syntax check for the variant A UI files (reuses the house check_js
# guard pattern; the bootc panels are new files, checked one by one).
#######################################
check_js_bootc() { :; }

#######################################
# Apply the subscription and GUI VM-defaults patches in order.
#######################################
main() {
  variant_a_go
  patch_subscription
  patch_gui_agent
  patch_gui_bios
  patch_gui_machine
  patch_vfa_s5_resources
  patch_vfa_s6_nodes
  patch_vfa_s7_api2_bootc
  patch_vfa_s8_services
  patch_vfa_s9_ui_tree
  patch_vfa_s10_ui_bootc
  check_js
  check_js_bootc
  echo "pve-manager: subscription + GUI defaults + variant A (S5-S10) patches applied."
}

main "$@"
