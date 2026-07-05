#!/usr/bin/env bash
# Covers the --remove / --reinstall building blocks with stubs (no real 6.6G zips,
# no wine): manifest roundtrip, game-file restore, steam_config.py --remove,
# the two guard failures, and a standalone --remove end-to-end.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
. "$REPO/installer/common.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() { if [ "$1" = "$2" ]; then echo "PASS: $3"; pass=$((pass+1)); else echo "FAIL: $3 (got '$1' want '$2')"; fail=$((fail+1)); fi; }

# ---------- A. manifest write -> load roundtrip ----------
mkdir -p "$TMP/a"
xwau_write_manifest "$TMP/a" variant=steam release_tag=v9.9.9 \
    xwau_full=/x/Full.zip xwau_upd=/x/Upd.zip ratio=3 preset=Ultra \
    resolution=1920x1080 concourse_pace=2 appid=361670 >/dev/null
xwau_load_manifest "$TMP/a"
check "$MF_VARIANT" steam "manifest variant roundtrips"
check "$MF_RELEASE_TAG" v9.9.9 "manifest release_tag roundtrips"
check "$MF_XWAU_FULL" /x/Full.zip "manifest xwau_full roundtrips"
check "$MF_RATIO" 3 "manifest ratio roundtrips"
check "$MF_PRESET" Ultra "manifest preset roundtrips"

# ---------- B. xwau_remove_gamefiles restores from .vanilla ----------
G="$TMP/b/game"; V="$TMP/b/game.vanilla"
mkdir -p "$G" "$V"
echo orig > "$V/stock.txt"                       # a stock file
echo orig > "$G/stock.txt"
echo mod  > "$G/ddraw_effects.dll"               # a mod-added file
echo mod  > "$G/.xwau-install.json"              # the manifest (must be wiped)
mkdir -p "$G/.linux-lib32"; echo x > "$G/.linux-lib32/libvpx.so.6"
xwau_remove_gamefiles "$G" >/dev/null
{ [ -e "$G/ddraw_effects.dll" ] && r=present; } || r=gone; check "$r" gone "remove drops mod DLL"
{ [ -e "$G/.xwau-install.json" ] && r=present; } || r=gone; check "$r" gone "remove drops manifest"
{ [ -e "$G/.linux-lib32" ] && r=present; } || r=gone; check "$r" gone "remove drops .linux-lib32"
{ [ -e "$G/stock.txt" ] && r=present; } || r=gone; check "$r" present "remove keeps stock file"
{ [ -d "$V" ] && r=present; } || r=gone; check "$r" present "remove keeps the .vanilla backup"

# ---------- C. steam_config.py --remove ----------
SR="$TMP/c/steam"; mkdir -p "$SR/config" "$SR/userdata/1/config"
cat > "$SR/config/config.vdf" <<'VDF'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"0"
					{
						"name"		"proton_experimental"
						"config"		""
						"priority"		"75"
					}
					"361670"
					{
						"name"		"proton_11"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
VDF
cat > "$SR/userdata/1/config/localconfig.vdf" <<'VDF'
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"361670"
					{
						"LaunchOptions"		"PROTON_LOG=1 %command%"
					}
				}
			}
		}
	}
}
VDF
python3 "$REPO/installer/steam_config.py" --remove --steam-root "$SR" --appid 361670 >/dev/null 2>&1
grep -q '"361670"' "$SR/config/config.vdf" && r=present || r=gone
check "$r" gone "steam_config --remove drops CompatToolMapping/361670"
grep -q '"0"' "$SR/config/config.vdf" && r=present || r=gone
check "$r" present "steam_config --remove keeps other mappings"
lo="$(grep -A1 '"361670"' "$SR/userdata/1/config/localconfig.vdf" | grep -oi 'LaunchOptions"[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')"
check "${lo:-EMPTY}" EMPTY "steam_config --remove clears LaunchOptions"

# ---------- D. guard: --remove with no .vanilla dies cleanly ----------
mkdir -p "$TMP/d/game"; echo x > "$TMP/d/game/stock.txt"
if ( xwau_remove_gamefiles "$TMP/d/game" ) >/dev/null 2>&1; then r=ok; else r=died; fi
check "$r" died "remove without .vanilla dies (no restore point)"

# ---------- E. guard: standalone --reinstall, no manifest + no --xwau -> die ----------
G2="$TMP/e/game"; mkdir -p "$G2" "$G2.vanilla"; echo x > "$G2/stock.txt"; echo x > "$G2.vanilla/stock.txt"
echo mod > "$G2/mod.txt"
"$REPO/install-xwau-linux.sh" --reinstall --game-dir "$G2" >/dev/null 2>&1; rc=$?
{ [ "$rc" != 0 ] && r=died; } || r=ok; check "$r" died "reinstall w/o manifest or --xwau dies"
{ [ -e "$G2/mod.txt" ] && r=present; } || r=gone
check "$r" present "failed reinstall did NOT remove anything (dies before remove)"

# ---------- F. standalone --remove end-to-end ----------
G3="$TMP/f/game"; mkdir -p "$G3" "$G3.vanilla"
echo stock > "$G3.vanilla/xwingalliance.exe"
echo stock > "$G3/xwingalliance.exe"
echo mod   > "$G3/ddraw_effects.dll"
xwau_write_manifest "$G3" variant=standalone release_tag=v0.3.0 xwau_full=/x/f.zip xwau_upd=/x/u.zip >/dev/null
"$REPO/install-xwau-linux.sh" --remove --game-dir "$G3" >/dev/null 2>&1; rc=$?
check "$rc" 0 "standalone --remove exits 0"
{ [ -e "$G3/ddraw_effects.dll" ] && r=present; } || r=gone; check "$r" gone "standalone --remove drops mod DLL"
{ [ -e "$G3/.xwau-install.json" ] && r=present; } || r=gone; check "$r" gone "standalone --remove drops manifest"
{ [ -e "$G3.vanilla" ] && r=present; } || r=gone; check "$r" gone "standalone --remove also deletes the .vanilla backup"

echo "----"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
