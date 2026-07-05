#!/usr/bin/env bash
# Proves xwau_payload_replay() cleans up the extracted scratch payloads after a
# successful install, keeps them when XWAU_KEEP_PAYLOADS is set, and keeps them
# (for debugging) when the replay step fails. Uses stubs — no real 6.6G zips.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/installer/common.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/installer" "$TMP/game" "$TMP/prof" "$TMP/work"

# stub payload installer: exit code from STUB_RC (default 0)
cat > "$TMP/installer/xwau_payload_install.py" <<'PY'
import sys, os
sys.exit(int(os.environ.get("STUB_RC", "0")))
PY

# tiny stub zips (real zips so unzip -q succeeds)
python3 - "$TMP/full.zip" "$TMP/upd.zip" <<'PY'
import sys, zipfile
for p in sys.argv[1:]:
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("x.txt", "x")
PY

pass=0; fail=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got '$1' want '$2')"; fail=$((fail+1)); fi; }
replay() { xwau_payload_replay "$TMP" "$TMP/game" "$TMP/prof" "$TMP/work" "$TMP/full.zip" "$TMP/upd.zip" 2 High >/dev/null 2>&1; }

# 1) normal successful run -> scratch payloads deleted
rm -rf "$TMP/work/payloads"
STUB_RC=0 replay
{ [ -d "$TMP/work/payloads" ] && r=present; } || r=absent
check "$r" absent "normal run deletes \$work/payloads"

# 2) XWAU_KEEP_PAYLOADS=1 -> retained
rm -rf "$TMP/work/payloads"
STUB_RC=0 XWAU_KEEP_PAYLOADS=1 replay
{ [ -d "$TMP/work/payloads" ] && r=present; } || r=absent
check "$r" present "XWAU_KEEP_PAYLOADS retains \$work/payloads"

# 3) replay step fails -> retained + non-zero return
rm -rf "$TMP/work/payloads"
STUB_RC=1 replay; rc=$?
{ [ -d "$TMP/work/payloads" ] && r=present; } || r=absent
check "$r" present "failed replay retains \$work/payloads"
{ [ "$rc" != 0 ] && rr=nonzero; } || rr=zero
check "$rr" nonzero "failed replay returns non-zero"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
