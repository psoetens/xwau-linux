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
#   --release TAG     win64 binary release to install (default v0.5.1)
#   --bin-dir PATH    local win64 binaries (optional dev override; default: download from --release)
#   --ratio {2,3}     XWAU aspect-ratio finalize (default 2 = 16:9)
#   --preset NAME     veryLow|Low|Medium|High|Ultra (default High)
#   --resolution WxH  force [hook_resolution]
#   --no-steam-config    don't touch Steam's config (compat tool + launch options);
#                        print the manual steps instead. Also lets the install run
#                        with Steam open (otherwise it aborts until Steam is closed).
#   --steam-config-only  (re)apply only the Steam compat tool + launch options, then exit
#                        (use this after closing Steam, if it was running during install)
#   --proton-token NAME  Steam compat-tool id to set (default proton_11)
#   --skip-xwau --skip-binaries --skip-configs   resume helpers
#   --remove          restore the original (vanilla) game + clear our Steam config, then exit
#   --reinstall       --remove, then reinstall using THIS dir's version; reuses the XWAU
#                     zip paths recorded at first install (pass --xwau-full/--xwau-upd to override)
#
# The installer sets the Proton compat tool + Launch Options for you (Steam must be
# CLOSED for that; if it's running the install aborts until you close it, or pass
# --no-steam-config). NEVER run Steam "Verify integrity of game files" on a modded install.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/installer/common.sh"

# ---------------------------------------------------------------- defaults
WORK="$HOME/.cache/xwau-linux-install"
STEAM_ROOT="$HOME/.local/share/Steam"
COMPAT_DIR="$STEAM_ROOT/compatibilitytools.d"
WRAP="$HOME/.local/share/xwau-linux/xwa-steam-run.sh"   # host launch wrapper (silences GNOME not-responding dialog during shader compile)
RELEASE_TAG="v0.5.1"          # win64 binaries are downloaded from this release
APPID=361670
PROTON_TOKEN="proton_11"      # Steam compat-tool id for Proton 11 (override: --proton-token)
DO_STEAM_CONFIG=1             # auto-set compat tool + launch options (needs Steam closed)
STEAM_CONFIG_ONLY=0          # --steam-config-only: just (re)apply the Steam config + wrapper
GAME="" XWAU_FULL="" XWAU_UPD="" BIN_DIR=""   # --bin-dir = optional local-build override
RATIO="" PRESET="" RESOLUTION="" CONCOURSE_PACE=""   # empty = default (or manifest, on --reinstall)
SKIP_XWAU=0 SKIP_BINARIES=0 SKIP_CONFIGS=0
REMOVE=0 REINSTALL=0

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
        --remove) REMOVE=1; shift ;;
        --reinstall) REINSTALL=1; shift ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)"; exit 2 ;;
    esac
done
mkdir -p "$WORK"

# Editing Steam's config requires Steam FULLY CLOSED (it rewrites config.vdf /
# localconfig.vdf on exit). Abort up front rather than doing a partial install and
# deferring config to a second run. --no-steam-config skips all Steam-config edits
# (you set the compat tool + launch options in Steam yourself) and lifts this.
if [ "$DO_STEAM_CONFIG" = 1 ] && pgrep -x steam >/dev/null 2>&1; then
    die "Steam is running — close it completely and re-run, or pass --no-steam-config to install without changing Steam's config."
fi

# Steam Launch Options the installer sets/prints. WINEDLLOVERRIDES makes the
# game-dir ddraw/dinput hooks load. The xwa-steam-run.sh prefix runs on the host
# (outside the Proton container) and silences GNOME's "not responding" dialog for
# the duration of the game — first-launch DXVK shader compile briefly hangs the
# window. (We do NOT wrap %command% itself; the prefix just brackets it.)
LAUNCH_OPTS="WINEDLLOVERRIDES=\"ddraw=n,b;dinput=n,b;dinput8=n,b;windowscodecs=b\" \"$WRAP\" %command%"

