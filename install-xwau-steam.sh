#!/bin/bash
# install-xwau-steam.sh — STEAM/PROTON win64 installer for X-Wing Alliance + XWAU 2025.
#
# The recommended path for Steam users. Instead of bundling wine, it leans on
# Steam's Proton (>= wine-11), which already provides the whole stack in its
# Steam Linux Runtime container: wine-11, DXVK, libvkd3d, gstreamer codecs, and
# wine-mono. This installer only lays down the game files + config and tells you
# how to point Steam at Proton. The 32-bit game runs under WoW64; hooks run
# in-process (no sidecar); full-res skins; HD concourse + HD video.
#
# Download the XWAU 2025 zips yourself from https://www.xwaupgrade.com/ :
#   XWAU2025_Full_1.0.0.zip and XWAU2025_UPD_1.1.0.zip
#
# Usage:
#   ./install-xwau-steam.sh --xwau-full .../Full.zip --xwau-upd .../UPD.zip \
#                           --bin-dir /path/to/win64/binaries
# Options:
#   --game-dir PATH   game dir (default: auto-detect Steam)
#   --work-dir PATH   scratch dir (default: ~/.cache/xwau-linux-install)
#   --release TAG     win64 binary release to install (default v0.2.0)
#   --bin-dir PATH    local win64 binaries (optional dev override; default: download from --release)
#   --ratio {2,3}     XWAU aspect-ratio finalize (default 2 = 16:9)
#   --preset NAME     veryLow|Low|Medium|High|Ultra (default High)
#   --resolution WxH  force [hook_resolution]
#   --no-steam-config    don't edit Steam's config; just print the manual steps
#   --steam-config-only  (re)apply only the Steam compat tool + launch options, then exit
#                        (use this after closing Steam, if it was running during install)
#   --proton-token NAME  Steam compat-tool id to set (default proton_11)
#   --skip-xwau --skip-binaries --skip-configs   resume helpers
#
# The installer sets the Proton compat tool + Launch Options for you (Steam must be
# CLOSED for that; if it's running it tells you to re-run with --steam-config-only).
# NEVER run Steam "Verify integrity of game files" on a modded install.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/installer/common.sh"

# ---------------------------------------------------------------- defaults
WORK="$HOME/.cache/xwau-linux-install"
STEAM_ROOT="$HOME/.local/share/Steam"
COMPAT_DIR="$STEAM_ROOT/compatibilitytools.d"
RELEASE_TAG="v0.2.0"          # win64 binaries are downloaded from this release
APPID=361670
PROTON_TOKEN="proton_11"      # Steam compat-tool id for Proton 11 (override: --proton-token)
DO_STEAM_CONFIG=1             # auto-set compat tool + launch options (needs Steam closed)
STEAM_CONFIG_ONLY=0          # --steam-config-only: just (re)apply the Steam config + wrapper
GAME="" XWAU_FULL="" XWAU_UPD="" BIN_DIR=""   # --bin-dir = optional local-build override
RATIO="2" PRESET="High" RESOLUTION="" CONCOURSE_PACE=""
SKIP_XWAU=0 SKIP_BINARIES=0 SKIP_CONFIGS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --game-dir) GAME="$2"; shift 2 ;;
        --work-dir) WORK="$2"; shift 2 ;;
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --release) RELEASE_TAG="$2"; shift 2 ;;
        --xwau-full) XWAU_FULL="$2"; shift 2 ;;
        --xwau-upd) XWAU_UPD="$2"; shift 2 ;;
        --ratio) RATIO="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --resolution) RESOLUTION="$2"; shift 2 ;;
        --concourse-pace) CONCOURSE_PACE="$2"; shift 2 ;;
        --steam-root) STEAM_ROOT="$2"; shift 2 ;;
        --proton-token) PROTON_TOKEN="$2"; shift 2 ;;
        --no-steam-config) DO_STEAM_CONFIG=0; shift ;;
        --steam-config-only) STEAM_CONFIG_ONLY=1; shift ;;
        --skip-xwau) SKIP_XWAU=1; shift ;;
        --skip-binaries) SKIP_BINARIES=1; shift ;;
        --skip-configs) SKIP_CONFIGS=1; shift ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done
mkdir -p "$WORK"

# Steam Launch Options the installer sets/prints. WINEDLLOVERRIDES makes the
# game-dir ddraw/dinput hooks load. (We do NOT wrap %command% — intercepting it
# breaks the Proton launch; the first-launch shader wait is explained in text below.)
LAUNCH_OPTS="WINEDLLOVERRIDES=\"ddraw=n,b;dinput=n,b;dinput8=n,b;windowscodecs=b\" %command%"

print_manual_steam_steps() {
    cat <<EOF
  In Steam, X-Wing Alliance -> Properties:
    * Compatibility -> force a Proton >= 11 (Hotfix / Experimental / Proton 11).
    * General -> Launch Options -> paste exactly:

        $LAUNCH_OPTS

    * Launch from Steam.
EOF
}

configure_steam() {
    if [ "$DO_STEAM_CONFIG" != 1 ]; then
        log "Steam config (manual — --no-steam-config)"; print_manual_steam_steps; return 0
    fi
    if pgrep -x steam >/dev/null 2>&1; then
        warn "Steam is running — can't safely edit its config. Close Steam completely, then run:"
        echo "    \"$0\" --steam-config-only"
        print_manual_steam_steps
        return 0
    fi
    log "Configuring Steam (Proton compat tool + launch options) for appid $APPID"
    if python3 "$SCRIPT_DIR/installer/steam_config.py" --steam-root "$STEAM_ROOT" \
         --appid "$APPID" --token "$PROTON_TOKEN" --launch-options "$LAUNCH_OPTS"; then
        echo "    Done. Start Steam and just press Play (Proton + launch options are set)."
    else
        warn "auto-config didn't complete; set it manually:"; print_manual_steam_steps
    fi
}

