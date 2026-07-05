#!/bin/bash
# common.sh — shared logic for the win64 XWAU-on-Linux installers
# (install-xwau-steam.sh = Proton; install-xwau-linux.sh = Kron4ek standalone).
# Source this; call the xwau_* functions. Pure functions (args, no hidden globals)
# except the log helpers. Branch: win64.

# ---- logging (define once) ----
if ! declare -F log >/dev/null; then
    log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
    warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*"; }
    die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
fi

# ---- host fonts check (both installers need the same fonts) ----
xwau_check_fonts() {
    if command -v fc-list >/dev/null; then
        # NB: capture once and match via here-string — do NOT pipe into `grep -q`.
        # Under `set -o pipefail`, grep -q closes the pipe on first match, fc-list
        # gets SIGPIPE, and the pipeline reports failure => spurious "not found"
        # warning even when the font IS present.
        local fonts; fonts="$(fc-list)"
        /usr/bin/grep -qi "DejaVu Sans"    <<<"$fonts" || warn "font 'DejaVu Sans' not found — install dejavu fonts (HUD text blank without it)"
        /usr/bin/grep -qi "Liberation Mono" <<<"$fonts" || warn "font 'Liberation Mono' not found — install liberation fonts (concourse text blank without it)"
    else
        warn "fc-list not found — cannot verify fonts (DejaVu Sans + Liberation Mono required)"
    fi
}

# ---- locate the Steam X-Wing Alliance dir (echoes the path) ----
xwau_locate_game() {
    local game=""
    for vdf in "$HOME/.steam/root/steamapps/libraryfolders.vdf" \
               "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"; do
        [ -f "$vdf" ] || continue
        while IFS= read -r lib; do
            local cand="$lib/steamapps/common/Star Wars X-Wing Alliance"
            if [ -f "$cand/xwingalliance.exe" ] || [ -f "$cand/XWINGALLIANCE.EXE" ]; then
                echo "$cand"; return 0
            fi
        done < <(/usr/bin/grep -oP '"path"\s+"\K[^"]+' "$vdf")
    done
    return 1
}

# ---- vanilla backup (restore point) ----
xwau_vanilla_backup() {
    local game="$1"
    if [ -d "$game.vanilla" ]; then
        log "Vanilla backup already exists: $game.vanilla"
    elif [ -f "$game/Hooks.ini" ] || [ -f "$game/ddraw_effects.dll" ]; then
        warn "game dir already has XWAU files and no .vanilla backup exists — skipping backup"
    else
        log "Backing up vanilla game dir (restore point — Steam Verify would destroy the mod)"
        cp -a "$game" "$game.vanilla"
    fi
}

# ---- XWAU 2025 payload replay ----
# xwau_payload_replay SCRIPT_DIR GAME USERPROFILE WORK XWAU_FULL XWAU_UPD RATIO PRESET
xwau_payload_replay() {
    local script_dir="$1" game="$2" userprofile="$3" work="$4" full="$5" upd="$6" ratio="$7" preset="$8"
    if [ -f "$game/Hooks.ini" ]; then
        log "XWAU 2025 already installed (Hooks.ini present)"; return 0
    fi
    [ -n "$full" ] && [ -f "$full" ] || die "pass --xwau-full /path/XWAU2025_Full_1.0.0.zip (download from xwaupgrade.com)"
    [ -n "$upd" ]  && [ -f "$upd" ]  || die "pass --xwau-upd /path/XWAU2025_UPD_1.1.0.zip (download from xwaupgrade.com)"
    log "Unpacking XWAU distribution zips"
    mkdir -p "$work/payloads/full" "$work/payloads/upd"
    unzip -o -q "$full" -d "$work/payloads/full"
    unzip -o -q "$upd"  -d "$work/payloads/upd"
    log "Installing XWAU 2025 (payload replay; ratio=$ratio preset=$preset)"
    mkdir -p "$userprofile"
    if python3 "$script_dir/installer/xwau_payload_install.py" "$game" "$userprofile" \
            "$work/payloads" --ratio "$ratio" --preset "$preset"; then
        # Success: the payload now lives in the game dir, so the extracted scratch
        # (a full second ~6.6G copy) is pure transience — drop it. Set
        # XWAU_KEEP_PAYLOADS=1 to keep it (avoids re-unzipping when iterating).
        if [ -n "${XWAU_KEEP_PAYLOADS:-}" ]; then
            echo "    kept scratch payloads (XWAU_KEEP_PAYLOADS set): $work/payloads"
        else
            rm -rf "$work/payloads"
            echo "    cleaned up scratch payloads: $work/payloads"
        fi
    else
        local rc=$?
        warn "payload install failed (rc=$rc) — keeping $work/payloads for debugging"
        return "$rc"
    fi
}

