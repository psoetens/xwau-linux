#!/usr/bin/env bash
# Proves the config.cfg backup/restore keeps the user's full config across a
# payload rewrite: backup -> (payload clobbers config.cfg) -> restore == original.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/installer/common.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
XWAU_STATE="$TMP/state"          # override the persistent-backup dir (don't touch $HOME)
G="$TMP/game"; mkdir -p "$G"

USERCFG=$'lastpilot Peter\njoybutton1 156\nmusic_volume 5\n'
PAYLOADCFG=$'lastpilot \njoybutton1 0\nmusic_volume 9\n'   # what the payload rewrites

pass=0; fail=0
ck() { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got '$1' want '$2')"; fail=$((fail+1)); fi; }

# 1) user config -> backup -> payload clobbers -> restore == user config (byte-exact)
printf '%s' "$USERCFG" > "$G/config.cfg"
printf '%s' "$USERCFG" > "$TMP/ref.cfg"              # reference for a byte-exact compare
xwau_backup_config "$G" >/dev/null
printf '%s' "$PAYLOADCFG" > "$G/config.cfg"          # simulate the XWAU payload rewrite
xwau_restore_config "$G" >/dev/null
{ cmp -s "$G/config.cfg" "$TMP/ref.cfg" && r=restored; } || r=clobbered
ck "$r" restored "full config.cfg restored over the payload's rewrite (byte-exact)"
ck "$(grep '^lastpilot' "$G/config.cfg")" "lastpilot Peter" "lastpilot survives"

# 2) keep-latest: a newer backup wins
printf 'lastpilot Wedge\n' > "$G/config.cfg"
xwau_backup_config "$G" >/dev/null                   # update backup to latest
printf 'lastpilot \n' > "$G/config.cfg"              # clobber again
xwau_restore_config "$G" >/dev/null
ck "$(grep '^lastpilot' "$G/config.cfg")" "lastpilot Wedge" "backup keeps the latest version"

# 3) no config.cfg -> backup/restore are clean no-ops
rm -f "$G/config.cfg"; rm -rf "$XWAU_STATE"
xwau_backup_config "$G" >/dev/null 2>&1; rc1=$?
xwau_restore_config "$G" >/dev/null 2>&1; rc2=$?
{ [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ ! -e "$G/config.cfg" ] && r=ok; } || r=bad
ck "$r" ok "no config.cfg: backup/restore are safe no-ops"

echo "----"; echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