# --steam-config-only: just (re)apply the Steam config + wrapper, then exit.
if [ "$STEAM_CONFIG_ONLY" = 1 ]; then
    command -v python3 >/dev/null || die "missing 'python3'"
    configure_steam
    exit 0
fi

# ---------------------------------------------------------------- step 1: deps
log "Checking host dependencies"
for t in curl unzip python3; do command -v "$t" >/dev/null || die "missing '$t'"; done
xwau_check_fonts

# ---------------------------------------------------------------- step 2: game dir
if [ -z "$GAME" ]; then
    log "Locating X-Wing Alliance (Steam appid 361670)"
    GAME="$(xwau_locate_game)" || die "could not find the game — install it from Steam, or pass --game-dir"
fi
[ -d "$GAME" ] || die "game dir not found: $GAME"
echo "    game: $GAME"
# library root = the steamapps that contains this game's common/ dir
STEAMAPPS="$(cd "$GAME/../.." && pwd)"          # .../steamapps
COMPATDATA="$STEAMAPPS/compatdata/361670"
PFX="$COMPATDATA/pfx"

# ---------------------------------------------------------------- step 3: Proton >= 11 check
log "Checking for Proton (>= wine-11)"
PROTON_OK=""
for p in "Proton Hotfix" "Proton Experimental" "$STEAMAPPS"/common/Proton\ 1[1-9]* ; do
    pdir="$STEAMAPPS/common/$p"; [ -d "$pdir" ] || pdir="$p"
    [ -d "$pdir" ] || continue
    pv="$("$pdir/files/bin/wine" --version 2>/dev/null || echo "")"
    case "$pv" in wine-1[1-9]*|wine-[2-9][0-9]*) PROTON_OK="$(basename "$pdir") ($pv)"; break ;; esac
done
if [ -n "$PROTON_OK" ]; then
    echo "    found Proton >= 11: $PROTON_OK"
else
    warn "no Proton >= wine-11 found. In Steam, install 'Proton Hotfix' or 'Proton Experimental'"
    warn "(Steam -> Tools, or right-click X-Wing Alliance -> Compatibility). wine-11 is required"
    warn "for HD video + the in-process hooks. You can finish this install and select it after."
fi

# ---------------------------------------------------------------- step 4: Proton prefix (for the payload's %UserProfile%)
if [ ! -d "$PFX/drive_c" ]; then
    cat <<EOF

  The Proton prefix for X-Wing Alliance doesn't exist yet. Create it first:
    1. In Steam: X-Wing Alliance -> Properties -> Compatibility ->
       "Force the use of a specific Steam Play compatibility tool" -> Proton Hotfix
       (or Proton Experimental).
    2. Launch the game once from Steam. It will create the prefix (the game may
       just show a black screen / close — that's fine; we configure it next).
    3. Re-run this installer.

  (Why: the XWAU payload writes some files to the prefix's user profile at
   $PFX/drive_c/users/steamuser.)
EOF
    die "Proton prefix not found at $PFX — see the steps above"
fi
USERPROFILE="$PFX/drive_c/users/steamuser"
[ -d "$USERPROFILE" ] || USERPROFILE="$PFX/drive_c/users/$USER"
echo "    proton prefix: $PFX"

# ---------------------------------------------------------------- step 5: vanilla backup
xwau_vanilla_backup "$GAME"

# ---------------------------------------------------------------- step 6: XWAU payloads
[ "$SKIP_XWAU" = 1 ] || xwau_payload_replay "$SCRIPT_DIR" "$GAME" \
    "$USERPROFILE" "$WORK" "$XWAU_FULL" "$XWAU_UPD" "$RATIO" "$PRESET"

# ---------------------------------------------------------------- step 7: binaries
[ "$SKIP_BINARIES" = 1 ] || xwau_install_binaries "$GAME" "$BIN_DIR" "$RELEASE_TAG" "$WORK"

# ---------------------------------------------------------------- step 8: config
[ "$SKIP_CONFIGS" = 1 ] || xwau_config_overlay "$GAME" "$RESOLUTION" "$CONCOURSE_PACE"

# ---------------------------------------------------------------- step 9: configure Steam
configure_steam

# ---------------------------------------------------------------- done
log "Install complete (win64 via Steam Proton)"
cat <<EOF

  Launch X-Wing Alliance from Steam. (Proton supplies wine-mono + DXVK + libvkd3d
  + codecs in its container; the launch-options overrides load the game-dir
  ddraw/dinput hooks. No bundled wine.)

  NOTES:
    * BE PATIENT ON THE FIRST LAUNCH: it builds the DXVK shader cache, so it can
      take a few minutes and may look frozen or open extra "side-loader" windows
      (the XWAU launcher's helper processes — harmless). Later launches are fast.
    * NEVER use Steam "Verify integrity of game files". Restore: $GAME.vanilla
    * If the menu renders half-size, re-run with --resolution (e.g.
      --resolution 1920x1080 --skip-xwau --skip-binaries).
    * Proton log for debugging: add PROTON_LOG=1 to Launch Options (writes ~/steam-361670.log).
EOF