# ---- win64 binary overlay (force-shim ddraw, native hook_patcher, CLR-hosting shims) ----
# xwau_install_binaries GAME BIN_DIR RELEASE_TAG WORK
# If BIN_DIR is empty, downloads the binaries from the GitHub release RELEASE_TAG
# (checksum-verified) into WORK; BIN_DIR is the developer override for local builds.
XWAU_RELEASE_BASE="https://github.com/psoetens/xwau-linux/releases/download"
XWAU_BIN_FILES="ddraw_effects.dll TGSMUSH.DLL hook_patcher.dll hook_32bpp_net.dll hook_concourse_net.dll hook_32bpp_bridge.dll hook_concourse_bridge.dll"
xwau_install_binaries() {
    local game="$1" bin_dir="$2" release_tag="${3:-}" work="${4:-$HOME/.cache/xwau-linux-install}"
    if [ -n "$bin_dir" ]; then
        [ -d "$bin_dir" ] || die "--bin-dir not found: $bin_dir"
        log "Installing win64 binaries from $bin_dir (local override)"
    else
        [ -n "$release_tag" ] || die "no --bin-dir and no --release tag"
        bin_dir="$work/bin-$release_tag"
        mkdir -p "$bin_dir"
        log "Downloading win64 binaries from release $release_tag"
        ( cd "$bin_dir"
          local f
          for f in $XWAU_BIN_FILES SHA256SUMS.txt; do
              [ -f "$f" ] && continue
              # -f: fail on HTTP errors (else a 404 body like "Not Found" gets saved
              # as the file and poisons this cache dir for every later run). Drop any
              # partial/empty file on failure so nothing bad is left behind.
              curl -fL -o "$f" "$XWAU_RELEASE_BASE/$release_tag/$f" || { rm -f "$f"; exit 1; }
          done
          sha256sum -c SHA256SUMS.txt
        ) || die "win64 binary download/checksum failed (release $release_tag)"
    fi
    _xwau_put() {  # src-basename backup-suffix
        local f="$1" suffix="$2"
        [ -f "$bin_dir/$f" ] || die "missing $f in $bin_dir"
        local tgt; tgt="$(find "$game" -maxdepth 1 -iname "$f" | head -1)"; tgt="${tgt:-$game/$f}"
        [ -f "$tgt" ] && [ ! -f "$tgt$suffix" ] && cp "$tgt" "$tgt$suffix"
        cp "$bin_dir/$f" "$tgt"; echo "    installed $f"
    }
    _xwau_put ddraw_effects.dll      .xwau-orig   # force-shim ddraw (HD concourse on wine-11)
    _xwau_put TGSMUSH.DLL            .xwau-orig   # MF video backend
    _xwau_put hook_patcher.dll       .ijw-orig    # NATIVE reimpl (no CLR-bootstrap deadlock)
    _xwau_put hook_32bpp_net.dll     .ijw-orig    # native CLR-hosting shim
    _xwau_put hook_concourse_net.dll .ijw-orig    # native CLR-hosting shim
    local b
    for b in hook_32bpp_bridge.dll hook_concourse_bridge.dll; do
        [ -f "$bin_dir/$b" ] && cp "$bin_dir/$b" "$game/$b" && echo "    installed $b"
    done
    # hook_keyboard_bg.dll is intentionally NOT installed on win64 (the Esc focus-loss
    # it fixed was the win32 sidecar window; no sidecar here — verified).
}

