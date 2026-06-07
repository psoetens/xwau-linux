# 32-bit Xwa32bppPlayer port (plan controller-and-briefing-fixes N5-B).
# Native parts: mingw i686. Managed part: the win32 prefix's own .NET 4.8
# csc.exe (C# 5) — run `make net` with the launcher env (see run-csc.sh).

CXX := i686-w64-mingw32-g++
CXXFLAGS := -O2 -std=c++17 -DUNICODE -D_UNICODE
LDFLAGS := -static -static-libgcc -static-libstdc++

OUT := /home/kaltan/src/SteamLibrary/build/xwa32bpp-player

all: $(OUT)/Xwa32bppPlayer32.exe $(OUT)/hook32_probe.exe

$(OUT)/Xwa32bppPlayer32.exe: player32.cpp
	$(CXX) $(CXXFLAGS) -mwindows -o $@ $< $(LDFLAGS) -lgdi32 -luser32 -lole32 -luuid

$(OUT)/hook32_probe.exe: hook32_probe.cpp
	$(CXX) -O2 -std=c++17 -o $@ $< $(LDFLAGS) -luser32

clean:
	rm -f $(OUT)/Xwa32bppPlayer32.exe $(OUT)/hook32_probe.exe $(OUT)/Xwa32bppPlayerNet32.dll

.PHONY: all clean net
