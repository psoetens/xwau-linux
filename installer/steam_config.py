#!/usr/bin/env python3
"""Targeted Steam-config editor for the XWAU win64 Steam installer.

Sets, for a given appid:
  - config.vdf:  CompatToolMapping/"<appid>" { name <token>; config ""; priority "250" }
  - localconfig.vdf (each userdata/*/config that has the app):  apps/"<appid>"/LaunchOptions

Targeted text edits only (locate the relevant "key" { ... } block by brace-matching,
then insert/replace inside it) — the rest of each file is preserved byte-for-byte.
Every file is backed up; after editing it is re-read and brace-balance-checked; on
any anomaly the backup is restored and we exit non-zero.

STEAM MUST BE CLOSED (Steam rewrites these on exit). Usage:
  steam_config.py --steam-root DIR --appid 361670 --token proton_11 \
                  --launch-options 'WINEDLLOVERRIDES="..." /path/wrapper %command%'
"""
import argparse, glob, os, re, sys, time


def match_brace(s, i):
    """s[i] is '{'; return index of the matching '}', skipping quoted strings."""
    depth, n, q = 0, len(s), False
    while i < n:
        c = s[i]
        if q:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                q = False
        else:
            if c == '"':
                q = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def find_block(s, key, start=0, end=None):
    """Find `"key" { ... }`; return (key_start, brace_open, brace_close) or None."""
    if end is None:
        end = len(s)
    pat = re.compile(r'"' + re.escape(key) + r'"')
    pos = start
    while True:
        m = pat.search(s, pos, end)
        if not m:
            return None
        j = m.end()
        while j < end and s[j] in ' \t\r\n':
            j += 1
        if j < end and s[j] == '{':
            bclose = match_brace(s, j)
            if bclose != -1:
                return (m.start(), j, bclose)
        pos = m.end()


def vdf_escape(v):
    return v.replace('\\', '\\\\').replace('"', '\\"')


def set_key_in_block(s, bopen, bclose, key, value):
    """Within the block s[bopen:bclose], set "key" "value" (replace or insert).
    Returns the new full string. `value` is escaped here."""
    block = s[bopen:bclose]            # includes '{' .. up to (not incl) '}'
    rx = re.compile(r'("' + re.escape(key) + r'"\s*)"(?:\\.|[^"\\])*"')
    ev = vdf_escape(value)
    if rx.search(block):
        newblock = rx.sub(lambda m: m.group(1) + '"' + ev + '"', block, count=1)
        return s[:bopen] + newblock + s[bclose:]
    # insert before the closing brace, indented one deeper than the block's '{' line
    indent = _line_indent(s, bopen) + '\t'
    ins = '%s"%s"\t\t"%s"\n%s' % (indent, key, ev, _line_indent(s, bopen))
    return s[:bclose] + ins + s[bclose:]


def _line_indent(s, idx):
    nl = s.rfind('\n', 0, idx)
    line = s[nl + 1: idx]
    return re.match(r'[ \t]*', line).group(0)


def ensure_compat_mapping(text, appid, token):
    cm = find_block(text, 'CompatToolMapping')
    if not cm:
        raise RuntimeError('CompatToolMapping block not found in config.vdf')
    _, cm_open, cm_close = cm
    appblk = find_block(text, appid, cm_open + 1, cm_close)
    if appblk:
        _, b_open, b_close = appblk
        # fix the name (insert if missing); leave config/priority as they are
        return set_key_in_block(text, b_open, b_close, 'name', token)
    # insert a fresh appid child before the mapping's closing brace
    indent = _line_indent(text, cm_open) + '\t'
    child = (
        '%s"%s"\n%s{\n%s\t"name"\t\t"%s"\n%s\t"config"\t\t""\n%s\t"priority"\t\t"250"\n%s}\n%s'
        % (indent, appid, indent, indent, token, indent, indent, indent, _line_indent(text, cm_open))
    )
    return text[:cm_close] + child + text[cm_close:]


