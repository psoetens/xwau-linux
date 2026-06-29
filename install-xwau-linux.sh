#!/bin/bash
# install-xwau-linux.sh — set up X-Wing Alliance + XWAU 2025 on Linux (WIN64).
#
# This is the WIN64 architecture (branch: win64). The 32-bit sidecar process,
# the skins downscale, and the whole 32-bit-VA mitigation stack are GONE — the
# hooks run in-process in a win64 prefix (the 32-bit game runs under WoW64),
# full-res skins fit, and HD concourse + HD video both render on wine-11.
#
# What it does (each step skipped if already done):
#   1. checks host dependencies
#   2. provisions a wine-11 runtime (+ DXVK)
#   3. backs up the vanilla game directory
#   4. creates a WIN64 wine prefix with the chosen CLR runtime (wine-mono or
#      dotnet48) + the exact DLL-override set the port needs
#   5. installs XWAU 2025 from the two official distribution zips (payload replay)
#   6. installs the Linux binaries (ddraw_effects force-shim, TGSMUSH, native
#      hook_patcher, the native CLR-hosting hook shims) and overlays config
#   7. installs the launcher (NO sidecar pre-start — hooks are in-process)
#
# You must download the XWAU 2025 zips yourself from https://www.xwaupgrade.com/
#   XWAU2025_Full_1.0.0.zip and XWAU2025_UPD_1.1.0.zip
#
# Usage:
#   ./install-xwau-linux.sh --xwau-full /path/XWAU2025_Full_1.0.0.zip \
#                           --xwau-upd  /path/XWAU2025_UPD_1.1.0.zip \
#                           --bin-dir   /path/to/win64/binaries
# Options:
#   --game-dir PATH    X-Wing Alliance install dir (default: auto-detect Steam)
#   --prefix PATH      wine prefix to create/use (default: ~/.local/share/xwa-prefix-w64)
#   --work-dir PATH    scratch dir (default: ~/.cache/xwau-linux-install)
#   --wine-dir PATH    wine-11 build dir (contains bin/wine) (DECISION: see below)
#   --runtime NAME     wine-mono (default) | dotnet48
#   --bin-dir PATH     dir holding the win64 binaries to install (DECISION: see below)
#   --ratio {2,3}      XWAU aspect-ratio finalize package (default 2 = 16:9)
#   --preset NAME      veryLow|Low|Medium|High|Ultra (default High — win64 has no
#                      VA ceiling, so the win32 'Medium' clamp is gone)
#   --resolution WxH   force [hook_resolution] (use if the menu renders half-size)
#   --skip-prefix --skip-xwau --skip-binaries --skip-configs   resume helpers
#
# ============================ OPEN DECISIONS (win64) =========================
# The structural cleanup (no sidecar / no downscale / no VA workarounds) is DONE.
# Three things are still PARAMETERIZED and default to the dev-validated setup;
# lock them before treating this as a shippable installer:
#   1. WINE: which wine-11 to ship. Default --wine-dir = the local self-built
#      ~/.local/opt/wine-11.10-amd64 (validated). SHIPPING TODO: a redistributable
#      wine-11 (Kron4ek standalone is the front-runner) downloaded like GE was.
#   2. RUNTIME: wine-mono (default — needs the native hook_patcher, drops the
#      ~400 MB dotnet48 install, validated this session) vs dotnet48 (proven).
#   3. BINARIES: the win64 binary set is NOT in release v0.1.0 (those are win32).
#      Default = install from a local --bin-dir (build outputs). SHIPPING TODO:
#      cut a win64 release and add a --release path.
# The functional end-to-end install is therefore UNVERIFIED pending these; the
# structural cleanup is what this revision delivers.
# =============================================================================
#
# NEVER run Steam "Verify integrity of game files" on a modded install —
# restore from the .vanilla backup instead.

set -euo pipefail

