#!/bin/bash
# Build the native (unmanaged) hook_patcher.dll (mingw i686).
# Plan: .claude/plans/glowing-popping-penguin.md
set -e
cd "$(dirname "$0")"

CXX=i686-w64-mingw32-g++
COMMON="-O2 -std=c++17"

# The native hook DLL (replaces the managed hook_patcher.dll).
$CXX $COMMON -shared -include string.h -o hook_patcher.dll hook_patcher.cpp \
    -static -static-libgcc -static-libstdc++

echo "=== file ==="; file hook_patcher.dll
echo "=== exports (must be the 4 ABI names) ==="
i686-w64-mingw32-objdump -p hook_patcher.dll | sed -n '/\[Ordinal\/Name Pointer\] Table/,/^$/p'

# Parity harness EXE: same logic compiled with PARITY_MAIN, run under wine in the
# game dir to dump the emitted patches for comparison against the managed output.
$CXX $COMMON -DPARITY_MAIN -include string.h -o hook_patcher_paritydump.exe hook_patcher.cpp \
    -static -static-libgcc -static-libstdc++
echo "=== parity dumper ==="; file hook_patcher_paritydump.exe
