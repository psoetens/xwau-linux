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
#   --game-dir PATH    game dir (the dir you innoextract'd the offline installer into)
#   --prefix PATH      wine prefix (default: ~/.local/share/xwa-prefix-w64)
#   --work-dir PATH    scratch dir (default: ~/.cache/xwau-linux-install)
#   --wine-version V   Kron4ek wine version to fetch (default: 11.11)
#   --wine-dir PATH    use an existing wine-11 build instead of downloading Kron4ek
#   --runtime NAME     wine-mono (default) | dotnet48
#   --release TAG      win64 binary release to install (default v0.4.3)
#   --bin-dir PATH     local win64 binaries (optional dev override; default: download from --release)
#   --ratio {2,3}      XWAU aspect-ratio finalize (default 2 = 16:9)
#   --preset NAME      veryLow|Low|Medium|High|Ultra (default High; no VA ceiling on win64)
#   --resolution WxH   force [hook_resolution]
#   --skip-prefix --skip-xwau --skip-binaries --skip-configs   resume helpers
#   --skip-codec-check     don't abort when the host lacks the 32-bit HD-cutscene
#                          libs (install anyway; cutscenes play audio-only)
#   --remove          restore the original (vanilla) game, then exit
#   --reinstall       --remove, then reinstall using THIS dir's version; reuses the XWAU
#                     zip paths recorded at first install (pass --xwau-full/--xwau-upd to override)

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
RELEASE_TAG="v0.4.3"                   # win64 binaries downloaded from this release
BIN_DIR=""                            # --bin-dir = optional local-build override
PREFIX="$HOME/.local/share/xwa-prefix-w64"
WORK="$HOME/.cache/xwau-linux-install"
COMPAT_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
GAME="" XWAU_FULL="" XWAU_UPD=""
RATIO="" PRESET="" RESOLUTION="" CONCOURSE_PACE=""   # empty = default (or manifest, on --reinstall)
SKIP_PREFIX=0 SKIP_XWAU=0 SKIP_BINARIES=0 SKIP_CONFIGS=0 SKIP_CODEC_CHECK=0
REMOVE=0 REINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        --work-dir) WORK="$2"; shift 2 ;;
        --wine-version) WINE_VERSION="$2"; shift 2 ;;
        --wine-dir) WINE_DIR="$2"; shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --release) RELEASE_TAG="$2"; shift 2 ;;
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
        --skip-codec-check) SKIP_CODEC_CHECK=1; shift ;;
        --remove) REMOVE=1; shift ;;
        --reinstall) REINSTALL=1; shift ;;
        -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done
case "$RUNTIME" in wine-mono|dotnet48) ;; *) die "bad --runtime: $RUNTIME" ;; esac

# ---------------------------------------------------------------- validate args (fail fast)
# Verify up front that every path passed as an argument exists, so a typo/missing
# file fails now instead of mid-install (after the slow prefix build + downloads).
if [ -n "$GAME" ]     && [ ! -d "$GAME" ];              then die "--game-dir not found: $GAME"; fi
if [ -n "$WINE_DIR" ] && [ ! -x "$WINE_DIR/bin/wine" ]; then die "--wine-dir has no bin/wine executable: $WINE_DIR"; fi
if [ -n "$BIN_DIR" ]  && [ ! -d "$BIN_DIR" ];           then die "--bin-dir not found: $BIN_DIR"; fi
# --remove needs no zips; --reinstall gets them from the manifest (checked later).
if [ "$SKIP_XWAU" != 1 ] && [ "$REMOVE" != 1 ] && [ "$REINSTALL" != 1 ]; then
    [ -n "$XWAU_FULL" ] || die "--xwau-full is required (or pass --skip-xwau) — download the XWAU 2025 zips from https://www.xwaupgrade.com/"
    [ -n "$XWAU_UPD" ]  || die "--xwau-upd is required (or pass --skip-xwau)"
    [ -f "$XWAU_FULL" ] || die "--xwau-full not found: $XWAU_FULL"
    [ -f "$XWAU_UPD" ]  || die "--xwau-upd not found: $XWAU_UPD"
fi

mkdir -p "$WORK"