# ---- config overlay (win64: HD concourse on, no sidecar, no VA workarounds) ----
# xwau_config_overlay GAME RESOLUTION PACE
xwau_config_overlay() {
    local game="$1" resolution="$2" pace="$3"
    if [ -z "$pace" ]; then
        local hz; hz=$(command -v xrandr >/dev/null && xrandr --current 2>/dev/null | /usr/bin/grep -oP '[0-9.]+(?=\*)' | head -1 | cut -d. -f1 || echo "")
        if   [ -z "$hz" ];     then pace=1
        elif [ "$hz" -le 70 ]; then pace=1
        elif [ "$hz" -le 150 ];then pace=2
        else                        pace=3; fi
        echo "    detected refresh ~${hz:-?} Hz -> concourse pace $pace"
    fi
    log "Applying Linux config overlay"
    python3 - "$game" "$resolution" "$pace" <<'PYCFG'
import sys, os, re
game, resolution, pace = sys.argv[1], sys.argv[2], sys.argv[3]
def find(name):
    for e in os.listdir(game):
        if e.lower() == name.lower():
            return os.path.join(game, e)
    return os.path.join(game, name)
def read(path):
    with open(path, 'rb') as f: raw = f.read()
    eol = '\r\n' if b'\r\n' in raw else '\n'
    return raw.decode('latin-1').split(eol), eol
def write(path, lines, eol):
    with open(path, 'wb') as f: f.write(eol.join(lines).encode('latin-1'))
def set_key(path, key, value, section=None):
    lines, eol = read(path) if os.path.exists(path) else ([], '\r\n')
    sec = None; in_target = section is None
    pat = re.compile(r'^\s*' + re.escape(key) + r'\s*=', re.I); last = len(lines)
    for i, line in enumerate(lines):
        m = re.match(r'^\s*\[(.+)\]\s*$', line)
        if m:
            if in_target and section is not None: last = i
            sec = m.group(1).strip().lower()
            in_target = section is None or sec == section.lower(); continue
        if in_target and pat.match(line):
            lines[i] = f'{key} = {value}'; write(path, lines, eol)
            print(f'  {os.path.basename(path)}{"["+section+"]" if section else ""}: {key} = {value}'); return
        if in_target and section is not None and line.strip(): last = i + 1
    if section is not None and (sec is None or not any(
            re.match(r'^\s*\[' + re.escape(section) + r'\]\s*$', l, re.I) for l in lines)):
        lines += [f'[{section}]']; last = len(lines)
    lines.insert(last, f'{key} = {value}'); write(path, lines, eol)
    print(f'  {os.path.basename(path)}{"["+section+"]" if section else ""}: {key} = {value} (added)')

ddraw = find('ddraw.cfg')
set_key(ddraw, 'HDConcourseEnabled', '1')        # force-shim ddraw renders it on wine-11
set_key(ddraw, 'EnableSideProcess', '0')         # no sidecar on win64 (in-process)
set_key(ddraw, 'TgSmushSwapchainPresentEnabled', '1')
set_key(ddraw, 'TextFontFamily', 'DejaVu Sans')
set_key(ddraw, 'Text2DRendererEnabled', '1')
set_key(ddraw, 'Radar2DRendererEnabled', '1')

hooks = find('Hooks.ini')
set_key(hooks, 'HDConcourseTextFont', 'Liberation Mono', section='hook_concourse')
set_key(hooks, 'EnableSideProcess', '0', section='hook_concourse')
set_key(hooks, 'EnableSideProcess', '0', section='hook_32bpp')  # in-process, full-res skins
if resolution:
    w, h = resolution.lower().split('x')
    set_key(hooks, 'ResolutionWidth', w, section='hook_resolution')
    set_key(hooks, 'ResolutionHeight', h, section='hook_resolution')

# win64 has no 32-bit VA ceiling -> the win32 mitigations are intentionally absent
# (no SSAO raytracing/HDR force-off, no SkinsSizeThreshold, no dxvk fps cap).

vrp = find('VRParams.cfg')
if os.path.exists(vrp):
    set_key(vrp, 'concourse_animations_at_25fps', pace)

tgs = find('TGSmush.cfg')
set_key(tgs, 'ForceBackend', 'mf')
set_key(tgs, 'MFSoftwarePresent', '0')
set_key(tgs, 'MFD3DPresent', '1')
PYCFG
}