print_manual_steam_steps() {
    cat <<EOF
  In Steam, X-Wing Alliance -> Properties:
    * Compatibility -> force a Proton >= 11 (Hotfix / Experimental / Proton 11).
    * General -> Launch Options -> paste exactly:

        $LAUNCH_OPTS

    * Launch from Steam.
EOF
}

ensure_wrap() {  # install the host launch wrapper that LAUNCH_OPTS points at
    mkdir -p "$(dirname "$WRAP")"
    if cp -f "$SCRIPT_DIR/installer/xwa-steam-run.sh" "$WRAP" 2>/dev/null; then
        chmod +x "$WRAP"
    else
        warn "couldn't install launch wrapper at $WRAP — GNOME's not-responding dialog won't be auto-silenced"
    fi
}

configure_steam() {
    ensure_wrap
    if [ "$DO_STEAM_CONFIG" != 1 ]; then
        log "Steam config (manual — --no-steam-config)"; print_manual_steam_steps; return 0
    fi
    # Steam is guaranteed closed here (the early guard aborts otherwise).
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
    if [ "$REINSTALL" = 1 ] || [ "$REMOVE" = 1 ]; then
        # Reuse the Steam dir recorded at install (a machine may also have a
        # GOG/standalone install — pick the steam-variant one, not that).
        GAME="$(xwau_resolve_reinstall_dir "" steam)" || die "pass --game-dir to choose which install"
    else
        log "Locating X-Wing Alliance (Steam appid 361670)"
        GAME="$(xwau_locate_game)" || die "could not find the game — install it from Steam, or pass --game-dir"
    fi
fi
[ -d "$GAME" ] || die "game dir not found: $GAME"
echo "    game: $GAME"
# library root = the steamapps that contains this game's common/ dir
STEAMAPPS="$(cd "$GAME/../.." && pwd)"          # .../steamapps
COMPATDATA="$STEAMAPPS/compatdata/361670"
PFX="$COMPATDATA/pfx"

# Snapshot the user's config.cfg now (before the payload rewrites it) so we can
# restore it at the end — keeps pilot/keybinds/settings across reinstalls.
xwau_backup_config "$GAME"

# ---------------------------------------------------------------- step 2b: remove / reinstall
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
    # (Steam already guaranteed closed by the early guard unless --no-steam-config,
    # in which case we don't touch Steam config here either.)
    log "Removing XWAU install (restoring vanilla game files)"
    xwau_remove_gamefiles "$GAME"
    if [ "$DO_STEAM_CONFIG" = 1 ]; then
        if python3 "$SCRIPT_DIR/installer/steam_config.py" --remove --steam-root "$STEAM_ROOT" --appid "$APPID"; then
            echo "    cleared Steam compat tool + launch options"
        else
            warn "couldn't clear Steam config automatically (edit manually if needed)"
        fi
    fi
    if [ "$REMOVE" = 1 ]; then
        rm -rf "$GAME.vanilla"
        xwau_registry_del "$GAME"
        log "Removed — X-Wing Alliance restored to vanilla and the mod uninstalled."
        echo "    (removed backup $GAME.vanilla; Proton prefix left in place — delete $COMPATDATA to fully reset.)"
        exit 0
    fi
    log "Reinstalling from this directory (release $RELEASE_TAG)"
fi
# hard defaults for anything not set by an arg or the manifest
RATIO="${RATIO:-2}"; PRESET="${PRESET:-High}"

# ---------------------------------------------------------------- step 3: Proton >= 11 check
log "Checking for Proton (>= wine-11)"
PROTON_OK=""; PROTON_DIR=""
for p in "Proton Hotfix" "Proton Experimental" "$STEAMAPPS"/common/Proton\ 1[1-9]* ; do
    pdir="$STEAMAPPS/common/$p"; [ -d "$pdir" ] || pdir="$p"
    [ -d "$pdir" ] || continue
    pv="$("$pdir/files/bin/wine" --version 2>/dev/null || echo "")"
    case "$pv" in wine-1[1-9]*|wine-[2-9][0-9]*) PROTON_OK="$(basename "$pdir") ($pv)"; PROTON_DIR="$pdir"; break ;; esac