# ---------------------------------------------------------------- step 1: deps
log "Checking host dependencies"
NEED="curl tar unzip python3 sha256sum sha512sum"
[ "$RUNTIME" = dotnet48 ] && NEED="$NEED cabextract"
for t in $NEED; do command -v "$t" >/dev/null || die "missing '$t'"; done
xwau_check_fonts

# ---------------------------------------------------------------- step 2: game dir
if [ -z "$GAME" ]; then
    log "Locating X-Wing Alliance"
    GAME="$(xwau_locate_game)" || die "could not find the game — pass --game-dir (GOG: innoextract the offline installer first; see README)"
fi
[ -d "$GAME" ] || die "game dir not found: $GAME"
echo "    game: $GAME"

# ------------------------------------------------------- step 2a: remove / reinstall
# --reinstall reuses the options recorded at first install; read the manifest NOW,
# before the remove wipes it. Explicit CLI args override the manifest.
if [ "$REINSTALL" = 1 ]; then
    if xwau_load_manifest "$GAME"; then
        [ -n "$XWAU_FULL" ]      || XWAU_FULL="$MF_XWAU_FULL"
        [ -n "$XWAU_UPD" ]       || XWAU_UPD="$MF_XWAU_UPD"
        [ -n "$RATIO" ]          || RATIO="$MF_RATIO"
        [ -n "$PRESET" ]         || PRESET="$MF_PRESET"
        [ -n "$RESOLUTION" ]     || RESOLUTION="$MF_RESOLUTION"
        [ -n "$CONCOURSE_PACE" ] || CONCOURSE_PACE="$MF_CONCOURSE_PACE"
        echo "    reusing manifest (previously installed release: ${MF_RELEASE_TAG:-?})"
    else
        warn "no install manifest at $GAME/.xwau-install.json — pass --xwau-full/--xwau-upd"
    fi
    if [ "$SKIP_XWAU" != 1 ]; then
        [ -n "$XWAU_FULL" ] && [ -f "$XWAU_FULL" ] || die "reinstall: XWAU Full zip not found: ${XWAU_FULL:-<unset>} (pass --xwau-full)"
        [ -n "$XWAU_UPD" ]  && [ -f "$XWAU_UPD" ]  || die "reinstall: XWAU UPD zip not found: ${XWAU_UPD:-<unset>} (pass --xwau-upd)"
    fi
fi
if [ "$REMOVE" = 1 ] || [ "$REINSTALL" = 1 ]; then
    log "Removing XWAU install (restoring vanilla game files)"
    xwau_remove_gamefiles "$GAME"
    if [ "$REMOVE" = 1 ]; then
        rm -rf "$GAME.vanilla"
        log "Removed — X-Wing Alliance restored to vanilla and the mod uninstalled."
        echo "    (removed backup $GAME.vanilla; wine prefix at $PREFIX left in place — delete it to fully reset.)"
        exit 0
    fi
    log "Reinstalling from this directory (release $RELEASE_TAG)"
fi
# hard defaults for anything not set by an arg or the manifest
RATIO="${RATIO:-2}"; PRESET="${PRESET:-High}"

