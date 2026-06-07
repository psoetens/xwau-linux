// hook_keyboard_bg.dll — keep XWA's keyboard alive across mode transitions
// under wine (plan controller-and-briefing-fixes, extension N6).
//
// Problem (proven via WINEDEBUG trace, see report N6): the Esc mission->menu
// transition briefly focuses a second window; wine's dinput input thread then
// fires handle_foreground_lost and unacquires the game's keyboard+mouse
// (acquired DISCL_FOREGROUND|DISCL_NONEXCLUSIVE). X-Wing Alliance never
// re-acquires until a real activation cycle (alt-tab x2).
//
// Fix: XWAU's hook loader (dinput.dll) LoadLibrary()s every game-dir
// hook_*.dll, so this DLL rides along. It patches the shared ANSI
// IDirectInputDeviceA vtable slot for SetCooperativeLevel to rewrite
// DISCL_FOREGROUND -> DISCL_BACKGROUND. Background devices are never
// unacquired on focus loss, so the keyboard survives the blip. The joystick
// path (winmm, W interfaces) is untouched. Rollback: delete this DLL.
//
// Build: i686-w64-mingw32 (see Makefile). Logs to hook_keyboard_bg.log (CWD).

#include <windows.h>
#include <cstdio>
#include <cstdarg>

static void LogF(const char* fmt, ...)
{
    FILE* f = fopen("hook_keyboard_bg.log", "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// --- minimal dinput bits (avoid header dependency drift) -------------------

static const GUID GUID_SysKeyboard_ =
    {0x6f1d2b61, 0xd5a0, 0x11cf, {0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}};

#define DISCL_EXCLUSIVE_    0x00000001
#define DISCL_NONEXCLUSIVE_ 0x00000002
#define DISCL_FOREGROUND_   0x00000004
#define DISCL_BACKGROUND_   0x00000008

typedef HRESULT (WINAPI* DirectInputCreateA_t)(HINSTANCE, DWORD, void**, void*);
typedef HRESULT (STDMETHODCALLTYPE* SetCooperativeLevel_t)(void* self, HWND hwnd, DWORD flags);

// IDirectInputDeviceA vtable: 0-2 IUnknown, 3 GetCapabilities, 4 EnumObjects,
// 5 GetProperty, 6 SetProperty, 7 Acquire, 8 Unacquire, 9 GetDeviceState,
// 10 GetDeviceData, 11 SetDataFormat, 12 SetEventNotification,
// 13 SetCooperativeLevel, ...
#define VTBL_SLOT_SETCOOPERATIVELEVEL 13

// IDirectInputA vtable: 0-2 IUnknown, 3 CreateDevice, ...
#define VTBL_SLOT_CREATEDEVICE 3

static SetCooperativeLevel_t g_origSetCooperativeLevel = nullptr;

static HRESULT STDMETHODCALLTYPE SetCooperativeLevelHook(void* self, HWND hwnd, DWORD flags)
{
    DWORD newFlags = flags;
    if (newFlags & DISCL_FOREGROUND_)
    {
        newFlags = (newFlags & ~(DWORD)DISCL_FOREGROUND_) | DISCL_BACKGROUND_;
    }
    LogF("SetCooperativeLevel dev=%p hwnd=%p flags=0x%lx -> 0x%lx", self, (void*)hwnd, flags, newFlags);
    return g_origSetCooperativeLevel(self, hwnd, newFlags);
}

static DWORD WINAPI PatchThread(LPVOID)
{
    // dinput.dll is already loaded: in-game it is the XWAU loader that loaded
    // us (its DirectInputCreateA forwards to the builtin); in the headless
    // gate it is the builtin directly. Either way the device objects come
    // from wine's builtin dinput and share one ANSI vtable.
    HMODULE dinput = GetModuleHandleA("dinput.dll");
    for (int i = 0; i < 100 && !dinput; i++) { Sleep(50); dinput = GetModuleHandleA("dinput.dll"); }
    if (!dinput) { LogF("ERROR: dinput.dll module not found"); return 1; }

    DirectInputCreateA_t create = (DirectInputCreateA_t)GetProcAddress(dinput, "DirectInputCreateA");
    if (!create) { LogF("ERROR: DirectInputCreateA not found"); return 1; }

    void* di = nullptr;
    HRESULT hr = create(GetModuleHandleA(nullptr), 0x0500, &di, nullptr);
    if (FAILED(hr) || !di) { LogF("ERROR: DirectInputCreateA hr=0x%08lx", hr); return 1; }

    // IDirectInputA::CreateDevice(GUID_SysKeyboard)
    void*** diVtbl = (void***)di;
    typedef HRESULT (STDMETHODCALLTYPE* CreateDevice_t)(void*, const GUID*, void**, void*);
    CreateDevice_t createDevice = (CreateDevice_t)(*diVtbl)[VTBL_SLOT_CREATEDEVICE];

    void* dev = nullptr;
    hr = createDevice(di, &GUID_SysKeyboard_, &dev, nullptr);
    if (FAILED(hr) || !dev) { LogF("ERROR: CreateDevice hr=0x%08lx", hr); return 1; }

    void** vtbl = *(void***)dev;

    if (vtbl[VTBL_SLOT_SETCOOPERATIVELEVEL] == (void*)SetCooperativeLevelHook)
    {
        LogF("vtable already patched");
    }
    else
    {
        DWORD oldProtect;
        if (!VirtualProtect(&vtbl[VTBL_SLOT_SETCOOPERATIVELEVEL], sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect))
        {
            LogF("ERROR: VirtualProtect failed: %lu", GetLastError());
        }
        else
        {
            g_origSetCooperativeLevel = (SetCooperativeLevel_t)vtbl[VTBL_SLOT_SETCOOPERATIVELEVEL];
            vtbl[VTBL_SLOT_SETCOOPERATIVELEVEL] = (void*)SetCooperativeLevelHook;
            VirtualProtect(&vtbl[VTBL_SLOT_SETCOOPERATIVELEVEL], sizeof(void*), oldProtect, &oldProtect);
            LogF("patched ANSI device vtable %p slot %d (orig %p)", (void*)vtbl,
                 VTBL_SLOT_SETCOOPERATIVELEVEL, (void*)g_origSetCooperativeLevel);
        }
    }

    // Release temp objects; the builtin dinput module (and its static vtable)
    // stays loaded — the XWAU loader holds a reference for the process life.
    typedef ULONG (STDMETHODCALLTYPE* Release_t)(void*);
    ((Release_t)(*(void***)dev)[2])(dev);
    ((Release_t)(*diVtbl)[2])(di);
    return 0;
}

// Loader-contract stubs: zero exe-patch hook functions; we only want DllMain.
extern "C" __declspec(dllexport) int GetHookFunctionsCount() { return 0; }
extern "C" __declspec(dllexport) void* GetHookFunction(int) { return nullptr; }

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(hinst);
        // No DI calls under loader lock — patch from a worker thread. The
        // game creates its devices seconds later (after window creation), so
        // the patch always wins the race.
        HANDLE h = CreateThread(nullptr, 0, PatchThread, nullptr, 0, nullptr);
        if (h) CloseHandle(h);
    }
    return TRUE;
}
