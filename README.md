# XWAU 2025 on Linux

**Status: fully playable** — X-Wing Alliance (Steam) with the
[XWAU 2025](https://www.xwaupgrade.com/) mod running end-to-end on
Linux/wine: HD concourse with crisp text, 30fps HD cutscenes, briefings,
missions and the simulator. User-verified over many sessions (2026-06).

This repository hosts the Linux-specific pieces and (soon) a one-script
installer. The substantive fixes live as pull requests against the XWAU
code repositories, designed so that the **stock Windows builds are
byte-for-byte unaffected** — Linux behavior comes from runtime wine
detection and config keys whose defaults preserve stock behavior:

| Where | What |
|---|---|
| [Prof-Butts/xwa_ddraw_d3d11#125](https://github.com/Prof-Butts/xwa_ddraw_d3d11/pull/125) | portability fixes (enables non-MSVC builds) |
| [Prof-Butts/xwa_ddraw_d3d11#126](https://github.com/Prof-Butts/xwa_ddraw_d3d11/pull/126) | WineD2DEffectShim: HD concourse + swapchain movie present under wine |
| [JeremyAnsel/xwa_TgSmush#4](https://github.com/JeremyAnsel/xwa_TgSmush/pull/4) | bugfixes + configurable backends + MF D3D-present mode |
| [JeremyAnsel/xwa_hooks#20](https://github.com/JeremyAnsel/xwa_hooks/issues/20) | findings + out-of-process hooks discussion (the path to vanilla Proton) |
| WineHQ (pending) | d2d1: custom effects render nothing — report + proposed patches |

## What's in this repo

- `player/` — **Xwa32bppPlayer32**: a 32-bit out-of-process port of the XWAU
  HD-OPT sideload player (mingw C++ CLR host + C# bridge). Required because
  the Linux setup uses a 32-bit wine prefix (the .NET hooks host the CLR in
  DllMain, which only works there), and the upstream x64 player cannot run
  in it. Includes `DownscaleToFit`: skinned-OPT textures are halved until the
  blob fits a configurable cap — a 32-bit address space under wine cannot
  take the full-size blobs (`SkinsSizeThreshold` in `Xwa32bppPlayer32.cfg`).
- `hook-keyboard-bg/` — **hook_keyboard_bg.dll**: patches the DirectInput
  keyboard cooperative level FOREGROUND→BACKGROUND so the keyboard survives
  wine's focus juggling on Esc-to-menu. **Linux-only: do not install on
  Windows** (it would read keys while the game is unfocused).
- `tools/` — the launcher (GE-Proton8-26 provides both wine and codecs;
  win32 prefix with real .NET 4.8).

## Releases

The [releases](../../releases) page carries the prebuilt, game-verified
Linux binaries (built from the PR branches above). An automated installer
script is in progress; until then the setup requires a manually prepared
win32 wine prefix with .NET 4.8 — full guide coming.

## Known limitation: 32-bit memory pressure

Because the setup is pinned to a 32-bit wine prefix (XWAU's .NET hooks host
the CLR in `DllMain`, which only works there), the game can occasionally run
out of address space entering a mission. It is nondeterministic and largely
mitigated by the installer defaults (Medium preset, skin-size cap, raytracing
off, out-of-process OPT loader). Causes, evidence, and what does/doesn't help
are documented in [docs/memory-pressure.md](docs/memory-pressure.md).

## Requirements (summary)

- Steam + X-Wing Alliance (appid 361670) + XWAU 2025
- GE-Proton8-26 (its wine runs the game *and* decodes the H.264 cutscenes)
- A 32-bit wine prefix with real .NET Framework 4.8 (winetricks `dotnet48`)
- 32-bit Vulkan drivers (any Steam install has them)

## License

MIT (this repository). The prebuilt binaries are built from the MIT
upstream projects plus the PR branches above. `ShimBitmapPS.hlsl` inside
the ddraw binary is a port of xwa_hook_concourse's BitmapPixelShader
(see Prof-Butts/xwa_ddraw_d3d11#126 for provenance discussion).