# ---------------------------------------------------------------- defaults
RUNTIME="wine-mono"                 # wine-mono | dotnet48  (DECISION 2)
# DECISION 1: default to the validated local wine-11.10; --wine-dir to override.
WINE_DIR="${WINE_DIR:-$HOME/.local/opt/wine-11.10-amd64}"
# DECISION 3: win64 binaries from a local build dir (no win64 release yet).
BIN_DIR=""

PREFIX="$HOME/.local/share/xwa-prefix-w64"
WORK="$HOME/.cache/xwau-linux-install"
COMPAT_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
GAME=""
XWAU_FULL="" XWAU_UPD=""
RATIO="2" PRESET="High" RESOLUTION="" CONCOURSE_PACE=""
SKIP_PREFIX=0 SKIP_XWAU=0 SKIP_BINARIES=0 SKIP_CONFIGS=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --work-dir) WORK="$2"; shift 2 ;;
        --wine-dir) WINE_DIR="$2"; shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --xwau-full) XWAU_FULL="$2"; shift 2 ;;
        --xwau-upd) XWAU_UPD="$2"; shift 2 ;;
        --ratio) RATIO="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --resolution) RESOLUTION="$2"; shift 2 ;;
        --concourse-pace) CONCOURSE_PACE="$2"; shift 2 ;;
        --skip-prefix) SKIP_PREFIX=1; shift ;;
        --skip-xwau) SKIP_XWAU=1; shift ;;
        --skip-binaries) SKIP_BINARIES=1; shift ;;
        --skip-configs) SKIP_CONFIGS=1; shift ;;
        -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

case "$RUNTIME" in wine-mono|dotnet48) ;; *) echo "bad --runtime: $RUNTIME"; exit 2 ;; esac
WINE="$WINE_DIR/bin/wine"
WINESERVER_BIN="$WINE_DIR/bin/wineserver"
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- step 1: deps
log "Checking host dependencies"
NEED="curl tar unzip python3 sha256sum"
[ "$RUNTIME" = dotnet48 ] && NEED="$NEED sha512sum cabextract"
for tool in $NEED; do
    command -v "$tool" >/dev/null || die "missing '$tool' — install it"
done
if command -v fc-list >/dev/null; then
    fc-list | /usr/bin/grep -qi "DejaVu Sans" || warn "font 'DejaVu Sans' not found — install dejavu fonts (HUD text blank without it)"
    fc-list | /usr/bin/grep -qi "Liberation Mono" || warn "font 'Liberation Mono' not found — install liberation fonts (concourse text blank without it)"
else
    warn "fc-list not found — cannot verify fonts (DejaVu Sans + Liberation Mono required)"
fi
mkdir -p "$WORK"

# ---------------------------------------------------------------- step 2: wine-11
# DECISION 1: this expects a wine-11 build at $WINE_DIR. Default is the validated
# self-built ~/.local/opt/wine-11.10-amd64. To SHIP, replace this with a download
# of a redistributable wine-11 (Kron4ek standalone) the way GE was fetched in the
# win32 installer. wine-11 is the floor (HD video Media Foundation + wine-mono).
[ -x "$WINE" ] || die "wine not found at $WINE (pass --wine-dir to a wine-11 build; SHIPPING TODO: bundle a redistributable wine-11)"
WVER="$("$WINE" --version 2>/dev/null || echo unknown)"
case "$WVER" in
    wine-1[1-9]*|wine-[2-9][0-9]*) echo "    wine: $WVER ($WINE_DIR)" ;;
    *) die "need wine-11 or newer (got '$WVER') — HD video + the in-process hooks require it" ;;
esac
# DXVK source: any GE-Proton in compatibilitytools.d bundles the 32-bit DXVK DLLs
# the WoW64 game needs. (SHIPPING TODO: bundle a pinned DXVK release instead.)
DXVK_SRC="$(ls -d "$COMPAT_DIR"/GE-Proton*/files/lib/wine/dxvk 2>/dev/null | head -1 || true)"

