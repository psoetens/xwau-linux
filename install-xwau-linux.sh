#!/bin/bash
# install-xwau-linux.sh — set up X-Wing Alliance + XWAU 2025 on Linux.
#
# What it does (each step skipped if already done):
#   1. checks host dependencies
#   2. downloads GE-Proton8-26 (wine runtime + codecs) with checksum
#   3. backs up the vanilla game directory
#   4. creates a 32-bit wine prefix with real .NET Framework 4.8 (winetricks)
#      + DXVK (from GE-Proton) + the exact DLL-override set the port needs
#   5. installs XWAU 2025 from the two official distribution zips
#      (payload replay — the official .NET installer does not run under wine)
#   6. installs the Linux binaries from the xwau-linux GitHub release
#      (checksum-verified)
#   7. applies the Linux config overlay and installs the launcher
#
# You must download the XWAU 2025 zips yourself from https://www.xwaupgrade.com/
# (asset redistribution requires project approval, so this script will not
# fetch them for you):
#   XWAU2025_Full_1.0.0.zip and XWAU2025_UPD_1.1.0.zip
#
# Usage:
#   ./install-xwau-linux.sh --xwau-full /path/XWAU2025_Full_1.0.0.zip \
#                           --xwau-upd  /path/XWAU2025_UPD_1.1.0.zip
# Options:
#   --game-dir PATH    X-Wing Alliance install dir (default: auto-detect Steam)
#   --prefix PATH      wine prefix to create/use (default: ~/.local/share/xwa-prefix)
#   --work-dir PATH    scratch dir (default: ~/.cache/xwau-linux-install)
#   --ratio {2,3}      XWAU aspect-ratio finalize package (default 2 = 16:9)
#   --preset NAME      veryLow|Low|Medium|High|Ultra (default High)
#   --resolution WxH   force [hook_resolution] (use if the menu renders half-size)
#   --release TAG      xwau-linux release to install binaries from (default v0.1.0)
#   --skip-prefix --skip-xwau --skip-binaries --skip-configs   resume helpers
#
# NEVER run Steam "Verify integrity of game files" on a modded install —
# it will destroy the mod. Restore from the .vanilla backup instead.

set -euo pipefail

# ---------------------------------------------------------------- defaults
GE_NAME="GE-Proton8-26"
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_NAME}/${GE_NAME}.tar.gz"
GE_SHA_URL="${GE_URL%.tar.gz}.sha512sum"
RELEASE_TAG="v0.1.0"
RELEASE_BASE="https://github.com/psoetens/xwau-linux/releases/download"

PREFIX="$HOME/.local/share/xwa-prefix"
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
        --xwau-full) XWAU_FULL="$2"; shift 2 ;;
        --xwau-upd) XWAU_UPD="$2"; shift 2 ;;
        --ratio) RATIO="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --resolution) RESOLUTION="$2"; shift 2 ;;
        --concourse-pace) CONCOURSE_PACE="$2"; shift 2 ;;
        --release) RELEASE_TAG="$2"; shift 2 ;;
        --skip-prefix) SKIP_PREFIX=1; shift ;;
        --skip-xwau) SKIP_XWAU=1; shift ;;
        --skip-binaries) SKIP_BINARIES=1; shift ;;
        --skip-configs) SKIP_CONFIGS=1; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

GE="$COMPAT_DIR/$GE_NAME/files"
WINE="$GE/bin/wine"
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- step 1: deps
log "Checking host dependencies"
for tool in curl tar unzip python3 sha256sum sha512sum cabextract; do
    command -v "$tool" >/dev/null || die "missing '$tool' — install it (cabextract is needed by winetricks dotnet48)"
done
if command -v fc-list >/dev/null; then
    fc-list | /usr/bin/grep -qi "DejaVu Sans" || warn "font 'DejaVu Sans' not found — install the dejavu fonts package (HUD text will be blank without a present font)"
    fc-list | /usr/bin/grep -qi "Liberation Mono" || warn "font 'Liberation Mono' not found — install the liberation fonts package (concourse text will be blank without it)"
else
    warn "fc-list not found — cannot verify fonts (DejaVu Sans + Liberation Mono are required)"
