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
    python3 "$script_dir/installer/xwau_payload_install.py" "$game" "$userprofile" \
        "$work/payloads" --ratio "$ratio" --preset "$preset"
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
              [ -f "$f" ] || curl -L -o "$f" "$XWAU_RELEASE_BASE/$release_tag/$f"
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