# ---- 32-bit codec deps for HD cutscenes --------------------------------------
# GE's 32-bit gstreamer cutscene plugins (libgstlibav/isomp4/videoparsersbad ->
# ffmpeg) need a slice of the host's 32-bit userland that GE does NOT ship. Two
# of those deps are "soname traps" we stage ourselves (see xwau_stage_leaf); the
# rest MUST come from the host's multilib packages — notably the GPU/display libs
# (libva/libvdpau/libdrm/libX11...) which have to match the running driver and so
# can't be bundled. This by-name list is coupled to the pinned GE-Proton version
# (GE-Proton10-34); if GE_NAME is bumped, re-derive it with:
#   LD_LIBRARY_PATH=$GE/lib/i386-linux-gnu ldd $GE/lib/i386-linux-gnu/gstreamer-1.0/libgstlibav.so
# (glibc base libc/libm/ld-linux are omitted: if any i386 lib resolves, they do).
XWAU_CODEC_SONAMES="libglib-2.0.so.0 libgobject-2.0.so.0 libgmodule-2.0.so.0 \
libz.so.1 libffi.so.8 libpcre2-8.so.0 libatomic.so.1 \
libva.so.2 libva-drm.so.2 libva-x11.so.2 libvdpau.so.1 libdrm.so.2 \
libX11.so.6 libX11-xcb.so.1 libxcb.so.1 libxcb-dri3.so.0 \
libXext.so.6 libXfixes.so.3 libXau.so.6 libXdmcp.so.6"

# true if the given file is a 32-bit ELF (EI_CLASS byte at offset 4 == 1).
_xwau_is_elf32() { [ "$(od -An -t u1 -j4 -N1 "$1" 2>/dev/null | tr -d ' ')" = 1 ]; }

# true if a 32-bit build of $1 (soname) is in the loader cache. The i386 entries
# carry an arch tag of "(libc6)" while 64-bit ones read "(libc6,x86-64)"; filter
# out x86-64/x32 so only the 32-bit variants count. Works on Debian and Fedora.
_xwau_have32() {  # $1 = soname   (reads cached $_XWAU_LDC)
    printf '%s\n' "$_XWAU_LDC" | grep -F "$1 (" | grep -Ev 'x86-64|x32' | grep -q .
}

# Print a copy-pasteable, per-distro "install the 32-bit codec libs" command.
_xwau_codec_fixhint() {  # $1 = space-separated missing sonames (for context only)
    local id like ctx
    id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    like="$(. /etc/os-release 2>/dev/null; echo "${ID_LIKE:-}")"
    ctx="$id $like"
    if [ -f /run/ostree-booted ]; then
        cat <<'EOF'
  Your system is image-based (immutable / ostree, e.g. Bazzite/Silverblue).
  These 32-bit libs normally ship preinstalled there, so hitting this is
  unusual. Layering codec libs is discouraged (needs a reboot and can slow OS
  updates), but the direct fix is:
      sudo rpm-ostree install glib2.i686 zlib-ng-compat.i686 libffi.i686 \
        pcre2.i686 libatomic.i686 libva.i686 libvdpau.i686 libdrm.i686 \
        libX11.i686 libxcb.i686 libXext.i686 libXfixes.i686 libXau.i686 \
        libXdmcp.i686 && systemctl reboot
EOF
        return
    fi
    case "$ctx" in
        *fedora*|*rhel*|*centos*)
            cat <<'EOF'
  Fedora / RHEL — run:
      sudo dnf install -y glib2.i686 zlib-ng-compat.i686 libffi.i686 pcre2.i686 \
        libatomic.i686 bzip2-libs.i686 libva.i686 libvdpau.i686 libdrm.i686 \
        libX11.i686 libxcb.i686 libXext.i686 libXfixes.i686 libXau.i686 libXdmcp.i686
