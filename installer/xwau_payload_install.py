#!/usr/bin/env python3
"""Manual XWAU 2025 installer for Linux.

Replays the logic of XwaInstallerManager/NSIS (XwaInstallerLibCore) against a
copy of the vanilla X-Wing Alliance directory:
  - payload zips: 'OverwriteOn\\...' trees extracted over the game dir
  - bare-file zips (Group_0_Application): files extracted to the game root
  - Script.txt command files (Prepare / Finalize / Ratio / Presets)
  - .202 binary patches (ZtFile format from JeremyAnsel/XwaExePatcher:
    13-byte ASCII target name, uint16 LE count, then records of
    int32 LE offset, uint8 length, <length> new bytes)

All path lookups are case-insensitive (Windows semantics on Linux).
"""

import os
import re
import shutil
import struct
import sys
import zipfile

GAME = None          # game dir (set in main)
USERPROFILE = None   # maps %UserProfile% (set in main)
LOG = sys.stdout


def log(*a):
    print(*a, file=LOG)
    LOG.flush()


def ci_resolve(rel, base=None):
    """Resolve a Windows-style relative path case-insensitively under base.
    Returns an absolute path; non-existing trailing components keep their
    given casing."""
    base = base or GAME
    rel = rel.replace("\\", "/").strip("/")
    cur = base
    parts = [p for p in rel.split("/") if p]
    for i, part in enumerate(parts):
        if os.path.isdir(cur):
            entries = {e.lower(): e for e in os.listdir(cur)}
            match = entries.get(part.lower())
            cur = os.path.join(cur, match if match else part)
        else:
            cur = os.path.join(cur, *parts[i:])
            break
    return cur


def expand(arg):
    if arg.lower().startswith("%userprofile%"):
        return USERPROFILE + arg[len("%userprofile%"):].replace("\\", "/")
    return None  # not a profile path


def resolve(arg, base=None):
    p = expand(arg)
    if p is not None:
        return ci_resolve(p.replace(USERPROFILE, "").lstrip("/"), USERPROFILE)
    return ci_resolve(arg, base)


# ---------------------------------------------------------------- zt patches

def apply_zt_patch(patch_file, target_file):
    with open(patch_file, "rb") as f:
        data = f.read()
    name = data[:13].rstrip(b"\0").decode("ascii", "replace")
    (count,) = struct.unpack_from("<H", data, 13)
    pos = 15
    patches = []
    for _ in range(count):
        (offset,) = struct.unpack_from("<i", data, pos)
        length = data[pos + 4]
        patches.append((offset, data[pos + 5:pos + 5 + length]))
        pos += 5 + length
    with open(target_file, "rb") as f:
        target = bytearray(f.read())
    maxend = max((o + len(b) for o, b in patches), default=0)
    if len(target) < maxend:
        raise RuntimeError(f"target too small for patch {patch_file}")
    for offset, bts in patches:
        target[offset:offset + len(bts)] = bts
    with open(target_file, "wb") as f:
        f.write(target)
    log(f"  ApplyPatch: {os.path.basename(patch_file)} -> "
        f"{os.path.basename(target_file)} ({count} records, header={name!r})")


# ---------------------------------------------------------------- text utils

def read_text(path):
    with open(path, "rb") as f:
        raw = f.read()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        text = raw.decode("utf-16")
    else:
        text = raw.decode("utf-8", "replace")
    eol = "\r\n" if "\r\n" in text else "\n"
    return text, eol


def write_text(path, lines, eol):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(eol.join(lines))


def set_config_line(path, key, value):
    text, eol = read_text(path)
    lines = text.split(eol)
    pat = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    for i, line in enumerate(lines):
        if pat.match(line):
            lines[i] = f"{key} = {value}"
            break
    else:
        lines.append(f"{key} = {value}")
    write_text(path, lines, eol)


def set_config_section_line(path, section, key, value):
    text, eol = read_text(path)
    lines = text.split(eol)
    sec_pat = re.compile(r"^\s*\[" + re.escape(section) + r"\]\s*$", re.I)
    key_pat = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.I)
    sec_idx = next((i for i, l in enumerate(lines) if sec_pat.match(l)), None)
    if sec_idx is None:
        lines += [f"[{section}]", f"{key} = {value}"]
    else:
        end = next((i for i in range(sec_idx + 1, len(lines))
                    if lines[i].strip().startswith("[")), len(lines))
        for i in range(sec_idx + 1, end):
            if key_pat.match(lines[i]):
                lines[i] = f"{key} = {value}"
                break
        else:
            lines.insert(end, f"{key} = {value}")
    write_text(path, lines, eol)