fi
mkdir -p "$WORK"

# ---------------------------------------------------------------- step 2: game dir
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

# ---------------------------------------------------------------- step 3: GE-Proton
if [ -x "$WINE" ]; then
    log "$GE_NAME already present"
else
    log "Downloading $GE_NAME (~430 MB)"
    cd "$WORK"
    [ -f "$GE_NAME.tar.gz" ] || curl -L -o "$GE_NAME.tar.gz" "$GE_URL"
    curl -sL -o "$GE_NAME.sha512sum" "$GE_SHA_URL"
    sha512sum -c "$GE_NAME.sha512sum" || die "checksum mismatch on $GE_NAME.tar.gz"
    mkdir -p "$COMPAT_DIR"
    tar -xf "$GE_NAME.tar.gz" -C "$COMPAT_DIR"
    [ -x "$WINE" ] || die "extraction failed: $WINE not found"
fi

# ---------------------------------------------------------------- step 4: vanilla backup
if [ -d "$GAME.vanilla" ]; then
    log "Vanilla backup already exists: $GAME.vanilla"
elif [ -f "$GAME/Hooks.ini" ] || [ -f "$GAME/ddraw_effects.dll" ]; then
    warn "game dir already contains XWAU files and no .vanilla backup exists — skipping backup"
else
    log "Backing up vanilla game dir (this is your restore point — Steam Verify would destroy the mod)"
    cp -a "$GAME" "$GAME.vanilla"
fi

# ---------------------------------------------------------------- step 5: prefix
export WINEPREFIX="$PREFIX"
export WINEDEBUG=-all
GE_BIN="$GE/bin"
CLR_MARKER="$PREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/clr.dll"

if [ "$SKIP_PREFIX" = 1 ] || [ -f "$CLR_MARKER" ]; then
    log "win32 prefix with .NET 4.8 already present: $PREFIX"
else
    log "Creating 32-bit wine prefix at $PREFIX"
    [ -d "$PREFIX" ] && die "prefix dir exists but has no .NET 4.8 — remove it or pass a different --prefix"
    WINEARCH=win32 "$WINE" wineboot -i
    "$GE_BIN/wineserver" -w

    log "Installing .NET Framework 4.8 (winetricks; downloads from Microsoft; takes 10-20 min)"
    # IMPORTANT: no WINEDLLOVERRIDES tampering here — that breaks the native
    # mscoree.dll placement winetricks performs.
    [ -f "$WORK/winetricks" ] || curl -sL -o "$WORK/winetricks" \
        "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
    chmod +x "$WORK/winetricks"
    WINE="$WINE" WINESERVER="$GE_BIN/wineserver" WINEARCH=win32 "$WORK/winetricks" -q dotnet48
    "$GE_BIN/wineserver" -w
    [ -f "$CLR_MARKER" ] || die ".NET 4.8 install failed (no clr.dll) — see winetricks output"

    log "Installing VC++ runtimes (XWAU native libs need them)"
    WINE="$WINE" WINESERVER="$GE_BIN/wineserver" WINEARCH=win32 "$WORK/winetricks" -q vcrun2010 vcrun2012 vcrun2013 vcrun2022 || \
        warn "a vcrun verb failed — continuing; install manually if native DLLs fail to load"
    "$GE_BIN/wineserver" -w

    log "Installing DXVK (from $GE_NAME) + DLL overrides"
    cp "$GE/lib/wine/dxvk/"*.dll "$PREFIX/drive_c/windows/system32/"
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d11" /d native /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d10core" /d native /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d9" /d native /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*d3d8" /d native /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*dxgi" /d native /f
    # XWAU's hook loader lives in game-dir ddraw/dinput (must win over builtins);
    # native WIC crashes the briefing room (keep builtin); mscoree must stay
    # native (real .NET — wine-mono cannot host the CLR hooks).
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "ddraw" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput8" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecs" /d builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecsext" /d builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*mscoree" /d native /f
    # The hooks host CLR v4 from 32-bit DllMain: force the v4-only runtime path.
    "$WINE" reg add "HKLM\\Software\\Microsoft\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f
    "$GE_BIN/wineserver" -w
fi