# ------------------------------------------------------- step 2b: codec preflight (fail early)
# Verify the host has the 32-bit userland GE's HD-cutscene codecs need BEFORE the
# ~500 MB GE/wine downloads and the slow prefix build — so a multilib gap is a
# 10-second "run this one command" stop, not a discovery after a long install.
# GE-independent (probes the loader cache, not GE's plugins). --skip-codec-check
# turns the abort into a warning for anyone who wants an audio-only install.
xwau_codec_preflight "$SKIP_CODEC_CHECK"

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

    log "Installing DXVK + vkd3d (from $GE_NAME donor) + DLL overrides"
    # GE keeps the DXVK PE DLLs in dxvk/{i386,x86_64}-windows subdirs (NOT flat in
    # dxvk/, and not under lib64/), and libvkd3d in its default_pfx. The 32-bit
    # WoW64 game needs the 32-bit set in syswow64; the 64-bit set goes to system32.
    # Without DXVK (dxgi/d3d11) AND libvkd3d (wine's d2d1 shader backend),
    # dxgi->d3d10_1->d2d1 fail to load -> DDraw_Effects/hook_concourse can't load
    # -> 0xC0000005 null-call crash at launch. See reports/win64-clr-hosting-fix.md.
    SYSW="$PREFIX/drive_c/windows/syswow64"
    SYS32="$PREFIX/drive_c/windows/system32"
    if [ -d "$GE/lib/wine/dxvk/i386-windows" ]; then
        cp -f "$GE/lib/wine/dxvk/i386-windows/"*.dll "$SYSW/" 2>/dev/null || true
    else
        warn "DXVK i386 dir not found under $GE/lib/wine/dxvk — check GE-Proton layout"
    fi
    [ -d "$GE/lib/wine/dxvk/x86_64-windows" ] && \
        cp -f "$GE/lib/wine/dxvk/x86_64-windows/"*.dll "$SYS32/" 2>/dev/null || true
    # libvkd3d: 32-bit -> syswow64, 64-bit -> system32 (prefer default_pfx, then lib/vkd3d)
    GEPFX="$GE/share/default_pfx/drive_c/windows"
    for d in libvkd3d-1.dll libvkd3d-shader-1.dll; do
        s32="$GEPFX/syswow64/$d"; [ -f "$s32" ] || s32="$GE/lib/vkd3d/i386-windows/$d"
        s64="$GEPFX/system32/$d"; [ -f "$s64" ] || s64="$GE/lib/vkd3d/x86_64-windows/$d"
        [ -f "$s32" ] && cp -f "$s32" "$SYSW/$d" || true
        [ -f "$s64" ] && cp -f "$s64" "$SYS32/$d" || true
    done
    # sanity: the 32-bit pieces the game actually loads at launch
    for d in dxgi.dll d3d11.dll libvkd3d-shader-1.dll; do
        [ -f "$SYSW/$d" ] || warn "$d missing in syswow64 after DXVK/vkd3d install — HD concourse/effects will fail"
    done
    for o in "*d3d11" "*d3d10core" "*d3d9" "*d3d8" "*dxgi"; do
        "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "$o" /d native /f
    done
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "ddraw" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "dinput8" /d native,builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecs" /d builtin /f
    "$WINE" reg add "HKCU\\Software\\Wine\\DllOverrides" /v "*windowscodecsext" /d builtin /f
    # The XWAU launcher (alliance.exe) is a WPF app; WPF renders via Direct3D and can
    # show a BLACK window under wine on some GPU/DPI combos (users otherwise have to
    # set wine DPI to 120 to work around it). Force WPF SOFTWARE rendering so the
    # launcher menu renders reliably. Runtime-independent; harmless on Windows.
    "$WINE" reg add "HKCU\\Software\\Microsoft\\Avalon.Graphics" /v DisableHWAcceleration /t REG_DWORD /d 1 /f
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
[ "$SKIP_BINARIES" = 1 ] || xwau_install_binaries "$GAME" "$BIN_DIR" "$RELEASE_TAG" "$WORK"

# ---------------------------------------------------------------- step 9: config
[ "$SKIP_CONFIGS" = 1 ] || xwau_config_overlay "$GAME" "$RESOLUTION" "$CONCOURSE_PACE"

# ---------------------------------------------------------------- step 9b: 32-bit codec libs
# GE's 32-bit HD .mp4 cutscene decoder needs two 32-bit "soname-trap" leaves GE
# ships neither of, staged into a game-local dir the launcher adds to
# LD_LIBRARY_PATH (without them decodebin can't build -> black cutscenes):
#   libvpx.so.6    — no current distro ships the .so.6 soname (all moved past it)
#   libbz2.so.1.0  — Fedora patches bzip2's soname to libbz2.so.1 (Debian keeps
#                    .so.1.0), so on Fedora we stage its ABI-identical libbz2.so.1
# The by-name host libs (glib/libva/libX11/...) were already gated in step 2b.
LIB32="$GAME/.linux-lib32"
mkdir -p "$LIB32"
xwau_stage_leaf "$LIB32" "libvpx.so.6"   "$RELEASE_TAG" || true
xwau_stage_leaf "$LIB32" "libbz2.so.1.0" "$RELEASE_TAG" \
    libbz2.so.1 libbz2.so.1.0.8 libbz2.so.1.0.6 libbz2.so.1.0.4 || true

