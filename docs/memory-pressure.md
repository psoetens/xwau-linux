# Memory pressure & the mission-entry crash (32-bit address space)

> **WIN32-ONLY (historical).** This entire problem class belongs to the `main`
> (win32) architecture. The `win64` architecture runs the game under WoW64 in a
> win64 prefix with **no 2 GB VA ceiling**, so the mission-entry memory-pressure
> crash, the sidecar, and the skins downscale are all **gone** there. Keep this
> doc for the win32 path; it does not apply to win64. See `win64-architecture.md`.

This document explains a real, partly-unavoidable fragility of running XWAU
2025 on Linux/wine: **32-bit virtual-address-space exhaustion**, which can
crash the game at mission entry. It records the causes, the evidence, what
mitigates it, and what does *not* — so the next person doesn't re-chase dead
ends we already ruled out.

## TL;DR

- The game runs as a **32-bit process** (`xwingalliance.exe`), so it has only
  ~2 GB of usable virtual address space (Large-Address-Aware is set).
- By the time you enter a flight mission, **~1.0–1.5 GB of that is already
  committed** (game engine heaps, the .NET CLR, in-process concourse
  animations, texture staging).
- Mission entry needs a **single ~64 MB contiguous** GPU allocation (the
  mission's skybox cubemap, e.g. `AzzameenSunrise`). If no 64 MB contiguous
  hole exists at that instant, DXVK's allocator fails and the game hangs
  (a "not responding" window) or crashes.
- This is **nondeterministic**: the largest free contiguous block oscillates
  (measured 31–128 MB), so the same install sometimes enters the mission fine
  and sometimes doesn't. "It works" is not the same as "it's robust."

## Why 32-bit at all

XWAU's `.NET` hooks host the CLR from `DllMain`. That only works in a **win32
wine prefix** with real .NET 4.8 — on a win64 prefix it aborts
(`mscorwks!CorDllMainForThunk`) or fails to wire (wine-mono → null deref).
So the whole setup is pinned to win32, which is where the 2 GB ceiling comes
from. There is no in-process way around the ceiling; see "the real fixes".

## What consumes the address space (measured)

A per-phase address-space census (`VirtualQuery` walk, bucketed by region
type) taken in the concourse just before a mission load:

| Bucket | Size | Notes |
|---|---|---|
| **PRIVATE** (heap/commit) | **~1.0–1.5 GB**, oscillating | the dominant consumer |
| IMAGE (loaded DLLs) | ~127 MB, stable | .NET CLR (`mscorlib.ni`, `clr.dll`, `System.ni`), `xwingalliance.exe` |
| MAPPED (file/section) | ~16 MB | small — the concourse video is **not** a file mapping |
| Largest **free contiguous** block | **31–128 MB**, oscillating | the number that matters for the 64 MB alloc |

The private commit is a **scatter**, not one block: a ~39 MB region plus a
cluster of ~10 MB regions (game heaps, decoded concourse-animation frames,
texture staging). Fragmentation — not just total usage — is what kills the
64 MB contiguous request.

## Biggest contributing factor: in-process concourse animations

XWAU's `hook_concourse` loads ~300 MB of WebM concourse/briefing animations
and, on Windows, runs them **out-of-process** (`XwaConcoursePlayer.exe`), so
that memory never touches the game. Under wine that side process can't run
(its D3D11 shared handles are broken), so XWAU falls back to loading the
animations **in-process** — putting the ~300 MB squarely in the game's 2 GB.

Worse, the hook's `WebmFreeAllVideos()` (which would free them on the
concourse→mission transition) is a **no-op** — its body was deliberately
commented out upstream (commit `f289b67`, "hook_concourse: fix webm"),
presumably because freeing-then-reloading caused a crash. On Windows that
leak is harmless (it's isolated in the side process); on wine it stays in the
game for the whole session. This is the single largest reclaimable chunk, but
it lives in upstream's unlicensed hook — we can't ship a fix for it.

## Mitigations applied (in the installer / config)

These reduce commit or avoid the worst spikes, and are why the game is
playable at all:

- **HD-OPT side-load player** (`Xwa32bppPlayer32`, `[hook_32bpp]
  EnableSideProcess=1`): moves ~340 MB of skinned-OPT processing **out** of
  the game's address space. This one *does* work under wine (unlike the
  concourse side process).
- **`SkinsSizeThreshold = 100 MB`** (`Xwa32bppPlayer32.cfg`): downscales
  skin textures so no single OPT transfer needs a >100 MB contiguous region.
- **Raytracing + HDR off** (`SSAO.cfg`): the BVH build at mission entry was a
  large extra allocation; disabling it removed a crash.
- **Graphics preset defaults to `Medium`** (installer `--preset`): higher
  presets (High/Ultra) commit more private memory (effect buffers, texture
  caches), thinning the margin. Medium leaves more headroom. Note: the skybox
  *cubemap assets are identical across presets* — the preset helps via
  general commit, not via the cubemap size.

## What does NOT help (ruled out — don't re-chase)

- **`dxvk.maxChunkSize`**: tested at 16 MiB, confirmed active in DXVK's
  effective config — but the 64 MB skybox is allocated as a **dedicated**
  resource that bypasses the chunk pool, so it still failed. Refuted.
- **Skybox cubemap resolution / preset cubemaps**: the `AzzameenSunrise`
  faces are **byte-identical** across installs/presets. Not the variable.
- **Freeing our own movie buffers** (`_tgSmushTex` ~15 MB + TgSmush
  `s_colors` ~14 MB): correct improvements, but ~29 MB is marginal against a
  64 MB cliff. (Parked; may be offered upstream separately.)
- **It is not a growing leak**: free VA recovers between phases (e.g. dips to
  31 MB, climbs back to 101 MB). It's transient peak pressure + fragmentation,
  not monotonic loss.

## The real fixes (not available to us today)

1. **Re-enable `WebmFreeAllVideos` upstream** (or stream concourse animations
   instead of caching all ~300 MB). Reclaims the single biggest chunk for
   in-process/wine users. This is a question for the XWAU hooks author
   (whether freeing can be made safe again).
2. **Run win64 / new-WOW64**: no 32-bit ceiling at all. Blocked today by the
   CLR-in-`DllMain` requirement; worth re-testing on each major wine release.

## Reproducing / diagnosing

The crash signature in the game log (`~/xwa-linux.log`) is:

```
err: DxvkMemoryAllocator: Memory allocation failed
err:   Size: 67108864          # 64 MB — the skybox cubemap
```

To see the address-space breakdown live, a debug build of `ddraw_effects`
can log a `[VACENSUS]` census on a timer (committed memory by type + the
largest regions with owning module). It is not in the shipped binary; it
lives only on a local diagnostic branch.

## Practical advice for users

- If the game crashes entering a mission, **lower the graphics preset** and
  retry — it widens the margin.
- A mission that crashed once may load on a second try (the margin is
  nondeterministic).
- Do not raise `SkinsSizeThreshold` above ~100 MB or re-enable raytracing on
  this 32-bit setup unless you enjoy crashes.
