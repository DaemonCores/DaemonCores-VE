#!/bin/bash
#
# patch-defaults.sh - apply the DaemonCores VE default-VM-settings to an
# extracted qemu-server tree ($1). These make every API/CLI-created VM inherit
# the same optimum defaults as the patched GUI wizard: OVMF, q35 (via machine),
# x86-64-v2-AES CPU (migration-safe on heterogeneous hosts), guest agent on,
# writethrough disk cache, NIC firewall on, and an auto-provisioned EFI vars
# disk.
#
# Each patch is GUARDED: if an upstream refactor moved a patch anchor, the
# package is SKIPPED (exit 3) rather than shipped unpatched - shipping the bare
# upstream would silently drop these defaults and is treated as OS-breaking. On
# skip we surface the reason in the CI step summary (markdown) and open/append a
# GitHub issue (notification), WITHOUT failing the pipeline; the last-good
# +bootc build is retained until the anchor is fixed here.
set -uo pipefail

O="${1:?usage: patch-defaults.sh <extracted-qemu-server-dir>}"
P="$O/usr/share/perl5/PVE"

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
  title="⛔ qemu-server patch drift — re-anchor needed"
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
  echo "::error title=qemu-server VM-defaults patch drift::${reason}"
  {
    echo "### ⛔ qemu-server not rebuilt — patch drift"
    echo
    echo "**${reason}**"
    echo
    echo "An upstream refactor moved a patch anchor, so qemu-server was"
    echo "**skipped**. The last-good \`+bootc\` build is kept; the unpatched"
    echo "upstream is never shipped (it would drop the VM defaults)."
    echo "Re-anchor the patch in"
    echo "\`workflows/bootc-debs-builder/qemu-server/patch-defaults.sh\`."
  } >>"${GITHUB_STEP_SUMMARY:-/dev/stderr}"
  notify_issue "${reason}"
  exit 3
}

#######################################
# Default the VM BIOS to OVMF (UEFI) instead of SeaBIOS.
# Globals:
#   P
#######################################
patch_bios() {
  local f="${P}/QemuServer.pm"
  sed -i "s/default => 'seabios',/default => 'ovmf',/" "${f}"
  grep -qF "default => 'ovmf'," "${f}" \
    || skip_pkg "bios: default OVMF anchor changed (QemuServer.pm)"
}

#######################################
# Default the CPU type to x86-64-v2-AES (migration-safe on heterogeneous
# hosts), leaving reported-model at kvm64.
# Globals:
#   P
#######################################
patch_cpu() {
  local f="${P}/QemuServer/CPUConfig.pm" prog
  prog="s/default => 'kvm64',\n(\s*)default_key => 1,"
  prog+="/default => 'x86-64-v2-AES',\n\${1}default_key => 1,/"
  perl -0777 -pi -e "${prog}" "${f}"
  grep -qF "'x86-64-v2-AES'" "${f}" \
    || skip_pkg "cpu: default cputype anchor changed (CPUConfig.pm)"
}

#######################################
# Default the NIC firewall to on.
# Globals:
#   P
#######################################
patch_nic_firewall() {
  local f="${P}/QemuServer/Network.pm" prog
  prog="s/(firewall => \{\n\s*type => 'boolean',\n"
  prog+="\s*description => 'Whether this interface should be "
  prog+="protected by the firewall.',\n)(\s*optional => 1,)"
  prog+="/\${1}        default => 1,\n\${2}/"
  perl -0777 -pi -e "${prog}" "${f}"
  grep -A4 "firewall => {" "${f}" | grep -qF "default => 1," \
    || skip_pkg "net: firewall default anchor changed (Network.pm)"
}

#######################################
# Default the disk cache mode to writethrough (safety over raw speed).
# Globals:
#   P
#######################################
patch_disk_cache() {
  local f="${P}/QemuServer/Drive.pm" prog
  prog="s/(cache => \{\n\s*type => 'string',\n"
  prog+="\s*enum => \[qw\(none writethrough writeback "
  prog+="unsafe directsync\)\],\n"
  prog+="\s*description => \"The drive's cache mode\",\n)"
  prog+="(\s*optional => 1,)"
  prog+="/\${1}        default => 'writethrough',\n\${2}/"
  perl -0777 -pi -e "${prog}" "${f}"
  grep -A4 "cache => {" "${f}" | grep -qF "default => 'writethrough'," \
    || skip_pkg "cache: writethrough default anchor changed (Drive.pm)"
}

#######################################
# Enable the QEMU guest agent by default.
# Globals:
#   P
#######################################
patch_agent() {
  local f="${P}/QemuServer/Agent.pm" prog
  prog="s/default => 0,\n(\s*)default_key => 1,"
  prog+="/default => 1,\n\${1}default_key => 1,/"
  perl -0777 -pi -e "${prog}" "${f}"
  grep -B2 "default_key => 1," "${f}" | grep -qF "default => 1," \
    || skip_pkg "agent: enable-by-default anchor changed (Agent.pm)"
}

#######################################
# OVMF is now the default BIOS, so auto-provision an EFI vars disk for CLI/API
# creates (the GUI wizard already does this), reusing the standard efidisk0
# handling in create_disks.
# Globals:
#   P
#######################################
patch_efidisk() {
  local f="${P}/API2/Qemu.pm" prog snippet
  prog="s/(my \\\$conf = \\\$param;\n"
  prog+="\s*my \\\$arch = "
  prog+="PVE::QemuServer::Helpers::get_vm_arch\(\\\$conf\);\n)"
  prog+="/\${1}\n"
  prog+="                # DaemonCores: OVMF is the default BIOS; "
  prog+="auto-provision an EFI\n"
  prog+="                # vars disk so CLI\/API creates persist "
  prog+="EFI state like the GUI.\n"
  prog+="                if ((\\\$param->{bios} \/\/ 'ovmf') eq "
  prog+="'ovmf' \&\& !\\\$param->{efidisk0} \&\& \\\$storage) {\n"
  prog+="                    \\\$param->{efidisk0} = "
  prog+="\"\\\$storage:1,efitype=4m\";\n"
  prog+="                }\n/"
  perl -0777 -pi -e "${prog}" "${f}"
  grep -qF "auto-provision an EFI" "${f}" \
    || skip_pkg "efidisk: auto-provision anchor changed (API2/Qemu.pm)"
  # Dependency-free syntax check of the injected snippet.
  snippet="sub _t { my (\$param, \$storage) = @_;"
  snippet+=" if ((\$param->{bios} // 'ovmf') eq 'ovmf'"
  snippet+=" && !\$param->{efidisk0} && \$storage) {"
  snippet+=" \$param->{efidisk0} = \"\$storage:1,efitype=4m\"; } }"
  perl -ce "${snippet}" >/dev/null 2>&1 \
    || skip_pkg "efidisk: injected snippet failed perl -c"
}

#######################################
# Default the machine type to q35 instead of pc (i440fx).
# Globals:
#   P
#######################################
patch_machine() {
  local f="${P}/QemuServer/Machine.pm"
  sed -i "s/x86_64 => 'pc',/x86_64 => 'q35',/" "${f}"
  grep -qF "x86_64 => 'q35'," "${f}" \
    || skip_pkg "machine: default q35 anchor changed (Machine.pm)"
}

#######################################
# Apply every VM-defaults patch in order.
#######################################
main() {
  patch_bios
  patch_cpu
  patch_nic_firewall
  patch_disk_cache
  patch_agent
  patch_efidisk
  patch_machine
  echo "qemu-server VM-defaults: all patches applied."
}

main "$@"