EOF
            ;;
        *arch*|*manjaro*)
            cat <<'EOF'
  Arch / Manjaro — enable the [multilib] repo in /etc/pacman.conf, then run:
      sudo pacman -S --needed lib32-glib2 lib32-zlib lib32-libffi lib32-pcre2 \
        lib32-bzip2 lib32-libva lib32-libvdpau lib32-libdrm lib32-libx11 \
        lib32-libxcb lib32-libxext lib32-libxfixes lib32-libxau lib32-libxdmcp \
        lib32-gcc-libs
EOF
            ;;
        *debian*|*ubuntu*|*mint*)
            cat <<'EOF'
  Debian / Ubuntu / Mint — run:
      sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install -y \
        libglib2.0-0t64:i386 zlib1g:i386 libffi8:i386 libpcre2-8-0:i386 \
        libatomic1:i386 libbz2-1.0:i386 libva2:i386 libva-drm2:i386 \
        libva-x11-2:i386 libvdpau1:i386 libdrm2:i386 libx11-6:i386 \
        libx11-xcb1:i386 libxcb1:i386 libxcb-dri3-0:i386 libxext6:i386 \
        libxfixes3:i386 libxau6:i386 libxdmcp6:i386
  (on releases predating the t64 transition, use libglib2.0-0:i386 instead.)
EOF
            ;;
        *)
            cat <<'EOF'
  Unknown distro — install the 32-bit (i686 / i386) build of each library listed
  above with your package manager, then re-run this installer.
EOF
            ;;
    esac
}

# Fail EARLY (before any download/extraction) if the host lacks the 32-bit stack
# HD cutscenes need. GE-independent: probes XWAU_CODEC_SONAMES via ldconfig, so it
# runs before the GE donor is even fetched. The two soname-trap leaves (libvpx.so.6,
# libbz2.so.1.0) are intentionally NOT probed here — xwau_stage_leaf always provides
# them, so their absence is never a reason to abort.
xwau_codec_preflight() {  # $1 = 1 to bypass the die (--skip-codec-check)
    local skip="${1:-0}"
    log "Checking 32-bit codec deps for HD cutscenes (before download)"
    local _XWAU_LDC
    _XWAU_LDC="$( { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } || true )"
    local missing="" s
    for s in $XWAU_CODEC_SONAMES; do
        _xwau_have32 "$s" || missing="$missing $s"
    done
    missing="${missing# }"
    if [ -z "$missing" ]; then
        echo "    32-bit codec stack present"
        return 0
    fi
    warn "missing 32-bit libraries required for HD cutscenes:"
    printf '      %s\n' $missing
    echo
    _xwau_codec_fixhint "$missing"
    echo
    if [ "$skip" = 1 ]; then
        warn "--skip-codec-check set: continuing anyway; HD cutscenes will be BLACK (audio only)"
        return 0
    fi
    die "install the 32-bit libraries above (single command in the box), then re-run — or pass --skip-codec-check to install without HD cutscenes."
}