# ---------------------------------------------------------------- step 3: vanilla backup
if [ -z "$GAME" ]; then
    log "Locating X-Wing Alliance (Steam appid 361670)"
    for vdf in "$HOME/.steam/root/steamapps/libraryfolders.vdf" \
               "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"; do
        [ -f "$vdf" ] || continue
        while IFS= read -r lib; do
            cand="$lib/steamapps/common/Star Wars X-Wing Alliance"
            if [ -f "$cand/xwingalliance.exe" ] || [ -f "$cand/XWINGALLIANCE.EXE" ]; then
                GAME="$cand"; break 2
            fi
        done < <(/usr/bin/grep -oP '"path"\s+"\K[^"]+' "$vdf")
    done
    [ -n "$GAME" ] || die "could not find the game — install X-Wing Alliance from Steam first, or pass --game-dir"
fi
[ -d "$GAME" ] || die "game dir not found: $GAME"
echo "    game: $GAME"

if [ -d "$GAME.vanilla" ]; then
    log "Vanilla backup already exists: $GAME.vanilla"
elif [ -f "$GAME/Hooks.ini" ] || [ -f "$GAME/ddraw_effects.dll" ]; then
    warn "game dir already contains XWAU files and no .vanilla backup exists — skipping backup"
else
    log "Backing up vanilla game dir (your restore point — Steam Verify would destroy the mod)"
    cp -a "$GAME" "$GAME.vanilla"
fi

# ---------------------------------------------------------------- step 4: win64 prefix
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
export WINELOADER="$WINE" WINESERVER="$WINESERVER_BIN"
CLR_MARKER="$PREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/clr.dll"
MONO_MARKER="$PREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll"
PREFIX_DONE_MARKER="$CLR_MARKER"; [ "$RUNTIME" = wine-mono ] && PREFIX_DONE_MARKER="$MONO_MARKER"

if [ "$SKIP_PREFIX" = 1 ] || [ -f "$PREFIX_DONE_MARKER" ]; then
    log "win64 prefix ($RUNTIME) already present: $PREFIX"
