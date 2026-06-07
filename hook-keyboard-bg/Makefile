# hook_keyboard_bg.dll — keyboard-survives-Esc fix (plan N6).
CXX := i686-w64-mingw32-g++
CXXFLAGS := -O2 -std=c++17
LDFLAGS := -static -static-libgcc -static-libstdc++

OUT := /home/kaltan/src/SteamLibrary/build/hook-keyboard-bg

all: $(OUT)/hook_keyboard_bg.dll $(OUT)/di_coop_gate.exe

$(OUT)/hook_keyboard_bg.dll: hook_keyboard_bg.cpp
	$(CXX) $(CXXFLAGS) -shared -o $@ $< $(LDFLAGS) -luser32

$(OUT)/di_coop_gate.exe: di_coop_gate.cpp
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS) -luser32

clean:
	rm -f $(OUT)/hook_keyboard_bg.dll $(OUT)/di_coop_gate.exe

.PHONY: all clean
