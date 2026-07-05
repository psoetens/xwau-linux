# XWAU 2025 on Linux

**Status: fully playable** — X-Wing Alliance with the
[XWAU 2025](https://www.xwaupgrade.com/) mod running end-to-end on
Linux/wine: HD concourse with crisp text, 30fps HD cutscenes, briefings,
missions and the simulator. Works with both the **GOG** and **Steam**
versions of the game.

This repository hosts the Linux-specific pieces and a one-script installer.
The substantive fixes live as pull requests against the XWAU code
repositories, designed so that the **stock Windows builds are
byte-for-byte unaffected** — Linux behavior comes from runtime wine
detection and config keys whose defaults preserve stock behavior:

| Where | What |
|---|---|
| [Prof-Butts/xwa_ddraw_d3d11#125](https://github.com/Prof-Butts/xwa_ddraw_d3d11/pull/125) | portability fixes (enables non-MSVC builds) |
| [Prof-Butts/xwa_ddraw_d3d11#126](https://github.com/Prof-Butts/xwa_ddraw_d3d11/pull/126) | WineD2DEffectShim: HD concourse + swapchain movie present under wine |
| [JeremyAnsel/xwa_TgSmush#4](https://github.com/JeremyAnsel/xwa_TgSmush/pull/4) | bugfixes + configurable backends + MF D3D-present mode |
| [JeremyAnsel/xwa_hooks#20](https://github.com/JeremyAnsel/xwa_hooks/issues/20) | findings + out-of-process hooks discussion |
| WineHQ (pending) | d2d1: custom effects render nothing — report + proposed patches |

## Which installer do I use?

Two installers — **pick the one for where you own the game:**

- **Steam → `install-xwau-steam.sh`** . Uses
  Steam's **Proton** (≥ wine-11: "Proton Hotfix" / "Experimental" / "Proton 11"),
  which already provides wine-11 + DXVK + libvkd3d + gstreamer codecs +
  wine-mono in its Steam Linux Runtime container. The script lays down the
  game files + config and **auto-configures Steam** (sets the Proton compat
  tool + Launch Options for you — **Steam must be closed**; if it's running it
  tells you to re-run with `--steam-config-only`). No bundled wine. (Be
  patient on the first launch — it compiles the DXVK shader cache and can look
  frozen for a minute; later launches are fast.)

- **GOG (or any non-Steam copy) → `install-xwau-linux.sh`** .
  Bundles **Kron4ek wine-11** + **wine-mono**, and uses a **GE-Proton** as the
  DXVK + gstreamer-codec donor. It builds its own wine prefix and writes a
  launcher — no Steam required. See the GOG setup below.

Both installers need the two XWAU 2025 zips, which you download yourself from
[xwaupgrade.com](https://www.xwaupgrade.com/): `XWAU2025_Full_1.0.0.zip` and
`XWAU2025_UPD_1.1.0.zip`. By default the installer **downloads the prebuilt
Linux binaries from the latest release**; pass `--bin-dir` only if you want to
use a local build instead.

## Get the installer

You don't need `git` — grab the release tarball and unpack it (the installer is
a small tree of scripts, not a single file, so download the whole thing):

```bash
curl -fL https://github.com/psoetens/xwau-linux/archive/refs/tags/v0.4.3.tar.gz | tar xz
cd xwau-linux-0.4.3
```

That tag's scripts are pinned to download the matching prebuilt binaries, so the
two always stay in sync. For a different version, swap `v0.4.3` for any tag on
the [Releases](https://github.com/psoetens/xwau-linux/releases) page.

If you *do* have `git` (e.g. to contribute or track `main`):

```bash
git clone https://github.com/psoetens/xwau-linux.git
cd xwau-linux
```

## GOG users: installation instructions

### Download game + extract

Download the **offline backup installer** from your GOG account — the file
named like `setup_star_wars_-_x-wing_alliance_2.02_(NNNNN).exe`. Do **not**
use the small "GOG Galaxy" installer stub: it only downloads the game at
runtime and can't be unpacked offline.

The offline installer is an Inno Setup archive — unpack it on Linux with
`innoextract` (no Wine needed):

```bash
sudo apt install innoextract          # or your distro's package
cd ~/Downloads                         # wherever the setup exe lives
innoextract -I app "setup_star_wars_-_x-wing_alliance_2.02_(NNNNN).exe" # replace NNNNN with the actual filename number
# -> creates ./app/ with the vanilla game (Alliance.EXE, XWINGALLIANCE.EXE, ...)
```

That `app/` directory is your game dir — pass it as `--game-dir` below.

### Install Example for GOG

```bash
./install-xwau-linux.sh \
  --game-dir  ~/Downloads/app \
  --xwau-full ~/Downloads/XWAU2025_Full_1.0.0.zip \
  --xwau-upd  ~/Downloads/XWAU2025_UPD_1.1.0.zip
```

This builds the wine prefix, installs XWAU 2025 into the game dir (keeping a
`.vanilla` backup next to it), downloads the Linux binaries from the release,
and writes an `xwa-linux-launch.sh` launcher into the game dir.

### Run for GOG

Go into your `app/` directory and run the launch command:

```bash
cd ~/Downloads/app
./xwa-linux-launch.sh
```

## Steam users: installation instructions

### Purchase and Download the game

In you steam library purchase and **download** the original 'STAR WARS: X-Wing Alliance' game.

**Then close Steam.**

### Install Example for Steam

```bash
./install-xwau-steam.sh \
  --xwau-full ~/Downloads/XWAU2025_Full_1.0.0.zip \
  --xwau-upd  ~/Downloads/XWAU2025_UPD_1.1.0.zip
```

The script will find your Steam installation from above and do the proper steps. If
you did not close Steam, it will refuse to run.

### Run from Steam

Re-launch steam and press the PLAY button of the 'STAR WARS: X-Wing Alliance' game.

## Uninstalling

`--remove` restores the **original (vanilla)** game from the backup the installer
made at first run (kept alongside the game dir as `<game-dir>.vanilla`):

```bash
./install-xwau-steam.sh --remove          # Steam copy
./install-xwau-linux.sh --remove          # GOG / standalone copy
```

- On **Steam**, it also clears the compat tool + launch options the installer
  set, so **Steam must be fully closed** — the installer **aborts up front** if
  Steam is running (pass `--no-steam-config` to skip touching Steam's config and
  run with Steam open).
- The Proton prefix (`compatdata/<appid>`) and the standalone wine prefix are
  **left in place** — they're reused on the next launch/install. Delete them
  yourself if you want a completely clean slate.
- Your **pilots and settings are kept** — the installer preserves your pilots
  (`UserData/XWAU/Pilot/`) and config files (`config.cfg`, effect/cockpit `.cfg`s,
  etc.) across the restore. Only `Hooks.ini` is regenerated (it's mod-managed;
  your resolution/preset choices come back from the recorded install options).
- Note: a pilot kept after `--remove` stays in the XWAU location
  (`UserData/XWAU/Pilot/`). The pilot *format* is identical to the original
  game, but a pure-vanilla X-Wing Alliance looks for pilots in the game root —
  copy the `.plt` there if you want to fly it without the mod.

## Upgrading (reinstall)

`--reinstall` reuses the XWAU zip paths and options (ratio /
preset / resolution) recorded in `<game-dir>/.xwau-install.json` at first install,
so you don't re-pass the ~6.6 GB `--xwau-full` / `--xwau-upd` arguments:

```bash
cd xwau-linux-0.4.3                        # the newer release you downloaded
./install-xwau-steam.sh --reinstall        # tears down the old version, installs this one
```

- To **upgrade**: download the newer release (see [Get the installer](#get-the-installer)),
  `cd` into it, and run `--reinstall`. It cleans up the currently-installed
  version and lays down the new one — reusing the mod zips you already have.
- **Your pilots and settings carry over** — reinstall preserves your pilots and
  config files and re-applies the new version's required settings on top; only
  `Hooks.ini` is regenerated.
- Pass `--xwau-full` / `--xwau-upd` (or `--ratio` / `--preset` / `--resolution`)
  to **override** what the manifest recorded — e.g. if you moved the zip files.
- If you first installed with a build that predates the manifest (no
  `.xwau-install.json` in the game dir), the first `--reinstall` needs
  `--xwau-full` / `--xwau-upd` passed explicitly; after that it's recorded.
- On Steam, **close Steam first** (same reason as `--remove`).

## Troubleshooting

- **HD cutscenes are black (audio only):** GE's 32-bit cutscene codecs need a
  slice of the host's **32-bit (multilib) userland** that GE itself does not
  ship. The standalone installer checks for it up front — *before* any large
  download — and if it's missing it stops and prints the exact one-line
  `apt`/`dnf`/`pacman` command to install it (pass `--skip-codec-check` to
  install anyway with audio-only cutscenes). Two libraries are staged
  automatically into `<game-dir>/.linux-lib32/` because no distro ships them
  under the name GE wants — `libvpx.so.6` (soname retired everywhere) and
  `libbz2.so.1.0` (Fedora patches bzip2's soname to `libbz2.so.1`); if neither
  a local copy nor the release asset is available, drop them there by hand.
  Note on immutable/atomic distros (Bazzite, Silverblue): the needed 32-bit
  libs usually ship preinstalled, so this rarely triggers — avoid layering
  codec libs with `rpm-ostree` unless the check actually flags something.
- **The game exits immediately:** X-Wing Alliance quits if no
  joystick/controller is connected — plug one in.

## What's in this repo

- `hook-patcher-native/` — a native (unmanaged) C++ reimplementation of XWAU's
  managed `hook_patcher`. The upstream one is a managed IJW assembly that
  bootstraps the CLR in `DllMain`; the native port removes that so the game can
  run under **wine-mono** (no ~400 MB dotnet48 install). See its README.
- `installer/` — shared installer logic (`common.sh`, Steam auto-config).
- `tools/` — the standalone launcher template.
- `docs/` — [architecture notes](docs/win64-architecture.md) and the historical
  32-bit [memory-pressure limitation](docs/memory-pressure.md).

## Requirements (summary)

- X-Wing Alliance (GOG or Steam) + the XWAU 2025 zips
- **wine-11** — needed for HD-video Media Foundation and the in-process hooks.
  The standalone installer bundles it (Kron4ek); the Steam installer uses Proton.
- A CLR runtime in the prefix: **wine-mono** (default) *or* dotnet48
- DXVK (32-bit DLLs for the game) + 32-bit Vulkan drivers


## License

MIT (this repository). The prebuilt binaries are built from the MIT
upstream projects plus the PR branches above. `ShimBitmapPS.hlsl` inside
the ddraw binary is a port of xwa_hook_concourse's BitmapPixelShader
(see Prof-Butts/xwa_ddraw_d3d11#126 for provenance discussion).