# Stage one 32-bit "soname-trap leaf" into LIB32 under the exact name GE's plugins
# ask for. GE ships neither, and the host either lacks it (libvpx: no distro ships
# .so.6 anymore) or has it under an incompatible soname (Fedora patches bzip2 to
# libbz2.so.1 vs the Debian soname libbz2.so.1.0). Order: exact host name ->
# compatible host name (ABI-identical; copied+renamed) -> release download. All
# candidates are ELF32-verified so a same-named 64-bit lib is never staged.
# Both leaves are BSD/bzip2-licensed and redistributable.
xwau_stage_leaf() {  # $1=lib32dir $2=wanted-soname $3=release_tag [compat basenames...]
    local lib32="$1" want="$2" tag="$3"; shift 3
    if [ -f "$lib32/$want" ]; then log "32-bit $want already staged"; return 0; fi
    log "Staging 32-bit $want (HD cutscene codec dep)"
    local names="$want $*" d n src=""
    for d in \
        "$HOME/.local/share/Steam/ubuntu12_32" \
        "$HOME/.local/share/Steam/steamrt32" \
        "$HOME"/.local/share/Steam/steamapps/common/SteamLinuxRuntime_sniper/*/files/lib/i386-linux-gnu \
        /usr/lib/i386-linux-gnu /usr/lib32 /usr/lib ; do
        [ -d "$d" ] || continue
        for n in $names; do
            if [ -f "$d/$n" ] && _xwau_is_elf32 "$d/$n"; then src="$d/$n"; break 2; fi
        done
    done
    if [ -n "$src" ]; then
        cp -fL "$src" "$lib32/$want"; echo "    staged from $src"; return 0
    fi
    if curl -fLsS -o "$lib32/$want" "$XWAU_RELEASE_BASE/$tag/$want"; then
        echo "    downloaded from release $tag"; return 0
    fi
    rm -f "$lib32/$want"
    warn "no 32-bit source for $want found locally and none in release $tag — HD cutscenes may be black; drop $want in $lib32/ or upload it to the release"
    return 1
}

# ---- Steam: create the Proton prefix without a manual game launch ------------
# Steam normally builds compatdata/<appid>/pfx on first game launch. We do the
# same thing standalone (Steam MUST be closed) by invoking the chosen Proton
# through the Steam Linux Runtime (sniper) entry-point with the compat env Steam
# would set, running wineboot. Best-effort: prints a warning and returns non-zero
# on any failure so the caller can fall back to the manual "launch once" steps.

# Locate SteamLinuxRuntime_sniper/_v2-entry-point. It lives in the *main* Steam
# library, which may differ from the game's library — so check the steam root and
# the game's library first, then any path in libraryfolders.vdf. Prints the path.
xwau_find_slr() {  # $1=steam_root  $2=game_steamapps
    local d p lf
    for d in "$1/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point" \
             "$2/common/SteamLinuxRuntime_sniper/_v2-entry-point"; do
        [ -x "$d" ] && { echo "$d"; return 0; }
    done
    lf="$1/steamapps/libraryfolders.vdf"
    if [ -f "$lf" ]; then
        while IFS= read -r p; do
            d="$p/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point"
            [ -x "$d" ] && { echo "$d"; return 0; }
        done < <(grep -oE '"path"[[:space:]]+"[^"]+"' "$lf" | sed -E 's/.*"([^"]+)"$/\1/')
    fi
    return 1
}

# Create the prefix. $1=proton_dir $2=compatdata_dir $3=steam_root $4=slr_entry
xwau_create_proton_prefix() {
    local proton_dir="$1" compatdata="$2" steam_root="$3" slr="$4"
    local proton="$proton_dir/proton"
    [ -f "$proton" ] || { warn "no 'proton' script in $proton_dir"; return 1; }
    [ -x "$slr" ]    || { warn "Steam Linux Runtime (sniper) entry-point not usable: $slr"; return 1; }
    mkdir -p "$compatdata"
    log "Creating Proton prefix with $(basename "$proton_dir") (no game launch needed)"
    STEAM_COMPAT_DATA_PATH="$compatdata" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="$steam_root" \
    timeout 300 "$slr" --verb=waitforexitandrun -- \
        "$proton" waitforexitandrun wineboot >/dev/null 2>&1
    local rc=$?
    [ "$rc" = 0 ] || { warn "prefix creation via Proton exited rc=$rc"; return 1; }
    [ -d "$compatdata/pfx/drive_c" ] || { warn "prefix not created (no pfx/drive_c)"; return 1; }
    return 0
}

# ---- remove / reinstall support ---------------------------------------------
# Restore the game dir to the pristine snapshot the installer took at first run.
# This removes ALL our changes that live in the game dir (payload, replaced DLLs,
# the manifest, and the standalone launcher + .linux-lib32) in one shot. The
# .vanilla dir is a SIBLING of the game dir, so it is never touched by the sync.
xwau_remove_gamefiles() {  # $1=game
    local game="$1" van="$1.vanilla"
    [ -d "$van" ] || die "no vanilla backup at $van — nothing to restore (was this installed by us?)"
    # Preserve USER DATA across the vanilla restore: pilots/saves + configs. The
    # XWAU payload zips contain no .cfg/.ini, so nothing regenerates over these;
    # on --reinstall the config overlay re-applies its keys per-key (merge).
    # Hooks.ini is intentionally NOT preserved — it's the install marker (the
    # payload skips if present) and is fully mod/overlay-managed, so it's
    # regenerated. Resolution/preset/ratio/pace come back via the manifest.
    local stash; stash="$(mktemp -d)"; local saved=0 item f base
    for item in UserData "Pilots Backup" pilot.bak; do          # pilots / saves
        [ -e "$game/$item" ] && { cp -a "$game/$item" "$stash/"; saved=1; }
    done
    shopt -s nullglob nocaseglob
    for f in "$game"/*.cfg "$game"/*.ini "$game"/*.plt; do      # user configs + root pilots
        base="$(basename "$f")"
        [ "${base,,}" = "hooks.ini" ] && continue               # marker: regenerate, don't keep
        cp -a "$f" "$stash/"; saved=1
    done
    shopt -u nullglob nocaseglob

    log "Restoring vanilla game files from $(basename "$van")"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$van/" "$game/"
    else
        find "$game" -mindepth 1 -delete
        cp -a "$van/." "$game/"
    fi
    if [ "$saved" = 1 ]; then
        cp -a "$stash/." "$game/"                               # user versions win over vanilla defaults
        echo "    preserved your pilots + configs (Hooks.ini regenerated)"
    fi
    rm -rf "$stash"
    echo "    game dir restored to vanilla"
}

# Record what was installed so --reinstall can replay it without re-passing the
# big XWAU zips. Lives in the game dir (wiped by --remove; --reinstall reads it
# into memory BEFORE removing). Args after $1 are key=value pairs.
xwau_write_manifest() {  # $1=game  key=value...
    local game="$1"; shift
    python3 - "$game/.xwau-install.json" "$@" <<'PY'
import sys, json
mf = sys.argv[1]
d = {"schema": 1}
for kv in sys.argv[2:]:
    k, _, v = kv.partition('=')
    d[k] = v
with open(mf, 'w') as f:
    json.dump(d, f, indent=2); f.write('\n')
PY
    echo "    wrote install manifest: $game/.xwau-install.json"
}

# Load the manifest into MF_* shell vars (safely shell-quoted). Returns 1 if none.
xwau_load_manifest() {  # $1=game
    local mf="$1/.xwau-install.json"
    [ -f "$mf" ] || return 1
    eval "$(python3 - "$mf" <<'PY'
import sys, json, shlex
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for k in ("variant","release_tag","xwau_full","xwau_upd","ratio","preset","resolution","concourse_pace","appid"):
    print("MF_%s=%s" % (k.upper(), shlex.quote(str(d.get(k, "")))))
PY
)" || return 1
}

# ---- config.cfg preservation across (re)install --------------------------------
# The XWAU payload rewrites config.cfg on every (re)install (its Prepare/Finalize
# scripts), which resets user settings — pilot pointer (lastpilot), keybinds,
# audio, graphics. We keep a persistent per-game backup of the latest config.cfg
# and restore it AFTER the payload, so the user's settings survive. Interim
# workaround pending an upstream fix that leaves config.cfg alone.
XWAU_STATE="$HOME/.local/share/xwau-linux"
_xwau_cfg_bak() {  # $1=game -> persistent backup path (per game dir)
    printf '%s/config-%s.cfg' "$XWAU_STATE" "$(printf '%s' "$1" | sha1sum | cut -c1-16)"
}
xwau_backup_config() {  # $1=game — snapshot the current config.cfg (keep latest)
    local src="$1/config.cfg" bak
    [ -f "$src" ] || return 0
    bak="$(_xwau_cfg_bak "$1")"; mkdir -p "$XWAU_STATE"
    cp -a "$src" "$bak" 2>/dev/null && echo "    backed up config.cfg (kept across reinstalls)"
}
xwau_restore_config() {  # $1=game — restore config.cfg over whatever the payload wrote
    local bak; bak="$(_xwau_cfg_bak "$1")"
    [ -f "$bak" ] || return 0
    cp -f "$bak" "$1/config.cfg" 2>/dev/null && echo "    restored your config.cfg (over the payload's)"
}
