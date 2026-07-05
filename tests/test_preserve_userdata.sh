#!/usr/bin/env bash
# Proves xwau_remove_gamefiles preserves user pilots + configs across the vanilla
# restore, while still reverting mod files and regenerating Hooks.ini.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/installer/common.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G="$TMP/game"; V="$G.vanilla"
mkdir -p "$G" "$V"

# vanilla: stock files, an edited-later config.cfg + ddraw.cfg, NO UserData/Bloom/Hooks
printf 'stock\n'            > "$V/xwingalliance.exe"
printf 'controls=vanilla\n' > "$V/config.cfg"
printf 'ddraw=vanilla\n'    > "$V/ddraw.cfg"
cp -a "$V/xwingalliance.exe" "$G/"

# modded game: user pilot, user-edited config.cfg + ddraw.cfg, effect cfg, Hooks.ini, mod DLL
mkdir -p "$G/UserData/XWAU/Pilot"
printf 'MYPILOT\n'          > "$G/UserData/XWAU/Pilot/User0.plt"
printf 'controls=USER_EDIT\n' > "$G/config.cfg"      # user changed keybinds in-game
printf 'ddraw=vanilla\nHDConcourseEnabled=1\n' > "$G/ddraw.cfg"
printf 'Bloom=USER_TUNED\n' > "$G/Bloom.cfg"         # user tweaked an effect
printf '[hook_concourse]\n' > "$G/Hooks.ini"         # marker (should be regenerated)
printf 'MOD\n'              > "$G/ddraw_effects.dll" # mod file (should be reverted away)

xwau_remove_gamefiles "$G" >/dev/null 2>&1

pass=0; fail=0
ck() { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got '$1' want '$2')"; fail=$((fail+1)); fi; }

{ [ -f "$G/UserData/XWAU/Pilot/User0.plt" ] && r=kept; } || r=lost
ck "$r" kept "user pilot preserved"
ck "$(cat "$G/UserData/XWAU/Pilot/User0.plt")" "MYPILOT" "pilot content intact"
{ [ "$(cat "$G/config.cfg")" = "controls=USER_EDIT" ] && r=kept; } || r=reverted
ck "$r" kept "user-edited config.cfg preserved (not reverted to vanilla)"
{ grep -q USER_TUNED "$G/Bloom.cfg" 2>/dev/null && r=kept; } || r=lost
ck "$r" kept "user effect config (Bloom.cfg) preserved"
{ [ -e "$G/Hooks.ini" ] && r=present; } || r=gone
ck "$r" gone "Hooks.ini regenerated (removed by restore, not preserved)"
{ [ -e "$G/ddraw_effects.dll" ] && r=present; } || r=gone
ck "$r" gone "mod file reverted away (real restore happened)"
{ [ -f "$G/xwingalliance.exe" ] && r=present; } || r=gone
ck "$r" present "stock file restored from vanilla"

echo "----"; echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
