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

## GOG users: prepare the game from the offline installer

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

## Example: install for a GOG copy

```bash
./install-xwau-linux.sh \
  --game-dir  ~/Downloads/app \
  --xwau-full ~/Downloads/XWAU2025_Full_1.0.0.zip \
  --xwau-upd  ~/Downloads/XWAU2025_UPD_1.1.0.zip
```

This builds the wine prefix, installs XWAU 2025 into the game dir (keeping a
`.vanilla` backup next to it), downloads the Linux binaries from the release,
and writes an `xwa-linux-launch.sh` launcher into the game dir. Then just:

```bash
~/Downloads/app/xwa-linux-launch.sh
```

(Steam owners skip all of the above — `install-xwau-steam.sh` auto-detects the
game and wires up Steam's Launch Options.)

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

## Troubleshooting

- **HD cutscenes are black (audio only):** the standalone installer runs a
  post-install check that names any missing 32-bit codec library. GE-Proton
  ships everything except a 32-bit `libvpx.so.6`; the installer stages one if
  it can find a local copy, otherwise drop a 32-bit `libvpx.so.6` into
  `<game-dir>/.linux-lib32/`.
- **The game exits immediately:** X-Wing Alliance quits if no
  joystick/controller is connected — plug one in.

## License

MIT (this repository). The prebuilt binaries are built from the MIT
upstream projects plus the PR branches above. `ShimBitmapPS.hlsl` inside
the ddraw binary is a port of xwa_hook_concourse's BitmapPixelShader
(see Prof-Butts/xwa_ddraw_d3d11#126 for provenance discussion).
