#!/bin/bash
# Sandbox spec tests for the qcowbind plugin + helpers. Nothing touches a
# real CT/VM/nbd/dataset; every external behaviour is stubbed (t/lib) or
# exercised only through the helpers' refusal paths.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/.."

fail=0

# --- plugin spec tests (perl, stubbed PVE) ------------------------------------
if perl -I t/lib -I usr/share/perl5 t/qcowbind-plugin.t; then
    echo "perl: plugin spec tests PASSED"
else
    echo "perl: plugin spec tests FAILED" >&2
    fail=1
fi

# --- syntax gates ------------------------------------------------------------
if perl -I t/lib -I usr/share/perl5 -MPVE::Storage::Custom::QcowBindPlugin -e 'print ""' 2>/dev/null; then
    echo "perl: plugin compiles"
else
    echo "perl: plugin compile FAILED" >&2
    fail=1
fi
if bash -n usr/sbin/qcowbind-bind; then
    echo "bash: bind helper compiles"
else
    echo "bash: bind helper compile FAILED" >&2
    fail=1
fi
if head -1 usr/sbin/qcowbind-resize | grep -q '^#!/usr/bin/env perl'; then
    # Grammar/usage checks stay source-based (no real PVE here); the compile
    # gate runs against the PVE stubs.
    if grep -q 'usage: qcowbind-resize' usr/sbin/qcowbind-resize \
        && grep -q 'QCOWBIND_DIRECT_RESIZE' usr/sbin/qcowbind-resize \
        && grep -qF '.share' usr/sbin/qcowbind-resize \
        && perl -I t/lib -c usr/sbin/qcowbind-resize >/dev/null 2>&1; then
        echo "perl: resize helper spec OK (grammar, marker, share-only target, compiles)"
    else
        echo "perl: resize helper FAILED (spec)" >&2
        fail=1
    fi
else
    echo "perl: resize helper run FAILED" >&2
    fail=1
fi

# --- helper spec tests (grammar/refusal paths reachable without /etc/pve) ------
spec() {
    local want=$1; shift
    if out=$(bash "$@" 2>&1); then
        echo "FAIL: '$*' was expected to fail ($want), got success: $out" >&2
        fail=1
    fi
}
spec 2 bash usr/sbin/qcowbind-bind                                            # usage
spec 2 bash usr/sbin/qcowbind-bind add                                        # usage
spec 1 bash usr/sbin/qcowbind-bind add 121 'qco:old.qcow2' /data              # v1 grammar refused
spec 1 bash usr/sbin/qcowbind-bind add 121 'local:vm-103-disk-0.raw' /data    # not a qcowbind volume
spec 1 bash usr/sbin/qcowbind-bind add 121 'local:space .share' /data         # bad name

python3 - <<'EOF' || fail=1
import pathlib
t = pathlib.Path('usr/sbin/qcowbind-bind').read_text()
# share size never lands in a CT conf through this helper
assert "size MUST NOT be set in the CT conf" in t
assert 'size=' in t
# the VM face: virtiofs only, never a disk attach
assert 'vm-add' in t and 'vm-drop' in t and 'virtiofs0' in t
print("bash: helper spec checks PASSED")
EOF

if [ "$fail" -eq 0 ]; then
    echo "ALL qcowbind tests PASSED"
else
    echo "qcowbind tests FAILED" >&2
    exit 1
fi