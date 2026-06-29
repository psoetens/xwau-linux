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

- `hook-patcher-native/` — a native (unmanaged) C++ reimplementation of XWAU's
  managed `hook_patcher`. The upstream one is a managed IJW assembly that
  bootstraps the CLR in `DllMain`; the native port removes that so the game can
  run under **wine-mono** (no ~400 MB dotnet48 install). See its README.
- `hook-keyboard-bg/` — **hook_keyboard_bg.dll**: patches the DirectInput
  keyboard cooperative level FOREGROUND→BACKGROUND so the keyboard survives
  wine's focus juggling on Esc-to-menu. **Linux-only: do not install on
  Windows** (it would read keys while the game is unfocused).
- `tools/` — the launcher (`xwa-w64-launch.sh`; no sidecar pre-start).
- `docs/win64-architecture.md` — the win64 architecture (this branch).

## Releases

The [releases](../../releases) page carries the prebuilt, game-verified
Linux binaries (built from the PR branches above). An automated installer
script is in progress; until then the setup requires a manually prepared
win32 wine prefix with .NET 4.8 — full guide coming.

## Architecture: win64 (this branch)

The 32-bit game runs under **WoW64 in a win64 wine prefix**: the .NET hooks run
**in-process** (no sidecar), full-res skins fit, and HD concourse + HD video both
render. There is **no 2 GB VA ceiling** and no mission-entry memory-pressure crash
— the win32 mitigations (sidecar, skins downscale, preset clamp, raytracing-off)
are gone. See [docs/win64-architecture.md](docs/win64-architecture.md). The
historical win32 limitation is kept (win32-only) in
[docs/memory-pressure.md](docs/memory-pressure.md).

## Requirements (summary)

- Steam + X-Wing Alliance (appid 361670) + XWAU 2025
- **wine-11** (HD-video Media Foundation + the in-process hooks need it)
- A **win64** wine prefix with a CLR runtime: **wine-mono** (default) *or* dotnet48
- DXVK (32-bit DLLs for the WoW64 game) + 32-bit Vulkan drivers
- the win64 binaries (see the installer's open decisions — no win64 release yet)

## License

MIT (this repository). The prebuilt binaries are built from the MIT
upstream projects plus the PR branches above. `ShimBitmapPS.hlsl` inside
the ddraw binary is a port of xwa_hook_concourse's BitmapPixelShader
(see Prof-Butts/xwa_ddraw_d3d11#126 for provenance discussion).