# ---------------------------------------------------------------- step 6: XWAU payloads
if [ "$SKIP_XWAU" = 1 ] || [ -f "$GAME/Hooks.ini" ]; then
    log "XWAU 2025 already installed (Hooks.ini present)"
else
    [ -n "$XWAU_FULL" ] && [ -f "$XWAU_FULL" ] || die "pass --xwau-full /path/XWAU2025_Full_1.0.0.zip (download from xwaupgrade.com)"
    [ -n "$XWAU_UPD" ] && [ -f "$XWAU_UPD" ] || die "pass --xwau-upd /path/XWAU2025_UPD_1.1.0.zip (download from xwaupgrade.com)"
    log "Unpacking XWAU distribution zips"
    mkdir -p "$WORK/payloads/full" "$WORK/payloads/upd"
    unzip -o -q "$XWAU_FULL" -d "$WORK/payloads/full"
    unzip -o -q "$XWAU_UPD" -d "$WORK/payloads/upd"
    log "Installing XWAU 2025 (payload replay; ratio=$RATIO preset=$PRESET; takes a few minutes)"
    python3 "$SCRIPT_DIR/installer/xwau_payload_install.py" "$GAME" \
        "$PREFIX/drive_c/users/$USER" "$WORK/payloads" --ratio "$RATIO" --preset "$PRESET"
fi

# ---------------------------------------------------------------- step 7: Linux binaries
if [ "$SKIP_BINARIES" = 1 ]; then
    log "Skipping Linux binaries"
else
    log "Installing Linux binaries from xwau-linux release $RELEASE_TAG"
    mkdir -p "$WORK/bin"; cd "$WORK/bin"
    for f in ddraw_effects.dll TGSMUSH.DLL Xwa32bppPlayer32.exe Xwa32bppPlayerNet32.dll hook_keyboard_bg.dll SHA256SUMS.txt; do
        [ -f "$f" ] || curl -L -o "$f" "$RELEASE_BASE/$RELEASE_TAG/$f"
    done
    sha256sum -c SHA256SUMS.txt || die "checksum mismatch on release binaries"
    for f in ddraw_effects.dll TGSMUSH.DLL; do
        tgt="$(find "$GAME" -maxdepth 1 -iname "$f" | head -1)"; tgt="${tgt:-$GAME/$f}"
        [ -f "$tgt" ] && [ ! -f "$tgt.xwau-orig" ] && cp "$tgt" "$tgt.xwau-orig"
        cp "$f" "$tgt"
    done
    # the hooks expect Xwa32bppPlayer.exe; keep upstream's x64 build aside
    if [ -f "$GAME/Xwa32bppPlayer.exe" ] && [ ! -f "$GAME/Xwa32bppPlayer.exe.x64-orig" ]; then
        cp "$GAME/Xwa32bppPlayer.exe" "$GAME/Xwa32bppPlayer.exe.x64-orig"
    fi
    cp Xwa32bppPlayer32.exe "$GAME/Xwa32bppPlayer32.exe"
    cp Xwa32bppPlayer32.exe "$GAME/Xwa32bppPlayer.exe"
    cp Xwa32bppPlayerNet32.dll "$GAME/Xwa32bppPlayerNet32.dll"
    cp hook_keyboard_bg.dll "$GAME/hook_keyboard_bg.dll"
fi

# ---------------------------------------------------------------- step 8: configs
if [ "$SKIP_CONFIGS" = 1 ]; then
    log "Skipping config overlay"
else
    log "Applying Linux config overlay"
    # The concourse pacing key depends on the monitor refresh rate (the
    # game presents briefing/concourse frames in N passes of SyncInterval N
    # = N^2 vblanks; ~25 fps is the intended cadence).
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
                last = i          # end of target section
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
set_key(ddraw, 'HDConcourseEnabled', '1')
# XWAU ships EnableSideProcess=1, but the side players (XwaDDrawPlayer /
# XwaConcoursePlayer) cannot run under wine (D3D11 shared handles) -> error
# popups. The in-process paths (plus the ddraw wine shim) handle everything.
set_key(ddraw, 'EnableSideProcess', '0')
set_key(ddraw, 'TgSmushSwapchainPresentEnabled', '1')
set_key(ddraw, 'TextFontFamily', 'DejaVu Sans')
set_key(ddraw, 'Text2DRendererEnabled', '1')
set_key(ddraw, 'Radar2DRendererEnabled', '1')

