# Win64 architecture (the simplified, current path)

**Status: `win64` branch. Validated end-to-end 2026-06-29.**

The win64 architecture replaces the entire fragile 32-bit workaround stack the
`main` (win32) branch carries. The 32-bit game runs under **WoW64 in a win64
prefix**, the .NET hooks run **in-process** (no sidecar), full-res skins fit (no
downscale), and **HD concourse + HD video both render**. There is no 2 GB VA
ceiling and no mission-entry memory-pressure crash class.

## What's validated (wine-11.10)

- Game, briefings, **full-res skins** in-process (`EnableSideProcess=0`, no sidecar)
- **HD cutscene video** (TgSmush → Media Foundation → swapchain present, 30 fps)
- **HD concourse** — renders via the force-shim ddraw (see below)
- No sidecar process, no skins downscale, no VA crash
- Runs on **either CLR runtime**: dotnet48 *or* wine-mono (see below)
- WoW64 mode is **not** a factor — both old-WoW64 (multilib) and new-WOW64 builds
  of wine-11 work (an earlier "needs new-WOW64" belief was a confound).

## Wine floor: wine-11

wine-11 is required (not just preferred):
- **HD video** needs wine-11's Media Foundation H.264 decoder MFT (wine-10 lacks it).
- The in-process hook CLR-hosting matured by wine-11.

wine-10/GE10 runs the **game only** (no HD video) via the native CLR-hosting shims.

## CLR runtime: dotnet48 or wine-mono

The hooks need a CLR. Two options, both validated:

- **dotnet48** — proven; ~400 MB winetricks install; loader-lock-safe `mscoree`.
- **wine-mono** (ships with wine) — drops the install. It used to **deadlock** at
  startup (mono's runtime init isn't loader-lock-safe and a managed hook bootstraps
  the CLR in `DllMain` during the load storm). Root cause was traced to
  **`hook_patcher.dll` being a managed IJW assembly**; replacing it with a
  **native (unmanaged) `hook_patcher`** removes the storm-time CLR bootstrap, after
  which the only CLR start is the hooks' own lazy, lock-free path — no deadlock.
  Validated end-to-end 2026-06-29.

The native CLR-hosting **hook shims** (`hook_32bpp_net` / `hook_concourse_net` host
the CLR explicitly instead of the upstream `[DllExport]` IJW mechanism) are what
let the hooks run on wine-10/11 and under wine-mono.

## HD concourse (solved 2026-06-29)

HD concourse uses a Direct2D **custom effect**, which wine's d2d1 can't render. We
ship `WineD2DEffectShim` inside `ddraw_effects`: on wine it renders the effect via
native **D3D11** instead. The wine-8 version "tried real wine d2d1 first," which on
wine-11 leaked a foreign `ID2D1Bitmap` into wine and tripped a `bitmap.c` assert.
The fix (**force-shim-on-wine**): under wine, force shim mode up front so the effect
is always our `ShimEffect` and every draw goes through D3D11 — wine's d2d1 never
sees a foreign object. `HDConcourseEnabled=1` now works on wine-11.

## What win32 carried that win64 drops

| win32 workaround | Why it existed | win64 |
|---|---|---|
| Sidecar `Xwa32bppPlayer32` (`[hook_32bpp] EnableSideProcess=1`) | keep ~340 MB OPT work out of the 2 GB space | **dropped** — in-process |
| Skins downscale (`SkinsSizeThreshold`) | full-res OPTs didn't fit | **dropped** — full-res fits |
| 32-bit wine prefix | belief that CLR-in-DllMain needed win32 | **dropped** — win64 prefix |
| SSAO raytracing/HDR force-off, `Medium` preset clamp, `dxvk.maxFrameRate` cap | reduce 32-bit VA pressure | **dropped** — no VA ceiling (default preset raised to High) |
| mission-entry memory-pressure crash class | 32-bit VA exhaustion | **gone** |

## Installers (two paths)

Shared logic lives in `installer/common.sh` (payload replay, win64 binary overlay,
config overlay: `HDConcourseEnabled=1`, `EnableSideProcess=0`, fonts, TgSmush).

- **`install-xwau-steam.sh` — Steam/Proton (recommended).** Uses Steam's Proton
  (≥ wine-11: Proton Hotfix / Experimental / Proton 11), which supplies wine-11 +
  DXVK + libvkd3d + gstreamer codecs + wine-mono in its container. Lays down
  files+config, then **auto-configures Steam** via `installer/steam_config.py`
  (targeted `config.vdf` CompatToolMapping → `proton_11` + `localconfig.vdf`
  LaunchOptions = `WINEDLLOVERRIDES="ddraw=n,b;dinput=n,b;dinput8=n,b;windowscodecs=b"
  %command%`; Steam must be closed — `--steam-config-only` resume otherwise; backups +
  brace-balance re-validate). The launcher (`alliance.exe`, JeremyAnsel's Alliance
  2.5.0.0) is kept — it spawns 3 idle side-loader windows (harmless; the game ignores
  them); the first launch compiles DXVK shaders (slow/one-time — documented, not a
  runtime popup: wrapping `%command%` to show a notice broke the Proton launch, so we
  don't). No bundled wine, no prefix creation. Validated: full clean install
  user-verified to the HD concourse.
- **`install-xwau-linux.sh` — Kron4ek standalone.** Downloads Kron4ek wine-11
  (default 11.11, sha256-verified) + installs wine-mono, uses a GE-Proton as the
  DXVK/gstreamer donor, builds a win64 prefix, and writes a bare launcher
  (`tools/xwa-w64-launch.sh` is the in-process template). Validated this session:
  Kron4ek wine-11.11 runs the game bare, clean.

## Open decisions before shipping (see installer header)

1. **Wine source** — which redistributable wine-11 to bundle (Kron4ek standalone is
   the front-runner). The installer currently defaults to a local `--wine-dir`.
2. **Runtime default** — wine-mono (recommended) vs dotnet48.
3. **win64 binary release** — the win64 binaries (force-shim `ddraw_effects`, native
   `hook_patcher`, the CLR-hosting shims) aren't in release v0.1.0 (win32). The
   installer installs them from a local `--bin-dir`; a win64 release is needed to
   ship.

## Upstream-relevant pieces (not Linux-only)

- `WineD2DEffectShim` force-shim → ddraw fork PR (#126 branch).
- Native `hook_patcher` + the CLR-hosting shim concept → JeremyaFr (xwa_hooks).
