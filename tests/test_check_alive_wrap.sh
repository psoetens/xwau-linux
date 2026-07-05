#!/usr/bin/env bash
# Proves installer/xwa-steam-run.sh brackets the game run with the GNOME
# check-alive-timeout toggle (set 0 -> run -> restore), passes args + exit code
# through, and is a clean no-op when gsettings is absent. Uses a STUB gsettings so
# no real GNOME setting is touched.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WRAP="$REPO/installer/xwa-steam-run.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# stub gsettings: log every call; `get` prints a fixed old value
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gsettings" <<'EOF'
#!/bin/bash
echo "$*" >> "$GSLOG"
[ "$1" = get ] && echo "uint32 5000"
exit 0
EOF
chmod +x "$BIN/gsettings"

pass=0; fail=0
ck() { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got '$1' want '$2')"; fail=$((fail+1)); fi; }

# --- with gsettings present: toggle 0 -> run -> restore, exit code passthrough ---
export GSLOG="$TMP/calls.log"; : > "$GSLOG"
out="$(PATH="$BIN:$PATH" GSLOG="$GSLOG" bash "$WRAP" bash -c 'echo RAN_MARKER; exit 7')"; rc=$?
ck "$rc" 7 "exit code passes through"
{ printf '%s' "$out" | grep -qx RAN_MARKER && r=yes; } || r=no; ck "$r" yes "wrapped command runs"
{ grep -qx 'set org.gnome.mutter check-alive-timeout 0' "$GSLOG" && r=yes; } || r=no; ck "$r" yes "sets check-alive-timeout 0"
{ grep -qx 'set org.gnome.mutter check-alive-timeout uint32 5000' "$GSLOG" && r=yes; } || r=no; ck "$r" yes "restores previous value"
# order: the '0' set happens before the restore
first_set=$(grep -n 'check-alive-timeout 0$' "$GSLOG" | head -1 | cut -d: -f1)
restore_set=$(grep -n 'check-alive-timeout uint32 5000$' "$GSLOG" | head -1 | cut -d: -f1)
{ [ -n "$first_set" ] && [ -n "$restore_set" ] && [ "$first_set" -lt "$restore_set" ] && r=ok; } || r=bad
ck "$r" ok "sets 0 before restoring"

# --- without gsettings on PATH: clean no-op, still runs + passes exit code ---
minimal="/usr/bin:/bin"   # no stub gsettings here
out2="$(PATH="$minimal" bash "$WRAP" bash -c 'echo OK2; exit 3')"; rc2=$?
ck "$rc2" 3 "no-gsettings: exit code passes through"
{ printf '%s' "$out2" | grep -qx OK2 && r=yes; } || r=no; ck "$r" yes "no-gsettings: command still runs"

echo "----"; echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
