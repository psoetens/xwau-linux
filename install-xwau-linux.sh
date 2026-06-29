#!/bin/bash
# install-xwau-linux.sh — STANDALONE win64 installer for X-Wing Alliance + XWAU 2025.
#
# For users NOT going through Steam's Proton. Bundles its own wine-11 (Kron4ek) +
# wine-mono, and uses a GE-Proton as the DXVK + gstreamer-codec donor. The 32-bit
# game runs under WoW64 in a win64 prefix; hooks run in-process (no sidecar);
# full-res skins; HD concourse + HD video.
#
# (Steam users: prefer ./install-xwau-steam.sh — it uses Steam's Proton, which
#  already provides wine-11 + DXVK + libvkd3d + codecs + wine-mono in its container.)
#
# Download the XWAU 2025 zips yourself from https://www.xwaupgrade.com/ :
#   XWAU2025_Full_1.0.0.zip and XWAU2025_UPD_1.1.0.zip
#
# Usage:
#   ./install-xwau-linux.sh --xwau-full .../Full.zip --xwau-upd .../UPD.zip \
#                           --bin-dir /path/to/win64/binaries
# Options:
#   --game-dir PATH    game dir (default: auto-detect Steam)
#   --prefix PATH      wine prefix (default: ~/.local/share/xwa-prefix-w64)
#   --work-dir PATH    scratch dir (default: ~/.cache/xwau-linux-install)
#   --wine-version V   Kron4ek wine version to fetch (default: 11.11)
#   --wine-dir PATH    use an existing wine-11 build instead of downloading Kron4ek
#   --runtime NAME     wine-mono (default) | dotnet48
#   --bin-dir PATH     dir with the win64 binaries (no win64 release yet)
#   --ratio {2,3}      XWAU aspect-ratio finalize (default 2 = 16:9)
#   --preset NAME      veryLow|Low|Medium|High|Ultra (default High; no VA ceiling on win64)
#   --resolution WxH   force [hook_resolution]
#   --skip-prefix --skip-xwau --skip-binaries --skip-configs   resume helpers
#
# NEVER run Steam "Verify integrity of game files" on a modded install.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/installer/common.sh"

# ---------------------------------------------------------------- defaults
WINE_VERSION="11.11"                  # Kron4ek wine to download
WINE_DIR=""                           # set by download unless --wine-dir
RUNTIME="wine-mono"                   # wine-mono | dotnet48
MONO_MSI_VER="11.1.0"                 # wine-mono version (madewokherd/wine-mono)
GE_NAME="GE-Proton10-34"              # DXVK + gstreamer-codec donor
GE_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_NAME}/${GE_NAME}.tar.gz"
BIN_DIR=""
PREFIX="$HOME/.local/share/xwa-prefix-w64"
WORK="$HOME/.cache/xwau-linux-install"
COMPAT_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
GAME="" XWAU_FULL="" XWAU_UPD=""
RATIO="2" PRESET="High" RESOLUTION="" CONCOURSE_PACE=""
SKIP_PREFIX=0 SKIP_XWAU=0 SKIP_BINARIES=0 SKIP_CONFIGS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --work-dir) WORK="$2"; shift 2 ;;
        --wine-version) WINE_VERSION="$2"; shift 2 ;;
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
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done
case "$RUNTIME" in wine-mono|dotnet48) ;; *) die "bad --runtime: $RUNTIME" ;; esac
mkdir -p "$WORK"

# ---------------------------------------------------------------- step 1: deps
log "Checking host dependencies"
NEED="curl tar unzip python3 sha256sum sha512sum"
[ "$RUNTIME" = dotnet48 ] && NEED="$NEED cabextract"
for t in $NEED; do command -v "$t" >/dev/null || die "missing '$t'"; done
xwau_check_fonts

# ---------------------------------------------------------------- step 2: game dir
if [ -z "$GAME" ]; then
    log "Locating X-Wing Alliance (Steam appid 361670)"
    GAME="$(xwau_locate_game)" || die "could not find the game — install it from Steam, or pass --game-dir"
fi
[ -d "$GAME" ] || die "game dir not found: $GAME"
echo "    game: $GAME"

# ---------------------------------------------------------------- step 3: GE donor (DXVK + codecs)
GE="$COMPAT_DIR/$GE_NAME/files"
if [ -d "$GE/lib/wine/dxvk" ]; then
    log "DXVK/codec donor present: $GE_NAME"