hooks = find('Hooks.ini')
set_key(hooks, 'HDConcourseTextFont', 'Liberation Mono', section='hook_concourse')
set_key(hooks, 'EnableSideProcess', '0', section='hook_concourse')
set_key(hooks, 'EnableSideProcess', '1', section='hook_32bpp')
if resolution:
    w, h = resolution.lower().split('x')
    set_key(hooks, 'ResolutionWidth', w, section='hook_resolution')
    set_key(hooks, 'ResolutionHeight', h, section='hook_resolution')

# The High/Ultra presets enable raytracing + HDR. The raytracing BVH
# build at mission entry exhausts the 32-bit address space under wine
# (crash right before the 3D view), so force them off.
ssao = find('SSAO.cfg')
if os.path.exists(ssao):
    set_key(ssao, 'raytracing_enabled', '0')
    set_key(ssao, 'raytracing_enabled_in_tech_room', '0')
    set_key(ssao, 'raytracing_enabled_in_cockpit', '0')
    set_key(ssao, 'HDR_enabled', '0')

vrp = find('VRParams.cfg')
if os.path.exists(vrp):
    set_key(vrp, 'concourse_animations_at_25fps', pace)

tgs = find('TGSmush.cfg')
set_key(tgs, 'ForceBackend', 'mf')
set_key(tgs, 'MFSoftwarePresent', '0')
set_key(tgs, 'MFD3DPresent', '1')

with open(os.path.join(game, 'Xwa32bppPlayer32.cfg'), 'w') as f:
    f.write('SkinsSizeThreshold = 200000000\n')
print('  Xwa32bppPlayer32.cfg written')

with open(os.path.join(game, 'dxvk.conf'), 'a+') as f:
    f.seek(0)
    if 'dxgi.maxFrameRate' not in f.read():
        f.write('\ndxgi.maxFrameRate = 80\n')
        print('  dxvk.conf: dxgi.maxFrameRate = 80 (added)')
PYCFG
fi

# ---------------------------------------------------------------- step 9: launcher
log "Installing launcher"
LAUNCHER="$GAME/xwa-linux-launch.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/bin/bash
# XWAU-on-Linux launcher (generated by install-xwau-linux.sh).
# $GE_NAME provides wine AND the gstreamer/ffmpeg codecs for HD cutscenes.
GE="$GE"
export WINEPREFIX="$PREFIX"
"\$GE/bin/wineserver" -k 2>/dev/null
sleep 1
export WINELOADER="\$GE/bin/wine"
export WINESERVER="\$GE/bin/wineserver"
export PATH="\$GE/bin:\$PATH"
export LD_LIBRARY_PATH="\$GE/lib/i386-linux-gnu:\$GE/lib:\$GE/lib64:\${LD_LIBRARY_PATH:-}"
export GST_PLUGIN_SYSTEM_PATH_1_0="\$GE/lib/gstreamer-1.0:\$GE/lib64/gstreamer-1.0"
export GST_PLUGIN_PATH="\$GST_PLUGIN_SYSTEM_PATH_1_0"
GAME="$GAME"
cd "\$GAME" || exit 1
export WINEDEBUG=-all
# pre-start the 32-bit OPT sideload player (hook_32bpp EnableSideProcess=1)
pkill -f 'Xwa32bppPlayer' 2>/dev/null
"\$GE/bin/wine" "\$GAME/Xwa32bppPlayer32.exe" &
P=\$!
sleep 2
"\$GE/bin/wine" "\$GAME/xwingalliance.exe" > "\$HOME/xwa-linux.log" 2>&1
RC=\$?
kill \$P 2>/dev/null
"\$GE/bin/wineserver" -k 2>/dev/null
exit \$RC
LAUNCHEOF
chmod +x "$LAUNCHER"

# ---------------------------------------------------------------- done
log "Install complete"
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
    * Logs: ~/xwa-linux.log (game), xwa32bpp-player32.log (player, game dir).
EOF