# ------------------------------------------------------------ script runner

def run_script(text, ctx_dir):
    """ctx_dir: directory containing auxiliary files (.202 patches)."""
    for ln in text.splitlines():
        line = ln.strip().lstrip("﻿")
        if not line or line.startswith("//"):
            continue
        m = re.match(r"^(\w+)\s*(.*)$", line)
        if not m:
            log(f"  !! unparsable line: {line!r}")
            continue
        cmd, rest = m.group(1), m.group(2)
        args = re.findall(r'"([^"]*)"', rest)
        handle_command(cmd, args, ctx_dir, line)


def handle_command(cmd, args, ctx_dir, line):
    c = cmd.lower()
    if c == "createdirectory":
        path = resolve(args[0])
        os.makedirs(path, exist_ok=True)
        log(f"  CreateDirectory {path}")
    elif c == "applypatch":
        patch = ci_resolve(args[0], ctx_dir)
        target = resolve(args[1])
        apply_zt_patch(patch, target)
    elif c == "movefileswithextension":
        src = resolve(args[0]) if args[0] else GAME
        dst = resolve(args[1])
        ext = args[2].lower()
        os.makedirs(dst, exist_ok=True)
        n = 0
        if os.path.isdir(src):
            for e in os.listdir(src):
                p = os.path.join(src, e)
                if os.path.isfile(p) and e.lower().endswith(ext):
                    shutil.move(p, os.path.join(dst, e))
                    n += 1
        log(f"  MoveFilesWithExtension {ext}: {n} files -> {dst}")
    elif c == "createdesktopshortcut":
        log("  CreateDesktopShortcut: skipped (Linux)")
    elif c == "copydirectory":
        src, dst = resolve(args[0]), resolve(args[1])
        if os.path.isdir(src):
            shutil.copytree(src, dst, dirs_exist_ok=True)
            log(f"  CopyDirectory {src} -> {dst}")
        else:
            log(f"  CopyDirectory: source missing, skipped: {src}")
    elif c == "copyfile":
        src, dst = resolve(args[0]), resolve(args[1])
        if os.path.isfile(src):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            log(f"  CopyFile {args[0]} -> {args[1]}")
        else:
            log(f"  CopyFile: source missing, skipped: {src}")
    elif c == "deletefile":
        path = resolve(args[0])
        if os.path.isfile(path):
            os.remove(path)
            log(f"  DeleteFile {args[0]}")
        else:
            log(f"  DeleteFile: not present, skipped: {args[0]}")
    elif c in ("renamedirectory", "renamefile"):
        src = resolve(args[0])
        dst = os.path.join(os.path.dirname(src), args[1].split("\\")[-1])
        if os.path.exists(src):
            if src != dst:
                if os.path.abspath(src).lower() == os.path.abspath(dst).lower():
                    tmp = src + ".__case__"
                    os.rename(src, tmp)
                    os.rename(tmp, dst)
                else:
                    os.rename(src, dst)
                log(f"  Rename {args[0]} -> {args[1]}")
        else:
            log(f"  Rename: not present, skipped: {args[0]}")
    elif c == "appendline":
        path = resolve(args[0])
        text, eol = read_text(path)
        lines = text.split(eol)
        if not any(l.strip() == args[1].strip() for l in lines):
            if lines and lines[-1] == "":
                lines.insert(-1, args[1])
            else:
                lines.append(args[1])
            write_text(path, lines, eol)
        log(f"  AppendLine {args[0]}: {args[1]!r}")
    elif c == "replaceline":
        # ReplaceLine "file" <0-based-index> "text"
        mm = re.match(r'^"([^"]*)"\s+(\d+)\s+"([^"]*)"$',
                      line[len(cmd):].strip())
        fname, idx, text_new = mm.group(1), int(mm.group(2)), mm.group(3)
        path = resolve(fname)
        text, eol = read_text(path)
        lines = text.split(eol)
        old = lines[idx]
        lines[idx] = text_new
        write_text(path, lines, eol)
        log(f"  ReplaceLine {fname}[{idx}]: {old!r} -> {text_new!r}")
    elif c == "setconfigline":
        path = resolve(args[0])
        set_config_line(path, args[1], args[2])
        log(f"  SetConfigLine {args[0]}: {args[1]} = {args[2]}")
    elif c == "setconfigsectionline":
        path = resolve(args[0])
        set_config_section_line(path, args[1], args[2], args[3])
        log(f"  SetConfigSectionLine {args[0]} [{args[1]}]: {args[2]} = {args[3]}")
    else:
        raise RuntimeError(f"unknown script command: {line!r}")