# ---------------------------------------------------------------- step 10: launcher
log "Installing launcher (win64 standalone; no sidecar)"
LAUNCHER="$GAME/xwa-linux-launch.sh"
cat > "$LAUNCHER" <<LAUNCHEOF
#!/bin/bash
# XWAU-on-Linux launcher (win64 standalone, Kron4ek wine + GE codec donor).
WINE_DIR="$WINE_DIR"
GE="$GE"
GAME="$GAME"
export WINEPREFIX="$PREFIX"
"\$WINE_DIR/bin/wineserver" -k 2>/dev/null; sleep 1
export WINELOADER="\$WINE_DIR/bin/wine" WINESERVER="\$WINE_DIR/bin/wineserver"
export PATH="\$WINE_DIR/bin:\$PATH"
# HD .mp4 cutscenes go through Media Foundation -> winegstreamer. The game is
# 32-bit (WoW64), so use GE's 32-bit gstreamer plugins + GE's 32-bit codec libs,
# plus the game-local libvpx.so.6 (GE ships no 32-bit libvpx). Kron4ek ships no
# codecs, hence the GE donor.
export GST_PLUGIN_SYSTEM_PATH_1_0="\$GE/lib/i386-linux-gnu/gstreamer-1.0"
export GST_PLUGIN_PATH="\$GST_PLUGIN_SYSTEM_PATH_1_0"
export LD_LIBRARY_PATH="\$GAME/.linux-lib32:\$GE/lib/i386-linux-gnu:\${LD_LIBRARY_PATH:-}"
cd "\$GAME" || exit 1
export WINEDEBUG=-all
"\$WINE_DIR/bin/wine" "\$GAME/xwingalliance.exe" > "\$HOME/xwa-linux.log" 2>&1
RC=\$?
"\$WINE_DIR/bin/wineserver" -k 2>/dev/null
exit \$RC
LAUNCHEOF
chmod +x "$LAUNCHER"

# ---------------------------------------------------------------- step 11: video codec self-check
# Resolve the 32-bit cutscene decode plugins exactly as the launcher will, and
# report any missing dep LOUDLY now — so a gap surfaces here, not as silent black
# cutscenes for the user.
log "Checking 32-bit video codec deps (HD cutscenes)"
_gst32="$GE/lib/i386-linux-gnu/gstreamer-1.0"
_vid_missing=0
for p in libgstlibav libgstisomp4 libgstvideoparsersbad; do
    _so="$_gst32/$p.so"
    if [ ! -f "$_so" ]; then
        warn "video: $p.so not found in GE donor ($_gst32)"; _vid_missing=1; continue
    fi
    _miss=$(LD_LIBRARY_PATH="$GAME/.linux-lib32:$GE/lib/i386-linux-gnu" ldd "$_so" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')
    if [ -n "$_miss" ]; then
        warn "video: $p.so is missing 32-bit dep(s): $_miss"; _vid_missing=1
    fi
done
if [ "$_vid_missing" = 1 ]; then
    warn "HD cutscenes will be BLACK (audio only) until the missing 32-bit lib(s) above are placed in $GAME/.linux-lib32/"
else
    echo "    video codec deps OK (mp4/h264/aac)"
fi

# install manifest (for --reinstall)
_MF_FULL="$XWAU_FULL"; [ -n "$_MF_FULL" ] && _MF_FULL="$(readlink -f "$_MF_FULL" 2>/dev/null || echo "$_MF_FULL")"
_MF_UPD="$XWAU_UPD";   [ -n "$_MF_UPD" ]  && _MF_UPD="$(readlink -f "$_MF_UPD" 2>/dev/null || echo "$_MF_UPD")"
xwau_write_manifest "$GAME" variant=standalone release_tag="$RELEASE_TAG" \
    xwau_full="$_MF_FULL" xwau_upd="$_MF_UPD" ratio="$RATIO" preset="$PRESET" \
    resolution="$RESOLUTION" concourse_pace="$CONCOURSE_PACE" \
    installed_at="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"

log "Install complete (standalone: Kron4ek wine-$WINE_VERSION + $RUNTIME)"
cat <<EOF

  Launch the game with:

    $LAUNCHER

  IMPORTANT:
    * A pristine backup of the game dir (restore point) is kept at: $GAME.vanilla
    * If the menu renders half-size, re-run with --resolution (e.g.
      --resolution 1920x1080 --skip-prefix --skip-xwau --skip-binaries).
    * Log: ~/xwa-linux.log
EOF
