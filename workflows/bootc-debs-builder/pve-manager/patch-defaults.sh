#!/bin/bash
#
# patch-defaults.sh - patch an extracted pve-manager tree ($1):
#   - suppress the "No valid subscription" web UI popup (Subscription.pm)
#   - set the GUI create-wizard VM defaults (guest agent on, OVMF, q35) so the
#     wizard shows AND sends the same optimum defaults as the qemu-server
#     backend.
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
# Apply the subscription and GUI VM-defaults patches in order.
#######################################
main() {
  patch_subscription
  patch_gui_agent
  patch_gui_bios
  patch_gui_machine
  check_js
  echo "pve-manager: subscription + GUI VM-defaults patches applied."
}

main "$@"
