#!/bin/bash
# XWAU-on-Linux WIN64 launcher (the simplified architecture).
#
# Supersedes the win32 approach: XWAU's .NET hooks run IN-PROCESS under a
# 64-bit wine prefix with new-WOW64 (verified 2026-06-28 — the CLR-in-DllMain
# loader-lock issue that we thought forced win32 does NOT fail on new-WOW64).
# Consequences vs the win32 stack: NO sidecar player, NO skins downscale, NO
# 2 GB address-space ceiling -> the mission-entry memory-pressure crash is gone.
#
# Status: missions, full-res skins, and HD video work. HD CONCOURSE does NOT
# work yet on wine (wine's Direct2D custom effects are incomplete) -- run with
# ddraw.cfg HDConcourseEnabled = 0 for now. See docs/win64-architecture.md.
#
# Adjust the three paths below for your machine.

# A 64-bit wine with new-WOW64 + dotnet48 installed in the prefix.
WINE_DIR="${XWA_WINE_DIR:-$HOME/.local/opt/wine-11.10-amd64-wow64}"
# A win64 prefix with real .NET Framework 4.8 (Framework + Framework64),
# OnlyUseLatestCLR=1, *mscoree=native, and ddraw/dinput/dinput8=native,builtin.
export WINEPREFIX="${XWA_PREFIX:-$HOME/.local/share/xwa-w64-prefix}"
GAME="${XWA_GAME:-$HOME/.cache/xwau-scratch/game}"

"$WINE_DIR/bin/wineserver" -k 2>/dev/null
sleep 1
export WINELOADER="$WINE_DIR/bin/wine"
export WINESERVER="$WINE_DIR/bin/wineserver"
export PATH="$WINE_DIR/bin:$PATH"
export WINEDEBUG="${XWA_WINEDEBUG:--all}"

cd "$GAME" || exit 1
# No sidecar pre-start: hooks run in-process on win64.
"$WINE_DIR/bin/wine" "$GAME/xwingalliance.exe" > "$HOME/xwa-w64.log" 2>&1
RC=$?
"$WINE_DIR/bin/wineserver" -k 2>/dev/null
exit $RC