else
    # reuse any GE-Proton already installed as the donor before downloading
    EXIST="$(ls -d "$COMPAT_DIR"/GE-Proton*/files 2>/dev/null | head -1 || true)"
    if [ -n "$EXIST" ] && [ -d "$EXIST/lib/wine/dxvk" ]; then
        GE="$EXIST"; log "Using existing GE-Proton as DXVK/codec donor: $GE"
    else
        log "Downloading $GE_NAME (DXVK + gstreamer codec donor, ~430 MB)"
        cd "$WORK"
        [ -f "$GE_NAME.tar.gz" ] || curl -L -o "$GE_NAME.tar.gz" "$GE_URL"
        curl -sL -o "$GE_NAME.sha512sum" "${GE_URL%.tar.gz}.sha512sum" || true
        [ -f "$GE_NAME.sha512sum" ] && sha512sum -c "$GE_NAME.sha512sum" || warn "no GE checksum — continuing"
        mkdir -p "$COMPAT_DIR"; tar -xf "$GE_NAME.tar.gz" -C "$COMPAT_DIR"
        GE="$COMPAT_DIR/$GE_NAME/files"
        [ -d "$GE/lib/wine/dxvk" ] || die "GE extraction failed"
    fi
fi

# ---------------------------------------------------------------- step 4: Kron4ek wine-11
if [ -z "$WINE_DIR" ]; then
    WINE_DIR="$HOME/.local/opt/wine-${WINE_VERSION}-amd64"
    if [ -x "$WINE_DIR/bin/wine" ]; then
        log "Kron4ek wine-$WINE_VERSION already present: $WINE_DIR"
    else
        log "Downloading Kron4ek wine-$WINE_VERSION-amd64"
        cd "$WORK"
        TB="wine-${WINE_VERSION}-amd64.tar.xz"
        BASE="https://github.com/Kron4ek/Wine-Builds/releases/download/${WINE_VERSION}"
        [ -f "$TB" ] || curl -L -o "$TB" "$BASE/$TB"
        curl -sL -o sha256sums.txt "$BASE/sha256sums.txt" || true
        if [ -f sha256sums.txt ]; then
            /usr/bin/grep " $TB\$" sha256sums.txt | sha256sum -c - || die "checksum mismatch on $TB"
        else
            warn "no Kron4ek checksum — continuing"
        fi
        mkdir -p "$HOME/.local/opt"; tar -xf "$TB" -C "$HOME/.local/opt"
        [ -x "$WINE_DIR/bin/wine" ] || die "Kron4ek extraction failed: $WINE_DIR/bin/wine missing"
    fi
fi
WINE="$WINE_DIR/bin/wine"; WINESERVER_BIN="$WINE_DIR/bin/wineserver"
WVER="$("$WINE" --version 2>/dev/null || echo unknown)"
case "$WVER" in wine-1[1-9]*|wine-[2-9][0-9]*) echo "    wine: $WVER" ;; *) die "need wine-11+ (got '$WVER')" ;; esac

# ---------------------------------------------------------------- step 5: vanilla backup
xwau_vanilla_backup "$GAME"

# ---------------------------------------------------------------- step 6: win64 prefix
export WINEPREFIX="$PREFIX" WINEDEBUG=-all
export WINELOADER="$WINE" WINESERVER="$WINESERVER_BIN"
CLR_MARKER="$PREFIX/drive_c/windows/Microsoft.NET/Framework/v4.0.30319/clr.dll"
MONO_MARKER="$PREFIX/drive_c/windows/mono/mono-2.0/bin/libmono-2.0-x86.dll"
DONE_MARKER="$MONO_MARKER"; [ "$RUNTIME" = dotnet48 ] && DONE_MARKER="$CLR_MARKER"

if [ "$SKIP_PREFIX" = 1 ] || [ -f "$DONE_MARKER" ]; then
    log "win64 prefix ($RUNTIME) already present: $PREFIX"
