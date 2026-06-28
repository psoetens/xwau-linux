# hook-patcher-native

A native (unmanaged) C++ reimplementation of XWA's `hook_patcher` hook.

## Why

On the win64 architecture the game can run under **wine-mono** (which ships with
wine) instead of a ~400 MB **dotnet48** winetricks install — *except* it
deadlocked at startup. The trigger was traced to **`hook_patcher.dll` itself
being a managed (.Net) IJW assembly**: the dinput hook-loader `LoadLibrary`s it
during the loader-lock-held startup storm, its `mscoree._CorDllMain` bootstrap
starts the CLR in `DllMain`, and wine-mono's `mono_runtime_init` creates and
waits for GC/finalizer threads while the loader lock is held → circular deadlock.
(dotnet48's mscoree is loader-lock-safe, so it only deadlocks on wine-mono.)

`hook_patcher` does no managed work — it is purely a **data-driven byte-patcher**.
Reimplementing it natively removes the storm-time CLR bootstrap. With it native,
the only remaining CLR users are the CLR-hosting `_net` shims, which start the CLR
**lazily** on the first managed call (a lock-free point) and do not deadlock.
Result: the game runs end-to-end on wine-mono with no dotnet48.

## What it does (faithful to upstream `hook_patcher`)

- Reads `hook_patcher.xml` and every `patcher-xml/*.xml` (merged) for patch
  definitions: `<Patch Name="..."><Item Offset="hex" From="hex" To="hex"/></Patch>`.
- Reads `hook_patcher.txt` enable flags (`<patch name> = <nonzero>`).
- Returns the enabled patches via the standard native hook ABI
  (`GetHookFunctionsCount` → 0, `GetHookFunction` → {}, `GetHookPatchesCount`,
  `GetHookPatch` → `const HookPatch*`). `HookPatch.Name` is prefixed
  `"[hook_patcher] "`; `From`/`To` pass through as hex strings (the dinput
  applier parses the hex and verifies `From`|`To` before writing).

Verified **byte-for-byte identical** to the managed `hook_patcher.dll` output via
`generic_dump.cpp` (a `LoadLibrary`-based ABI dumper) on both the deployed config
and a richer multi-patch case.

## Build

    ./build-hook.sh        # -> hook_patcher.dll (mingw i686) + hook_patcher_paritydump.exe

Requires `i686-w64-mingw32-g++`. Deploy `hook_patcher.dll` next to the game exe in
place of the managed one.

## Licensing note

`hook_patcher.cpp` includes a small copy of the upstream hooks' INI config parser
(`GetFileLines`/`GetFileKeyValueInt`) and reimplements the upstream `hook_patcher`
ABI/behavior. The upstream XWA hooks are unlicensed; this is kept **local /
unpublished** pending the upstream maintainers' stance. It is intended as a clean
upstream proposal (loader-lock-safe; no functional change on Windows).