def remove_compat_mapping(text, appid):
    """Remove the CompatToolMapping/<appid> block entirely. Returns (text, changed)."""
    cm = find_block(text, 'CompatToolMapping')
    if not cm:
        return text, False
    _, cm_open, cm_close = cm
    blk = find_block(text, appid, cm_open + 1, cm_close)
    if not blk:
        return text, False                       # not mapped -> already "fresh"
    kstart, _b_open, b_close = blk
    line_start = text.rfind('\n', 0, kstart) + 1  # include the key's leading indent
    end = b_close + 1
    if end < len(text) and text[end] == '\n':     # and the trailing newline
        end += 1
    return text[:line_start] + text[end:], True


def set_launch_options(text, appid, value):
    """Find the apps/<appid> block and set its LaunchOptions. Returns (text, changed)."""
    pos = 0
    while True:
        apps = find_block(text, 'apps', pos)
        if not apps:
            return text, False
        _, a_open, a_close = apps
        appblk = find_block(text, appid, a_open + 1, a_close)
        if appblk:
            _, b_open, b_close = appblk
            return set_key_in_block(text, b_open, b_close, 'LaunchOptions', value), True
        pos = a_close + 1


def brace_balanced(s):
    depth, q, i, n = 0, False, 0, len(s)
    while i < n:
        c = s[i]
        if q:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                q = False
        else:
            if c == '"':
                q = True
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
        i += 1
    return depth == 0 and not q


def edit_file(path, transform, require_change=True):
    """Read path, apply transform(text)->(text,changed), back up, write, re-validate."""
    with open(path, 'r', encoding='utf-8', errors='surrogateescape') as f:
        orig = f.read()
    new, changed = transform(orig)
    if not changed:
        if require_change:
            print('  WARN: no change made to %s (target block not found)' % os.path.basename(path))
        return False
    if new == orig:
        return False
    if not brace_balanced(new):
        raise RuntimeError('edit unbalanced braces in %s — aborting' % path)
    bak = '%s.xwau.bak.%d' % (path, int(time.time()))
    with open(bak, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(orig)
    with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(new)
    # re-read + re-validate; restore on anomaly
    with open(path, 'r', encoding='utf-8', errors='surrogateescape') as f:
        back = f.read()
    if back != new or not brace_balanced(back):
        with open(path, 'w', encoding='utf-8', errors='surrogateescape') as f:
            f.write(orig)
        raise RuntimeError('post-write validation failed for %s — restored' % path)
    print('  edited %s (backup: %s)' % (path, os.path.basename(bak)))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--steam-root', required=True)
    ap.add_argument('--appid', required=True)
    ap.add_argument('--token')
    ap.add_argument('--launch-options')
    ap.add_argument('--remove', action='store_true',
                    help='remove the compat-tool mapping and clear launch options')
    a = ap.parse_args()
    if not a.remove and (a.token is None or a.launch_options is None):
        ap.error('--token and --launch-options are required unless --remove is given')

    # --remove: drop the CompatToolMapping block; else set the name to the token.
    compat_transform = ((lambda t: remove_compat_mapping(t, a.appid)) if a.remove
                        else (lambda t: (ensure_compat_mapping(t, a.appid, a.token), True)))
    # --remove: blank the launch options; else set them.
    lo_value = '' if a.remove else a.launch_options

    did = 0
    config_vdf = os.path.join(a.steam_root, 'config', 'config.vdf')
    if os.path.exists(config_vdf):
        if edit_file(config_vdf, compat_transform, require_change=not a.remove):
            did += 1
    else:
        print('  WARN: %s not found' % config_vdf)

    locals_ = glob.glob(os.path.join(a.steam_root, 'userdata', '*', 'config', 'localconfig.vdf'))
    touched_lc = False
    for lc in locals_:
        if edit_file(lc, lambda t: set_launch_options(t, a.appid, lo_value),
                     require_change=False):
            touched_lc = True
            did += 1
    if not touched_lc and not a.remove:
        print('  WARN: no localconfig.vdf had an apps/%s block (launch options not set)' % a.appid)

    print('  steam_config: %d file(s) updated' % did)
    return 0 if did else 2


if __name__ == '__main__':
    sys.exit(main())
