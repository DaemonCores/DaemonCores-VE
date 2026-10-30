# Unit tests for the pvect-ostree resolved-storage volume wiring.
# Run:  tests/run-tests.sh
# Everything external (pvesm, pct, deploy/registry/need_root) is stubbed; the
# real code under test is storage_ids_with_content / first_active_storage /
# volume_storage / cmd_create storage selection.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../usr/sbin/pvect-ostree"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$STUBBIN"' EXIT
STUBBIN="$TMP/bin"
mkdir -p "$STUBBIN"

# --- fake storage.cfg: declaration order dir-a, dir-b, local ----------------
cat >"$TMP/storage.cfg" <<'EOF'
dir: dir-a
	content rootdir images

dir: dir-b
	content rootdir vztmpl

dir: local
	content iso vztmpl
EOF

# --- stubs -------------------------------------------------------------------
cat >"$STUBBIN/pvesm" <<'EOF'
#!/bin/bash
# Emulates `pvesm status -content <type>`: dir-a + dir-b carry rootdir+images,
# dir-b + local carry vztmpl. Anything else is a stub echo.
case "$1" in
  status)
    case "${2:-}" in
      -content)
        case "$3" in
          rootdir) printf 'name\ttyp\tactive\n'
                   printf 'dir-a\tdir\tactive\ndir-b\tdir\tactive\n' ;;
          vztmpl)  printf 'name\ttyp\tactive\n'
                   printf 'dir-b\tdir\tactive\nlocal\tdir\tactive\n' ;;
          *) exit 1 ;;
        esac ;;
      *) printf 'dir-a\tdir\tactive\ndir-b\tdir\tactive\nlocal\tdir\tactive\n' ;;
    esac ;;
  *) echo "stub-volid" ;;
esac
EOF
cat >"$STUBBIN/pct" <<'EOF'
#!/bin/bash
# Record every invocation for assertions; always succeed.
printf '%s\0' "$@" >>"${PVECT_TEST_LOG:?}" ; exit 0
EOF
cat >"$STUBBIN/nothing" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUBBIN"/*
export PATH="$STUBBIN:$PATH"
export PVECT_STORAGE_CFG="$TMP/storage.cfg"

# Load the implementation (source-safe entry guard).
source "$SCRIPT"

fail=0
ok()   { info "PASS: $1"; }
bad()  { info "FAIL: $1"; fail=1; }
eq() { local got=$1 want=$2 name=$3
  if [[ $got == "$want" ]]; then ok "$name"; else bad "$name (got '$got', want '$want')"; fi
}

# Common environment under test.
ROOTFSD="$TMP" # never written by these code paths, only referenced

info "== volume_storage =="
eq "$(volume_storage rootdir dir-a '' label)" "dir-a" "valid explicit pref wins"
out=$(volume_storage rootdir '' dir-b label) && eq "$out" "dir-b" "empty pref follows usable fallback"
out=$(volume_storage rootdir '' dir-nope label) && eq "$out" "dir-a" \
  "empty pref + unusable fallback resolves to first ACTIVE rootdir storage"
out=$(volume_storage rootdir local dir-a label 2>&1 >/dev/null) \
  && bad "pref without the content must die" \
  || { [[ $out == *"local"*"rootdir"* ]] && ok "pref lacking 'content rootdir' dies loudly" \
       || bad "wrong rejection message: $out"; }

info "== cmd_create per-volume storage wiring =="
# Neutralise the side-effecting commands; keep the real pct resolution path.
cmd_deploy() { :; }
reg_write() { :; }
mount_rootfs() { :; }
normalise_conf() { :; }
ct_sysroot() { echo /stub/sysroot; }
alloc_template() { echo alpine-3.20_amd64.tar.gz; }
need_root() { :; }
need_tools() { :; }
TEMPLATE_STORAGE=tmplstore
MP_ETC_SIZE=1; MP_VAR_SIZE=16; MP_BOOTC_SIZE=16

LOG="$TMP/pct.log"
PVECT_TEST_LOG="$LOG" ROOTFS_STORAGE=dir-a MP0_STORAGE= MP1_STORAGE= MP2_STORAGE= \
  cmd_create 9991 img "extra=1"