else
    log "Creating WIN64 wine prefix at $PREFIX (runtime: $RUNTIME)"
    [ -d "$PREFIX" ] && die "prefix dir exists but looks incomplete — remove it or pass a different --prefix"
    WINEARCH=win64 "$WINE" wineboot -i
    "$WINESERVER_BIN" -w

    if [ "$RUNTIME" = dotnet48 ]; then
        log "Installing .NET Framework 4.8 (winetricks; downloads from Microsoft; 10-20 min)"
        [ -f "$WORK/winetricks" ] || curl -sL -o "$WORK/winetricks" \
            "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
        chmod +x "$WORK/winetricks"
        WINE="$WINE" WINESERVER="$WINESERVER_BIN" "$WORK/winetricks" -q dotnet48
        "$WINESERVER_BIN" -w
        [ -f "$CLR_MARKER" ] || die ".NET 4.8 install failed (no clr.dll) — see winetricks output"
    else
        # wine-mono ships with wine. The native hook_patcher (step 6) + the native
        # CLR-hosting hook shims make wine-mono viable (no CLR-in-DllMain deadlock).
        [ -f "$MONO_MARKER" ] || warn "wine-mono not found at $MONO_MARKER — ensure this wine build bundles wine-mono"
    fi

    log "Installing DXVK + DLL overrides"
    if [ -n "$DXVK_SRC" ]; then
        # 32-bit DXVK DLLs for the WoW64 (32-bit) game -> syswow64; 64-bit -> system32 if present.
        cp "$DXVK_SRC"/*.dll "$PREFIX/drive_c/windows/syswow64/" 2>/dev/null || \
        cp "$DXVK_SRC"/*.dll "$PREFIX/drive_c/windows/system32/" 2>/dev/null || true
        echo "    DXVK from: $DXVK_SRC"
    else
        warn "no DXVK source found (no GE-Proton in $COMPAT_DIR) — wined3d fallback bloats VA on skins. Install DXVK manually."
    fi
    for o in "*d3d11" "*d3d10core" "*d3d9" "*d3d8" "*dxgi"; do
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "$o" /d native /f
    done
    # XWAU's hook loader lives in game-dir ddraw/dinput (must win over builtins);
    # native WIC crashes the briefing room (keep builtin).
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "ddraw" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput8" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecs" /d builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecsext" /d builtin /f
    if [ "$RUNTIME" = dotnet48 ]; then
        # real .NET: mscoree must be the native dotnet48 one (loader-lock-safe).
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*mscoree" /d native /f
        "$WINE" reg add "HKLM\\Software\\Microsoft\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f
    fi
    # else wine-mono: leave *mscoree builtin (= wine-mono).
    "$WINESERVER_BIN" -w
fi

# ---------------------------------------------------------------- step 5: XWAU payloads
if [ "$SKIP_XWAU" = 1 ] || [ -f "$GAME/Hooks.ini" ]; then
    log "XWAU 2025 already installed (Hooks.ini present)"
else
    [ -n "$XWAU_FULL" ] && [ -f "$XWAU_FULL" ] || die "pass --xwau-full /path/XWAU2025_Full_1.0.0.zip (download from xwaupgrade.com)"
    [ -n "$XWAU_UPD" ] && [ -f "$XWAU_UPD" ] || die "pass --xwau-upd /path/XWAU2025_UPD_1.1.0.zip (download from xwaupgrade.com)"
    log "Unpacking XWAU distribution zips"
    mkdir -p "$WORK/payloads/full" "$WORK/payloads/upd"
    unzip -o -q "$XWAU_FULL" -d "$WORK/payloads/full"
    unzip -o -q "$XWAU_UPD" -d "$WORK/payloads/upd"
    log "Installing XWAU 2025 (payload replay; ratio=$RATIO preset=$PRESET)"
    python3 "$SCRIPT_DIR/installer/xwau_payload_install.py" "$GAME" \
        "$PREFIX/drive_c/users/$USER" "$WORK/payloads" --ratio "$RATIO" --preset "$PRESET"
fi

# ---------------------------------------------------------------- step 6: win64 binaries
# The win64 binary overlay. DECISION 3: sourced from a local --bin-dir (no win64
# release yet). Required files (build outputs from this project):
#   ddraw_effects.dll        - force-shim ddraw (HD concourse on wine-11)
#   TGSMUSH.DLL              - MF video backend
#   hook_patcher.dll         - NATIVE (unmanaged) reimpl (no CLR bootstrap deadlock)
#   hook_32bpp_net.dll       - native CLR-hosting shim (+ hook_32bpp_bridge.dll)
#   hook_concourse_net.dll   - native CLR-hosting shim (+ hook_concourse_bridge.dll)
# (hook_keyboard_bg.dll is NOT needed on win64: the Esc focus-loss it fixed was
#  the win32 sidecar window stealing focus, which doesn't exist here — verified.)
if [ "$SKIP_BINARIES" = 1 ]; then
    log "Skipping Linux binaries"
else
    [ -n "$BIN_DIR" ] && [ -d "$BIN_DIR" ] || die "pass --bin-dir DIR with the win64 binaries (SHIPPING TODO: cut a win64 release + add --release)"
    log "Installing win64 binaries from $BIN_DIR"
    install_bin() {  # src basename -> game dir (case-insensitive target), backing up the original once
        local f="$1" suffix="$2"
        [ -f "$BIN_DIR/$f" ] || die "missing $f in $BIN_DIR"
        local tgt; tgt="$(find "$GAME" -maxdepth 1 -iname "$f" | head -1)"; tgt="${tgt:-$GAME/$f}"
        [ -f "$tgt" ] && [ ! -f "$tgt$suffix" ] && cp "$tgt" "$tgt$suffix"
        cp "$BIN_DIR/$f" "$tgt"
        echo "    installed $f"
    }
    # ddraw + video (back up the XWAU originals)
    install_bin ddraw_effects.dll .xwau-orig
    install_bin TGSMUSH.DLL        .xwau-orig
    # native hook_patcher replaces the managed one (back up the IJW/.Net original)
    install_bin hook_patcher.dll   .ijw-orig
    # native CLR-hosting shims replace the IJW _net.dlls (back up the IJW originals);
    # their managed bridges sit alongside.
    install_bin hook_32bpp_net.dll      .ijw-orig
    install_bin hook_concourse_net.dll  .ijw-orig
    for b in hook_32bpp_bridge.dll hook_concourse_bridge.dll; do
        [ -f "$BIN_DIR/$b" ] && cp "$BIN_DIR/$b" "$GAME/$b" && echo "    installed $b"
    done
fi

# ---------------------------------------------------------------- step 7: configs
if [ "$SKIP_CONFIGS" = 1 ]; then
    log "Skipping config overlay"
else
    log "Applying Linux config overlay"
    # Concourse pacing depends on monitor refresh (game presents briefing frames
    # in N passes of SyncInterval N = N^2 vblanks; ~25 fps is the intended cadence).
    if [ -z "${CONCOURSE_PACE:-}" ]; then
        HZ=$(command -v xrandr >/dev/null && xrandr --current 2>/dev/null | /usr/bin/grep -oP '[0-9.]+(?=\*)' | head -1 | cut -d. -f1 || echo "")
        if   [ -z "$HZ" ];        then CONCOURSE_PACE=1
        elif [ "$HZ" -le 70 ];    then CONCOURSE_PACE=1
        elif [ "$HZ" -le 150 ];   then CONCOURSE_PACE=2
        else                           CONCOURSE_PACE=3; fi
        echo "    detected refresh ~${HZ:-?} Hz -> concourse pace $CONCOURSE_PACE"
    fi
    python3 - "$GAME" "$RESOLUTION" "$CONCOURSE_PACE" <<'PYCFG'
import sys, os, re

game, resolution, pace = sys.argv[1], sys.argv[2], sys.argv[3]

def find(name):
    for e in os.listdir(game):
        if e.lower() == name.lower():
            return os.path.join(game, e)
    return os.path.join(game, name)

def read(path):
    with open(path, 'rb') as f:
        raw = f.read()
    eol = '\r\n' if b'\r\n' in raw else '\n'
    return raw.decode('latin-1').split(eol), eol

def write(path, lines, eol):
    with open(path, 'wb') as f:
        f.write(eol.join(lines).encode('latin-1'))

def set_key(path, key, value, section=None):
    lines, eol = read(path) if os.path.exists(path) else ([], '\r\n')
    sec = None
    in_target = section is None
    pat = re.compile(r'^\s*' + re.escape(key) + r'\s*=', re.I)
    last = len(lines)
    for i, line in enumerate(lines):
        m = re.match(r'^\s*\[(.+)\]\s*$', line)
        if m:
            if in_target and section is not None:
                last = i
            sec = m.group(1).strip().lower()
            in_target = section is None or sec == section.lower()
            continue
        if in_target and pat.match(line):
            lines[i] = f'{key} = {value}'
            write(path, lines, eol)
            print(f'  {os.path.basename(path)}{"["+section+"]" if section else ""}: {key} = {value}')
            return
        if in_target and section is not None and line.strip():
            last = i + 1
    if section is not None and (sec is None or not any(
            re.match(r'^\s*\[' + re.escape(section) + r'\]\s*$', l, re.I) for l in lines)):
        lines += [f'[{section}]']
        last = len(lines)
    lines.insert(last, f'{key} = {value}')
    write(path, lines, eol)
    print(f'  {os.path.basename(path)}{"["+section+"]" if section else ""}: {key} = {value} (added)')

ddraw = find('ddraw.cfg')
set_key(ddraw, 'HDConcourseEnabled', '1')         # force-shim ddraw renders it on wine-11
set_key(ddraw, 'EnableSideProcess', '0')          # no sidecar on win64 (in-process)
set_key(ddraw, 'TgSmushSwapchainPresentEnabled', '1')
set_key(ddraw, 'TextFontFamily', 'DejaVu Sans')
set_key(ddraw, 'Text2DRendererEnabled', '1')
set_key(ddraw, 'Radar2DRendererEnabled', '1')

hooks = find('Hooks.ini')
set_key(hooks, 'HDConcourseTextFont', 'Liberation Mono', section='hook_concourse')
set_key(hooks, 'EnableSideProcess', '0', section='hook_concourse')
set_key(hooks, 'EnableSideProcess', '0', section='hook_32bpp')   # win64: in-process, full-res skins
if resolution:
    w, h = resolution.lower().split('x')
    set_key(hooks, 'ResolutionWidth', w, section='hook_resolution')
    set_key(hooks, 'ResolutionHeight', h, section='hook_resolution')

# NOTE: win64 has no 32-bit VA ceiling, so the win32 mitigations are intentionally
# NOT applied here: no SSAO raytracing/HDR force-off, no SkinsSizeThreshold /
# Xwa32bppPlayer32.cfg, no dxvk.maxFrameRate cap, no Medium preset clamp.

vrp = find('VRParams.cfg')
if os.path.exists(vrp):
    set_key(vrp, 'concourse_animations_at_25fps', pace)

tgs = find('TGSmush.cfg')
set_key(tgs, 'ForceBackend', 'mf')
set_key(tgs, 'MFSoftwarePresent', '0')
set_key(tgs, 'MFD3DPresent', '1')
PYCFG
fi

# ---------------------------------------------------------------- step 8: launcher
log "Installing launcher (win64; no sidecar pre-start)"
LAUNCHER="$GAME/xwa-linux-launch.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/bin/bash
# XWAU-on-Linux launcher (win64; generated by install-xwau-linux.sh).
WINE_DIR="$WINE_DIR"
export WINEPREFIX="$PREFIX"
"\$WINE_DIR/bin/wineserver" -k 2>/dev/null
sleep 1
export WINELOADER="\$WINE_DIR/bin/wine"
export WINESERVER="\$WINE_DIR/bin/wineserver"
export PATH="\$WINE_DIR/bin:\$PATH"
GAME="$GAME"
cd "\$GAME" || exit 1
export WINEDEBUG=-all
# No sidecar pre-start: the hooks run in-process on win64.
"\$WINE_DIR/bin/wine" "\$GAME/xwingalliance.exe" > "\$HOME/xwa-linux.log" 2>&1
RC=\$?
"\$WINE_DIR/bin/wineserver" -k 2>/dev/null
exit \$RC
LAUNCHEOF
chmod +x "$LAUNCHER"

# ---------------------------------------------------------------- done
log "Install complete (win64 architecture)"
cat <<EOF

  Set this as the game's Steam Launch Options
  (X-Wing Alliance -> Properties -> Launch Options):

    bash -c 'exec "$LAUNCHER"' %command%

  Then launch from Steam. First launch compiles shaders - give it a minute.

  IMPORTANT:
    * NEVER use Steam "Verify integrity of game files" on this install.
      Restore point: $GAME.vanilla
    * If the main menu renders half-size, re-run with --resolution (e.g.
      --resolution 1920x1080 --skip-prefix --skip-xwau --skip-binaries).
    * Log: ~/xwa-linux.log
    * win64 architecture: no sidecar, full-res skins, HD concourse + HD video.
EOF
