// di_coop_gate — behavioral gate for hook_keyboard_bg.dll (plan N6 §gate).
//
// Creates a HIDDEN window (never foreground), then a DirectInput keyboard
// device with DISCL_FOREGROUND|DISCL_NONEXCLUSIVE, then Acquire():
//   - unpatched ("nopatch" arg): Acquire FAILS (window is not foreground)
//   - with hook_keyboard_bg.dll loaded: SetCooperativeLevel was rewritten to
//     BACKGROUND -> Acquire SUCCEEDS.
//
// Usage: di_coop_gate.exe [nopatch]
// Exit: 0 = expected behavior for the mode, 2 = unexpected, 3 = setup error.

#include <windows.h>
#include <stdio.h>
#include <string.h>

static const GUID GUID_SysKeyboard_ =
    {0x6f1d2b61, 0xd5a0, 0x11cf, {0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}};
static const GUID GUID_Key_ =
    {0x55728220, 0xd33c, 0x11cf, {0xbf, 0xc7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}};

#define DISCL_NONEXCLUSIVE_ 0x00000002
#define DISCL_FOREGROUND_   0x00000004

// c_dfDIKeyboard equivalent: we don't need SetDataFormat to test Acquire's
// foreground check?? — wine requires a data format before Acquire. Build the
// standard keyboard format: 256 objects, 1 byte each.
struct DIOBJECTDATAFORMAT_ { const GUID* pguid; DWORD dwOfs; DWORD dwType; DWORD dwFlags; };
struct DIDATAFORMAT_ {
    DWORD dwSize; DWORD dwObjSize; DWORD dwFlags; DWORD dwDataSize; DWORD dwNumObjs;
    DIOBJECTDATAFORMAT_* rgodf;
};
#define DIDFT_BUTTON_ 0x0000000C
#define DIDFT_MAKEINSTANCE_(n) ((DWORD)(((n) & 0xffff) << 8))
#define DIDF_RELAXED_ 0  // dwFlags 0

typedef HRESULT (WINAPI* DirectInputCreateA_t)(HINSTANCE, DWORD, void**, void*);

int main(int argc, char** argv)
{
    bool noPatch = (argc > 1) && strcmp(argv[1], "nopatch") == 0;

    // hidden window — never foreground
    WNDCLASSA wc{};
    wc.lpfnWndProc = DefWindowProcA;
    wc.lpszClassName = "DiCoopGateWnd";
    wc.hInstance = GetModuleHandleA(nullptr);
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("DiCoopGateWnd", "gate", WS_OVERLAPPEDWINDOW,
                              0, 0, 100, 100, nullptr, nullptr, wc.hInstance, nullptr);
    if (!hwnd) { printf("RESULT=SETUP no window\n"); return 3; }

    // load real dinput FIRST (mirrors the in-game load order), then the hook
    HMODULE dinput = LoadLibraryA("dinput.dll");
    if (!dinput) { printf("RESULT=SETUP no dinput\n"); return 3; }

    if (!noPatch)
    {
        HMODULE hook = LoadLibraryA("hook_keyboard_bg.dll");
        if (!hook) { printf("RESULT=SETUP hook dll not found (%lu)\n", GetLastError()); return 3; }
        Sleep(1500); // let PatchThread run
    }

    DirectInputCreateA_t create = (DirectInputCreateA_t)GetProcAddress(dinput, "DirectInputCreateA");
    void* di = nullptr;
    HRESULT hr = create(wc.hInstance, 0x0500, &di, nullptr);
    if (FAILED(hr)) { printf("RESULT=SETUP DirectInputCreateA 0x%08lx\n", hr); return 3; }

    typedef HRESULT (STDMETHODCALLTYPE* CreateDevice_t)(void*, const GUID*, void**, void*);
    void* dev = nullptr;
    hr = ((CreateDevice_t)(*(void***)di)[3])(di, &GUID_SysKeyboard_, &dev, nullptr);
    if (FAILED(hr)) { printf("RESULT=SETUP CreateDevice 0x%08lx\n", hr); return 3; }
    void** vtbl = *(void***)dev;

    // SetDataFormat: replicate c_dfDIKeyboard (256 optional key buttons)
    static DIOBJECTDATAFORMAT_ objs[256];
    for (int i = 0; i < 256; i++) { objs[i] = { &GUID_Key_, (DWORD)i, DIDFT_BUTTON_ | DIDFT_MAKEINSTANCE_(i) | 0x80000000u /*DIDFT_OPTIONAL*/, 0 }; }
    DIDATAFORMAT_ fmt = { sizeof(fmt), sizeof(DIOBJECTDATAFORMAT_), 0x2 /*DIDF_RELAXIS*/, 256, 256, objs };
    typedef HRESULT (STDMETHODCALLTYPE* SetDataFormat_t)(void*, DIDATAFORMAT_*);
    hr = ((SetDataFormat_t)vtbl[11])(dev, &fmt);
    printf("SetDataFormat -> 0x%08lx\n", hr);

    typedef HRESULT (STDMETHODCALLTYPE* SetCooperativeLevel_t)(void*, HWND, DWORD);
    hr = ((SetCooperativeLevel_t)vtbl[13])(dev, hwnd, DISCL_FOREGROUND_ | DISCL_NONEXCLUSIVE_);
    printf("SetCooperativeLevel(FOREGROUND|NONEXCLUSIVE) -> 0x%08lx\n", hr);

    typedef HRESULT (STDMETHODCALLTYPE* Acquire_t)(void*);
    hr = ((Acquire_t)vtbl[7])(dev);
    printf("Acquire -> 0x%08lx\n", hr);

    bool acquired = SUCCEEDED(hr);
    bool expected = noPatch ? !acquired : acquired;
    printf("RESULT=%s MODE=%s ACQUIRED=%d\n", expected ? "PASS" : "FAIL",
           noPatch ? "nopatch" : "patched", acquired ? 1 : 0);
    return expected ? 0 : 2;
}
