#!/bin/bash
# Compile the managed bridge (Xwa32bppPlayerNet32.dll) with the win32 prefix's
# own .NET 4.8 csc (C#5). Referenced by the Makefile comment ("make net");
# reconstructed 2026-06-07 (plan magical-jumping-pascal).
# NB: csc under wine needs BACKSLASH source paths — forward slashes get the
# directory component silently stripped (CS1504 in the parent dir).
set -e
cd "$(dirname "$0")"
P8="/home/kaltan/src/SteamLibrary/steamapps/common/Proton 8.0"
env WINEPREFIX="$HOME/.local/share/xwa-prefix" WINEDEBUG=-all \
    LD_LIBRARY_PATH="$P8/dist/lib:$P8/dist/lib64" \
    "$P8/dist/bin/wine" 'C:\windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' \
    /nologo /target:library /unsafe \
    /out:Xwa32bppPlayerNet32.dll \
    /reference:JeremyAnsel.Xwa.Opt.dll \
    /reference:System.IO.Compression.dll \
    /reference:System.IO.Compression.FileSystem.dll \
    'cs\Bridge.cs' 'cs\Main.cs' 'cs\XwaHooksConfig.cs'
ls -la Xwa32bppPlayerNet32.dll
