# Win64 architecture (the simplified path)

**Status: experimental branch (`win64`). Verified 2026-06-28.**

An XWAU developer pointed out that XWAU runs in a **64-bit wine prefix** (with
.NET 4.8 + new-WOW64), and testing confirmed it. This collapses most of the
complexity the `main` (win32) branch carries.

## The finding that changes everything

We had believed XWAU was pinned to a **win32 prefix** because the .NET hooks
host the CLR from `DllMain` (a loader-lock violation that aborted on the
win64 Proton containers we tested). That belief was **wrong for new-WOW64**:

- On `wine-11.10` with true **new-WOW64**, the in-process .NET hooks
  (`[hook_32bpp] EnableSideProcess=0`, no sidecar) load and run fine — **no
  `CorDllMainForThunk` abort.**
- Because the game then has a normal 64-bit-hosted address space, the **2 GB
  ceiling is gone** — the `AzzameenSunrise` skybox allocation that crashed
  every mission entry on win32 succeeds, with zero `DxvkMemoryAllocator`
  failures.

(The precise mechanism, for the upstream conversation: the native hooks pull
in their C# logic via a global-static `NetFunctions g_netFunctions`
constructor that `LoadLibrary`s the `[DllExport]` `_net` assembly under the
loader lock — `concourse.cpp:473`/`:426`, `32bpp.cpp:192`. It happens to
survive new-WOW64; deferring it out of the ctor would be best practice but is
not required to run on win64.)

## What win64 makes unnecessary (to be removed when stabilizing)

| win32 workaround | Why it existed | win64 status |
|---|---|---|
| Sidecar `Xwa32bppPlayer32` (`EnableSideProcess=1`) | keep ~340 MB OPT processing out of the 2 GB space | **drop** — in-process works |
| Skins downscale (`SkinsSizeThreshold`) | full-res OPTs didn't fit | **drop** — full-res fits |
| 32-bit wine prefix | CLR-in-DllMain only worked on win32 | **drop** — use win64 prefix |
| `Medium` preset / raytracing-off defaults | reduce memory pressure | **revisit** — likely can raise |
| The whole mission-entry memory-pressure crash class | 32-bit VA exhaustion | **gone** |

## What still works on win64 (verified)

- Missions, briefings, full-res skins (in-process, no downscale)
- HD cutscene video via TgSmush MF + swapchain present (30 fps)
- No sidecar, no memory crash

## The one open problem: HD concourse

HD concourse does **not** render on wine yet, on any approach — it's a
wine Direct2D **custom-effect** gap, independent of bitness:

- stock wine: custom effect draws nothing (renders black);
- our `WineD2DEffectShim` (a wine-8 stopgap): on wine-11 it feeds wine a
  foreign `ID2D1Bitmap` and trips wine's `bitmap.c` assert;
- our experimental wine d2d1 patch: a partial single-draw-transform
  implementation that the headless probe passed but hook_concourse's real
  usage crashes (null-deref in `d2d_device_context_draw_effect`).

**Run with `HDConcourseEnabled = 0` for now.** Proper HD concourse needs
either real d2d custom-effect support in wine, or a reworked shim that does
all concourse drawing on the D3D11 side and never hands wine a foreign
bitmap. Tracked as the phase-2 investigation below.

## Roadmap

**Phase 1 — stabilize win64 (remove win32 workarounds):**
- Win64 installer variant: win64 prefix + dotnet48 + new-WOW64 wine; in-process
  hooks (`EnableSideProcess=0`); no sidecar binary; no skins downscale; HD
  concourse off; revisit graphics preset.
- Win64 launcher: `tools/xwa-w64-launch.sh` (this branch).
- Verify the full flow (intro → concourse(non-HD) → missions → video) on a
  clean win64 install.

**Phase 2 — investigate HD concourse:**
- Decide between (a) reworking the shim to bypass wine d2d entirely for the
  effect, or (b) pursuing real wine custom-effect support, or (c) an upstream
  hook change. Likely an upstream conversation with JeremyaFr.