else
    log "Creating WIN64 wine prefix at $PREFIX (runtime: $RUNTIME)"
    [ -d "$PREFIX" ] && die "prefix exists but looks incomplete — remove it or pass a different --prefix"
    WINEARCH=win64 "$WINE" wineboot -i; "$WINESERVER_BIN" -w

    if [ "$RUNTIME" = wine-mono ]; then
        log "Installing wine-mono $MONO_MSI_VER"
        MONO_MSI="$HOME/.cache/wine/wine-mono-${MONO_MSI_VER}-x86.msi"
        if [ ! -f "$MONO_MSI" ]; then
            mkdir -p "$(dirname "$MONO_MSI")"
            curl -L -o "$MONO_MSI" \
              "https://github.com/madewokherd/wine-mono/releases/download/wine-mono-${MONO_MSI_VER}/wine-mono-${MONO_MSI_VER}-x86.msi"
        fi
        "$WINE" msiexec /i "$MONO_MSI"; "$WINESERVER_BIN" -w
        [ -f "$MONO_MARKER" ] || warn "wine-mono marker missing after install — verify the prefix"
    else
        log "Installing .NET Framework 4.8 (winetricks; 10-20 min)"
        [ -f "$WORK/winetricks" ] || curl -sL -o "$WORK/winetricks" \
            "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
        chmod +x "$WORK/winetricks"
        WINE="$WINE" WINESERVER="$WINESERVER_BIN" "$WORK/winetricks" -q dotnet48; "$WINESERVER_BIN" -w
        [ -f "$CLR_MARKER" ] || die ".NET 4.8 install failed"
    fi

    log "Installing DXVK (from $GE_NAME donor) + DLL overrides"
    # 32-bit DXVK for the WoW64 game -> syswow64; 64-bit -> system32
    cp "$GE/lib/wine/dxvk/"*.dll "$PREFIX/drive_c/windows/syswow64/" 2>/dev/null || true
    [ -d "$GE/lib64/wine/dxvk" ] && cp "$GE/lib64/wine/dxvk/"*.dll "$PREFIX/drive_c/windows/system32/" 2>/dev/null || true
    for o in "*d3d11" "*d3d10core" "*d3d9" "*d3d8" "*dxgi"; do
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "$o" /d native /f
    done
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "ddraw" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput8" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecs" /d builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecsext" /d builtin /f
    if [ "$RUNTIME" = dotnet48 ]; then
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*mscoree" /d native /f
        "$WINE" reg add "HKLM\\Software\\Microsoft\\.NETFramework" /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f
    fi
    "$WINESERVER_BIN" -w
fi

# ---------------------------------------------------------------- step 7: XWAU payloads
[ "$SKIP_XWAU" = 1 ] || xwau_payload_replay "$SCRIPT_DIR" "$GAME" \
    "$PREFIX/drive_c/users/$USER" "$WORK" "$XWAU_FULL" "$XWAU_UPD" "$RATIO" "$PRESET"

# ---------------------------------------------------------------- step 8: binaries
[ "$SKIP_BINARIES" = 1 ] || xwau_install_binaries "$GAME" "$BIN_DIR"

# ---------------------------------------------------------------- step 9: config
[ "$SKIP_CONFIGS" = 1 ] || xwau_config_overlay "$GAME" "$RESOLUTION" "$CONCOURSE_PACE"

# ---------------------------------------------------------------- step 10: launcher
log "Installing launcher (win64 standalone; no sidecar)"
LAUNCHER="$GAME/xwa-linux-launch.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/bin/bash
# XWAU-on-Linux launcher (win64 standalone, Kron4ek wine + GE codec donor).
WINE_DIR="$WINE_DIR"
GE="$GE"
export WINEPREFIX="$PREFIX"
"\$WINE_DIR/bin/wineserver" -k 2>/dev/null; sleep 1
export WINELOADER="\$WINE_DIR/bin/wine" WINESERVER="\$WINE_DIR/bin/wineserver"
export PATH="\$WINE_DIR/bin:\$PATH"
# HD .mp4 cutscenes go through Media Foundation -> winegstreamer; point it at GE's
# gstreamer plugins (libav/h264) since Kron4ek wine ships no codecs.
export GST_PLUGIN_SYSTEM_PATH_1_0="\$GE/lib/gstreamer-1.0:\$GE/lib64/gstreamer-1.0"
export GST_PLUGIN_PATH="\$GST_PLUGIN_SYSTEM_PATH_1_0"
GAME="$GAME"; cd "\$GAME" || exit 1
export WINEDEBUG=-all
"\$WINE_DIR/bin/wine" "\$GAME/xwingalliance.exe" > "\$HOME/xwa-linux.log" 2>&1
RC=\$?
"\$WINE_DIR/bin/wineserver" -k 2>/dev/null
exit \$RC
LAUNCHEOF
chmod +x "$LAUNCHER"

log "Install complete (win64 standalone: Kron4ek wine-$WINE_VERSION + $RUNTIME)"
cat <<EOF

  Steam Launch Options (X-Wing Alliance -> Properties -> Launch Options):

    bash -c 'exec "$LAUNCHER"' %command%

  IMPORTANT:
    * NEVER use Steam "Verify integrity of game files". Restore: $GAME.vanilla
    * If the menu renders half-size, re-run with --resolution (e.g.
      --resolution 1920x1080 --skip-prefix --skip-xwau --skip-binaries).
    * Log: ~/xwa-linux.log
EOF