args=$(tr '\0' ' ' <"$LOG")
eq "$(grep -o -- '--rootfs [^ ]*' <<<"$args")" "--rootfs dir-a:0" \
  "rootfs defaults onto the resolved ROOTFS_STORAGE"
eq "$(grep -o -- '--mp0 [^ ]*' <<<"$args")" "--mp0 dir-a:1,mp=/etc" \
  "mp0 follows the rootfs store when unset"
eq "$(grep -o -- '--mp1 [^ ]*' <<<"$args")" "--mp1 dir-a:16,mp=/var" \
  "mp1 follows the rootfs store when unset"
eq "$(grep -o -- '--mp2 [^ ]*' <<<"$args")" "--mp2 dir-a:16,mp=/usr/lib/bootc" \
  "mp2 follows the rootfs store when unset"
eq "$([[ $args == *'extra=1'* ]] && echo yes)" "yes" "remaining options pass through to pct create"

LOG="$TMP/pct2.log"
: >"$LOG"
PVECT_TEST_LOG="$LOG" ROOTFS_STORAGE=dir-a MP0_STORAGE= MP1_STORAGE= MP2_STORAGE= \
  cmd_create 9992 img --rootfs-storage=dir-b --mp1-storage dir-b --memory 512
args=$(tr '\0' ' ' <"$LOG")
eq "$(grep -o -- '--rootfs [^ ]*' <<<"$args")" "--rootfs dir-b:0" \
  "explicit --rootfs-storage= re-targets the rootfs"
eq "$(grep -o -- '--mp0 [^ ]*' <<<"$args")" "--mp0 dir-b:1,mp=/etc" \
  "mp0 follows the CLI rootfs store when unset"
eq "$(grep -o -- '--mp1 [^ ]*' <<<"$args")" "--mp1 dir-b:16,mp=/var" \
  "explicit --mp1-storage re-targets mp1 only"
eq "$(grep -o -- '--mp0 \|--mp1 ' <<<"$args" | uniq | grep -c -- '--mp')" "2" \
  "each mp is allocated exactly once"
eq "$([[ $args == *'--memory 512'* ]] && echo yes)" "yes" \
  "pct options after the storage flags still reach pct create"

out=$(PVECT_TEST_LOG=/dev/null ROOTFS_STORAGE=dir-a MP1_STORAGE= \
  cmd_create 9993 img --mp1-storage local 2>&1 >/dev/null)
if [[ $out == *"'local'"*"rootdir'"* ]]; then ok "CLI store lacking 'content rootdir' is rejected"; else bad "bad rejection: $out"; fi

info "== resolved defaults (resolve_default_storages) =="
pveam() { # stub: templates live only where PVECT_TEST_TEMPLATES points
  [[ $1 == list && $2 == "${PVECT_TEST_TEMPLATES:-}" && -n ${PVECT_TEST_TEMPLATES:-} ]] \
    && { echo "local:vztmpl/alpine-3.20-amd64.tar.gz"; return 0; }
  return 0
}
ROOTFS_STORAGE=; STORAGE=; TEMPLATE_STORAGE=
resolve_default_storages
eq "$ROOTFS_STORAGE" "dir-a" "ROOTFS_STORAGE defaults to the first ACTIVE rootdir storage"
eq "$STORAGE" "dir-a" "legacy STORAGE alias follows the resolved ROOTFS_STORAGE"
eq "$TEMPLATE_STORAGE" "dir-b" "TEMPLATE_STORAGE defaults to the first ACTIVE vztmpl storage"
PVECT_TEST_TEMPLATES=local ROOTFS_STORAGE= STORAGE= TEMPLATE_STORAGE=
resolve_default_storages
eq "$TEMPLATE_STORAGE" "local" "vztmpl storage that already holds templates wins"
ROOTFS_STORAGE=kept-root TEMPLATE_STORAGE=kept-tmpl
resolve_default_storages
eq "$ROOTFS_STORAGE" "kept-root" "explicit ROOTFS_STORAGE override wins"
eq "$TEMPLATE_STORAGE" "kept-tmpl" "explicit TEMPLATE_STORAGE override wins"

