#!/usr/bin/env bash
# Proves install-xwau-steam.sh aborts up front when Steam is running (before doing
# any work), and that --no-steam-config lifts that requirement. Uses a fake process
# named "steam" (so `pgrep -x steam` matches) — does NOT touch real Steam.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
FAKE=""
cleanup() { [ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/steamapps/common/game" "$TMP/work"
echo x > "$TMP/steamapps/common/game/xwingalliance.exe"
G="$TMP/steamapps/common/game"

# fake "steam" process: comm must be exactly "steam" for `pgrep -x steam`
cp "$(command -v sleep)" "$TMP/steam"
"$TMP/steam" 120 & FAKE=$!
# give it a moment to show up in the process table
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x steam >/dev/null 2>&1 && break; done

pass=0; fail=0
ck() { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got '$1' want '$2')"; fail=$((fail+1)); fi; }

GUARD='pass --no-steam-config to install'   # phrase unique to the early config guard

# 1) Steam running, default (config on) -> abort early with the guard message
out="$("$REPO/install-xwau-steam.sh" --game-dir "$G" --work-dir "$TMP/work" --steam-root "$TMP/sr" 2>&1)"; rc=$?
{ [ "$rc" != 0 ] && r=died; } || r=ok;                 ck "$r" died "aborts when Steam is running"
{ printf '%s' "$out" | grep -qF "$GUARD" && r=yes; } || r=no; ck "$r" yes "abort message points to --no-steam-config"

# 2) --no-steam-config -> gets PAST the config guard (may stop later, but not here)
out2="$("$REPO/install-xwau-steam.sh" --game-dir "$G" --work-dir "$TMP/work" --steam-root "$TMP/sr" --no-steam-config 2>&1)"
{ printf '%s' "$out2" | grep -qF "$GUARD" && r=blocked; } || r=passed; ck "$r" passed "--no-steam-config bypasses the Steam-closed abort"

echo "----"; echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