# ------------------------------------------------------------------ extract

def extract_payload(zip_path):
    """Extract a Group zip into the game dir (case-insensitively).
    'OverwriteOn/...' is stripped; bare files land in the game root.
    Script.txt / *.202 zips are NOT handled here."""
    n = 0
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            name = info.filename.replace("\\", "/")
            if name.endswith("/"):
                continue
            parts = name.split("/")
            if parts[0].lower() == "overwriteon":
                parts = parts[1:]
            elif parts[0].lower() == "overwriteoff":
                parts = parts[1:]
                dest_probe = ci_resolve("/".join(parts))
                if os.path.exists(dest_probe):
                    continue
            if not parts:
                continue
            dest = ci_resolve("/".join(parts))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with z.open(info) as src, open(dest, "wb") as out:
                shutil.copyfileobj(src, out)
            n += 1
    log(f"  extracted {n} files from {os.path.basename(zip_path)}")


def run_script_zip(zip_path):
    """Extract a script-bearing Group zip to a temp dir and run Script.txt."""
    tmp = zip_path + ".extracted"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(tmp)
    spath = next(os.path.join(tmp, e) for e in os.listdir(tmp)
                 if e.lower() == "script.txt")
    text, _ = read_text(spath)
    log(f"-- running script from {os.path.basename(zip_path)}")
    run_script(text, tmp)


# --------------------------------------------------------------------- main

def install_package(pkg_dir, payload_names, finalize_names):
    for name in payload_names:
        p = os.path.join(pkg_dir, name)
        log(f"-- payload {name}")
        extract_payload(p)
    for name in finalize_names:
        run_script_zip(os.path.join(pkg_dir, name))


def main():
    global GAME, USERPROFILE, LOG
    import argparse
    ap = argparse.ArgumentParser(description="XWAU 2025 payload installer for Linux")
    ap.add_argument("game")
    ap.add_argument("userprofile")
    ap.add_argument("payloads", help="dir containing full/ and upd/ (the unzipped distribution zips)")
    ap.add_argument("--ratio", default="2", choices=["2", "3"],
                    help="Group_3_Ratio<N> finalize: 2 = 16:9 (default), 3 = alternative ratio")
    ap.add_argument("--preset", default="Ultra",
                    choices=["veryLow", "Low", "Medium", "High", "Ultra"],
                    help="special effects preset (default Ultra)")
    args = ap.parse_args()
    GAME = args.game
    USERPROFILE = args.userprofile
    base = args.payloads
    LOG = open(os.path.join(base, "xwau_install.log"), "w")

    os.makedirs(USERPROFILE, exist_ok=True)

    full = os.path.join(base, "full")
    upd = os.path.join(base, "upd")

    log("==== XWAU2025 Full 1.0.0 ====")
    run_script_zip(os.path.join(full, "Group_0_Prepare.zip"))
    payloads = ["Group_0_Application.zip", "Group_0_Main.zip"] + sorted(
        n for n in os.listdir(full) if n.startswith("Group_2_"))
    install_package(full, payloads, [
        "Group_3_Finalize.zip",
        f"Group_3_Ratio{args.ratio}.zip",
        f"Group_3_SpecialEffects_Presets_{args.preset}.zip",
    ])

    log("==== XWAU2025 UPD 1.1.0 ====")
    run_script_zip(os.path.join(upd, "Group_0_Prepare.zip"))
    payloads = ["Group_0_Main.zip"] + sorted(
        n for n in os.listdir(upd) if n.startswith("Group_2_"))
    install_package(upd, payloads, [
        "Group_3_Finalize.zip",
        f"Group_3_SpecialEffects_Presets_{args.preset}.zip",
    ])

    log("==== DONE ====")
    print("install complete; log at", os.path.join(base, "xwau_install.log"))


if __name__ == "__main__":
    main()