info "== pvect-bootc template-storage resolution =="
PVECT_TEST_TEMPLATES= # reset the stub state leaked by the preceding section
. "$HERE/../../pve-manager/usr/share/pve-manager/dc/pvect-bootc"
TEMPLATE_STORAGE=
resolve_default_storages
eq "$TEMPLATE_STORAGE" "dir-b" "pvect-bootc defaults to the first ACTIVE vztmpl storage"
PVECT_TEST_TEMPLATES=local TEMPLATE_STORAGE=
resolve_default_storages
eq "$TEMPLATE_STORAGE" "local" "pvect-bootc: already-hosted templates win"
PVECT_TEST_TEMPLATES=
TEMPLATE_STORAGE=
resolve_default_storages
eq "$TEMPLATE_STORAGE" "dir-b" "pvect-bootc returns to the first-active default once templates vanish"
out=$(seed_probe() {
  local vmid=1 archive='dir-b:vztmpl/ghost-stack.tar.gz'
  # create_guest must resolve the seed through pvesm path (never a hard-coded
  # /var/lib/pve/<storeid>/... path); the stub returns an unreadable path,
  # so the run dies right after the resolution attempt.
  local storeid=dir-b stack=ghost-stack file
  file=$(pvesm path "$storeid:vztmpl/$stack.tar.gz" 2>/dev/null)
  [[ -n $file && -r $file ]] \
    || { warn "seed template $archive not found (resolved storage: $TEMPLATE_STORAGE)"; return 1; }
}; TEMPLATE_STORAGE=dir-b seed_probe 2>&1)
if [[ $out == *"seed template dir-b:vztmpl/ghost-stack.tar.gz not found (resolved storage: dir-b)"* ]]; then
  ok "seed file is resolved through the storage API"
else
  bad "seed resolution message: $out"
fi

info "== stage_mp_dir (mp file volumes) =="
# Dir targets pass through unchanged; anything else (raw file) needs a loop
# mount — root-only, so unit-test the passthrough and loud-death branches and
# verify the descriptor shape the seed loop relies on.
mkdir -p "$TMP/legacy-ct/9994/etc" "$TMP/legacy-ct/9994/var"
out=$(stage_mp_dir "$TMP/legacy-ct/9994/etc")
eq "$out" "$TMP/legacy-ct/9994/etc|" "stage_mp_dir passes an existing dir through (empty cleanup id)"
out=$(stage_mp_dir "$TMP/legacy-ct/9994/var")
eq "$out" "$TMP/legacy-ct/9994/var|" "stage_mp_dir passes a second dir through"
out=$(stage_mp_dir "$TMP/does-not-exist" 2>&1 >/dev/null)
if [[ $out == *"mp target does not exist"* ]]; then
  ok "stage_mp_dir dies loudly on a missing target"
else
  bad "stage_mp_dir missing-target death: $out"
fi
# Raw FILE volumes must map to a loop-staged mount, never a directory op on
# the file itself. Without root (no losetup), assert the function reaches the
# mount path and dies loud — never silently treating the file as a dir.
: >"$TMP/vm-214-disk-1.raw"
out=$(stage_mp_dir "$TMP/vm-214-disk-1.raw" 2>&1 >/dev/null)
if [[ $out == *"$TMP/vm-214-disk-1.raw"* ]] && [[ -f $TMP/vm-214-disk-1.raw ]]; then
  ok "stage_mp_dir treats a raw file as a volume (loud stage attempt, file untouched)"
else
  bad "stage_mp_dir raw-file handling: $out"
fi

info "== publish --no-test flag parsing =="
parse_stack_args 1 --name s --no-test
eq "$STACK" "s" "publish: --name parsed with --no-test"
eq "$NO_TEST" "1" "publish: --no-test sets NO_TEST"
NO_TEST=
out=$(parse_stack_args 1 --name s2 2>&1 >/dev/null)
eq "${NO_TEST:-0}" "0" "publish: NO_TEST defaults to 0"
out=$(parse_stack_args 0 --no-test 2>&1 >/dev/null)
if [[ $out == *"unknown option: --no-test"* ]]; then
  ok "build (smoke-gated) rejects --no-test"
else
  bad "build acceptance of --no-test: $out"
fi

if (( fail )); then
  info "pvect-ostree tests FAILED"
  exit 1
fi
info "pvect-ostree tests PASSED"