done
if [ -n "$PROTON_OK" ]; then
    echo "    found Proton >= 11: $PROTON_OK"
else
    warn "no Proton >= wine-11 found. In Steam, install 'Proton Hotfix' or 'Proton Experimental'"
    warn "(Steam -> Tools, or right-click X-Wing Alliance -> Compatibility). wine-11 is required"
    warn "for HD video + the in-process hooks. You can finish this install and select it after."
fi

# ---------------------------------------------------------------- step 4: Proton prefix (for the payload's %UserProfile%)
# The payload writes to the prefix's user profile ($PFX/drive_c/users/steamuser),
# so the prefix must exist. Steam builds it on first game launch — but we can do
# the same thing here (Steam closed) by driving Proton through the Steam Linux
# Runtime, so a first-time install needs no manual "launch once + re-run". This is
# best-effort: if anything about the standalone Proton invocation fails, we fall
# back to the manual steps rather than leaving a half-made prefix.
print_manual_prefix_steps() {
    cat <<EOF

  Create the Proton prefix first (manual fallback):
    1. In Steam: X-Wing Alliance -> Properties -> Compatibility ->
       "Force the use of a specific Steam Play compatibility tool" -> Proton Hotfix
       (or Proton Experimental).
    2. Launch the game once from Steam. It will create the prefix (the game may
       just show a black screen / close — that's fine; we configure it next).
    3. Re-run this installer.

  (Why: the XWAU payload writes files to $PFX/drive_c/users/steamuser.)
EOF
}
if [ ! -d "$PFX/drive_c" ]; then
    if pgrep -x steam >/dev/null 2>&1; then
        warn "Steam is running — close Steam completely, then re-run so the prefix can be created."
        print_manual_prefix_steps
        die "Proton prefix not found at $PFX (Steam must be closed to create it)"
    fi
    SLR_ENTRY="$(xwau_find_slr "$STEAM_ROOT" "$STEAMAPPS" || true)"
    if [ -n "$PROTON_DIR" ] && [ -n "$SLR_ENTRY" ] \
       && xwau_create_proton_prefix "$PROTON_DIR" "$COMPATDATA" "$STEAM_ROOT" "$SLR_ENTRY"; then
        echo "    created prefix: $PFX"
    else
        warn "couldn't auto-create the Proton prefix (need Proton >= 11 + SteamLinuxRuntime_sniper)."
        print_manual_prefix_steps
        die "Proton prefix not found at $PFX — see the steps above"
    fi
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
# The XWAU payload rewrote config.cfg; put the user's saved one back.
xwau_restore_config "$GAME"

# ---------------------------------------------------------------- step 9: configure Steam
configure_steam

# ---------------------------------------------------------------- step 10: install manifest (for --reinstall)
_MF_FULL="$XWAU_FULL"; [ -n "$_MF_FULL" ] && _MF_FULL="$(readlink -f "$_MF_FULL" 2>/dev/null || echo "$_MF_FULL")"
_MF_UPD="$XWAU_UPD";   [ -n "$_MF_UPD" ]  && _MF_UPD="$(readlink -f "$_MF_UPD" 2>/dev/null || echo "$_MF_UPD")"
xwau_write_manifest "$GAME" variant=steam release_tag="$RELEASE_TAG" \
    game_dir="$GAME" \
    xwau_full="$_MF_FULL" xwau_upd="$_MF_UPD" ratio="$RATIO" preset="$PRESET" \
    resolution="$RESOLUTION" concourse_pace="$CONCOURSE_PACE" appid="$APPID" \
    installed_at="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
# Record this dir so a later --reinstall/--remove (no --game-dir) reuses the
# Steam install specifically (a machine may also have a GOG/standalone one).
xwau_registry_add "$GAME"

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
