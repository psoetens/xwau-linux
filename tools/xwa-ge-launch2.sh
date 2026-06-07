#!/bin/bash
# XWAU one-runtime launcher (plan community-release-v1, P0): GE-Proton8-26
# provides BOTH wine and codecs. Supersedes the two-runtime xwa-ge-launch.sh
# (Proton 8.0 wine + GE codecs), which stays untouched as the fallback.
#
# Why this works (GE-wine retest, 2026-06-07, user-verified + log-verified):
#   * GE's wine is wine-8.0 (Staging), win32-prefix capable; renders the game
#     correctly incl. HD concourse (the old "GE wine renders 2D wrong" verdict
#     came from the win64-compat-tool era where the .NET hooks were broken).
#   * GE's gstreamer/ffmpeg decode the HD H.264 cutscenes (stock Proton 8
#     can't). One runtime = one download for the community installer.
#   * Requires TGSMUSH.DLL >= e3ca134 (linux-wine-fixes): staging mfplat never
#     delivers SampleGrabberCB::OnShutdown, so PlayVideo must clear the
#     shared-mem videoFrameIndex itself (else: frozen last movie frame).
#   * WINEPREFIX = the win32 prefix with real .NET 4.8 (CLR-in-DllMain hooks).
#   * Note: wine's builtin ddraw cannot load in GE's layout (err:module
#     wined3d) — harmless, the game-dir native ddraw_effects is what loads.
# See memory upstream-patch-prep + reports/xwau-linux-ge-unified-solution.md.
#
# Steam Launch Options:
#   bash -c 'exec /home/kaltan/src/SteamLibrary/tools/xwa-ge-launch2.sh' %command%

P8="/home/kaltan/src/SteamLibrary/steamapps/common/Proton 8.0"
GE="$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton8-26/files"

export WINEPREFIX="$HOME/.local/share/xwa-prefix"

# Clean handoff if the prefix was last driven by the other wine build
# (mixing wine builds against one live wineserver is undefined).
"$P8/dist/bin/wineserver" -k 2>/dev/null
"$GE/bin/wineserver" -k 2>/dev/null
sleep 1

export WINELOADER="$GE/bin/wine"
export WINESERVER="$GE/bin/wineserver"
export PATH="$GE/bin:$PATH"
export LD_LIBRARY_PATH="$GE/lib/i386-linux-gnu:$GE/lib:$GE/lib64:$LD_LIBRARY_PATH"
export GST_PLUGIN_SYSTEM_PATH_1_0="$GE/lib/gstreamer-1.0:$GE/lib64/gstreamer-1.0"
export GST_PLUGIN_PATH="$GE/lib/gstreamer-1.0:$GE/lib64/gstreamer-1.0"

GAME="/home/kaltan/src/SteamLibrary/steamapps/common/Star Wars X-Wing Alliance"
cd "$GAME" || exit 1
# Quiet by default. NOTE: Steam exports its own WINEDEBUG, so ${VAR:-default}
# never applies — hardcode channels here when tracing (e.g.
# err+seh,err+module,fixme-all,+debugstr).
export WINEDEBUG="-all"

# Pre-start the 32-bit sideload player (hook_32bpp EnableSideProcess=1) so HD
# OPT processing stays out of the game's 4 GB address space. Logs to
# xwa32bpp-player32.log in the game dir.
pkill -f 'Xwa32bppPlayer' 2>/dev/null   # reap orphans from crashed runs
"$GE/bin/wine" "$GAME/Xwa32bppPlayer32.exe" &
XWA32BPP_PID=$!
sleep 2

"$GE/bin/wine" "$GAME/xwingalliance.exe" > "$HOME/xwa-ge2.log" 2>&1
RC=$?
kill $XWA32BPP_PID 2>/dev/null
"$GE/bin/wineserver" -k 2>/dev/null
exit $RC
