// Xwa32bppPlayer32 — 32-bit port of JeremyAnsel's Xwa32bppPlayer (x64).
// Plan: .claude/plans/controller-and-briefing-fixes.md (extension N5-B).
//
// Why: XWAU 2025 sideloads HD OPT/texture data into this helper process to
// escape the game's 32-bit 4GB address space. The shipped player is x64 and
// cannot run in the win32 wine prefix the game requires; this port keeps the
// exact WM_COPYDATA + shared-memory protocol of the original
// (window class XWA32BPPPLAYER, mapping Local\Xwa32bppHookSemaphore) but is
// built i686 with mingw, and replaces the DllExport-based
// Xwa32bppPlayerNet.dll calls with CLR 4.0 hosting
// (ExecuteInDefaultAppDomain -> Xwa32bppPlayerNet.Bridge, see cs/Bridge.cs).
//
// Build: see Makefile. Logs to xwa32bpp-player32.log in the CWD.

#include <windows.h>
#include <string>
#include <cstdio>
#include <cstdarg>
#include <cwchar>

// ---------------------------------------------------------------------------
// Logging (the player is a GUI app; a logfile is the only headless channel)
// ---------------------------------------------------------------------------

static void LogF(const char* fmt, ...)
{
    FILE* f = fopen("xwa32bpp-player32.log", "a");
    if (!f) return;
    SYSTEMTIME st; GetLocalTime(&st);
    fprintf(f, "%02u:%02u:%02u.%03u ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// ---------------------------------------------------------------------------
// SharedMemoryWriter — verbatim port of upstream SharedMemory.cpp (writer side)
// ---------------------------------------------------------------------------

class SharedMemoryWriter
{
public:
    SharedMemoryWriter() : _handle(nullptr), _lpData(nullptr), _cbData(0) {}
    ~SharedMemoryWriter() { Close(); }

    void Close()
    {
        if (_lpData) { UnmapViewOfFile(_lpData); _lpData = nullptr; }
        if (_handle) { CloseHandle(_handle); _handle = nullptr; }
        _cbData = 0;
    }

    void Create(const wchar_t* name, unsigned int cbData)
    {
        Close();
        HANDLE hMapFile = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, cbData, name);
        if (!hMapFile) { LogF("SharedMemoryWriter.Create(%u) FAILED: %lu", cbData, GetLastError()); return; }
        void* lpData = MapViewOfFile(hMapFile, FILE_MAP_ALL_ACCESS, 0, 0, cbData);
        if (!lpData) { LogF("SharedMemoryWriter MapViewOfFile(%u) FAILED: %lu", cbData, GetLastError()); CloseHandle(hMapFile); return; }
        _handle = hMapFile;
        _lpData = lpData;
        _cbData = cbData;
    }

    void* _handle;
    void* _lpData;
    unsigned int _cbData;
};

// ---------------------------------------------------------------------------
// Minimal CLR 4.0 hosting declarations (this mingw lacks metahost.h).
// Vtable orders match the published metahost.h/mscoree.h exactly.
// ---------------------------------------------------------------------------

static const CLSID CLSID_CLRMetaHost_  = {0x9280188d, 0x0e8e, 0x4867, {0xb3, 0x0c, 0x7f, 0xa8, 0x38, 0x84, 0xe8, 0xde}};
static const IID   IID_ICLRMetaHost_   = {0xd332db9e, 0xb9b3, 0x4125, {0x82, 0x07, 0xa1, 0x48, 0x84, 0xf5, 0x32, 0x16}};
static const IID   IID_ICLRRuntimeInfo_= {0xbd39d1d2, 0xba2f, 0x486a, {0x89, 0xb0, 0xb4, 0xb0, 0xcb, 0x46, 0x68, 0x91}};
static const CLSID CLSID_CLRRuntimeHost_={0x90f1a06e, 0x7712, 0x4762, {0x86, 0xb5, 0x7a, 0x5e, 0xba, 0x6b, 0xdb, 0x02}};
static const IID   IID_ICLRRuntimeHost_= {0x90f1a06c, 0x7712, 0x4762, {0x86, 0xb5, 0x7a, 0x5e, 0xba, 0x6b, 0xdb, 0x02}};

struct ICLRRuntimeInfo;

struct ICLRMetaHost : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE GetRuntime(LPCWSTR pwzVersion, REFIID riid, LPVOID* ppRuntime) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetVersionFromFile(LPCWSTR pwzFilePath, LPWSTR pwzBuffer, DWORD* pcchBuffer) = 0;
    virtual HRESULT STDMETHODCALLTYPE EnumerateInstalledRuntimes(IEnumUnknown** ppEnumerator) = 0;
    virtual HRESULT STDMETHODCALLTYPE EnumerateLoadedRuntimes(HANDLE hndProcess, IEnumUnknown** ppEnumerator) = 0;
    virtual HRESULT STDMETHODCALLTYPE RequestRuntimeLoadedNotification(void* pCallbackFunction) = 0;
    virtual HRESULT STDMETHODCALLTYPE QueryLegacyV2RuntimeBinding(REFIID riid, LPVOID* ppUnk) = 0;
    virtual HRESULT STDMETHODCALLTYPE ExitProcess(INT32 iExitCode) = 0;
};

struct ICLRRuntimeInfo : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE GetVersionString(LPWSTR pwzBuffer, DWORD* pcchBuffer) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetRuntimeDirectory(LPWSTR pwzBuffer, DWORD* pcchBuffer) = 0;
    virtual HRESULT STDMETHODCALLTYPE IsLoaded(HANDLE hndProcess, BOOL* pbLoaded) = 0;
    virtual HRESULT STDMETHODCALLTYPE LoadErrorString(UINT iResourceID, LPWSTR pwzBuffer, DWORD* pcchBuffer, LONG iLocaleID) = 0;
    virtual HRESULT STDMETHODCALLTYPE LoadLibraryA(LPCWSTR pwzDllName, HMODULE* phndModule) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetProcAddress(LPCSTR pszProcName, LPVOID* ppProc) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetInterface(REFCLSID rclsid, REFIID riid, LPVOID* ppUnk) = 0;
    virtual HRESULT STDMETHODCALLTYPE IsLoadable(BOOL* pbLoadable) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetDefaultStartupFlags(DWORD dwStartupFlags, LPCWSTR pwzHostConfigFile) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDefaultStartupFlags(DWORD* pdwStartupFlags, LPWSTR pwzHostConfigFile, DWORD* pcchHostConfigFile) = 0;
    virtual HRESULT STDMETHODCALLTYPE BindAsLegacyV2Runtime() = 0;
    virtual HRESULT STDMETHODCALLTYPE IsStarted(BOOL* pbStarted, DWORD* pdwStartupFlags) = 0;
};

struct ICLRRuntimeHost : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE Start() = 0;
    virtual HRESULT STDMETHODCALLTYPE Stop() = 0;
    virtual HRESULT STDMETHODCALLTYPE SetHostControl(void* pHostControl) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetCLRControl(void** pCLRControl) = 0;
    virtual HRESULT STDMETHODCALLTYPE UnloadAppDomain(DWORD dwAppDomainId, BOOL fWaitUntilDone) = 0;
    virtual HRESULT STDMETHODCALLTYPE ExecuteInAppDomain(DWORD dwAppDomainId, void* pCallback, void* cookie) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetCurrentAppDomainId(DWORD* pdwAppDomainId) = 0;
    virtual HRESULT STDMETHODCALLTYPE ExecuteApplication(LPCWSTR pwzAppFullName, DWORD dwManifestPaths, LPCWSTR* ppwzManifestPaths, DWORD dwActivationData, LPCWSTR* ppwzActivationData, int* pReturnValue) = 0;
    virtual HRESULT STDMETHODCALLTYPE ExecuteInDefaultAppDomain(LPCWSTR pwzAssemblyPath, LPCWSTR pwzTypeName, LPCWSTR pwzMethodName, LPCWSTR pwzArgument, DWORD* pReturnValue) = 0;
};

typedef HRESULT (STDAPICALLTYPE* CLRCreateInstance_t)(REFCLSID clsid, REFIID riid, LPVOID* ppInterface);

// ---------------------------------------------------------------------------
// ClrBridge — replaces upstream NetFunctions (LoadLibrary + GetProcAddress)
// ---------------------------------------------------------------------------

class ClrBridge
{
public:
    bool Init()
    {
        // The bridge assembly sits next to this exe.
        wchar_t exePath[MAX_PATH];
        GetModuleFileNameW(nullptr, exePath, MAX_PATH);
        std::wstring dir(exePath);
        size_t slash = dir.find_last_of(L"\\/");
        _netDllPath = dir.substr(0, slash + 1) + L"Xwa32bppPlayerNet32.dll";

        if (GetFileAttributesW(_netDllPath.c_str()) == INVALID_FILE_ATTRIBUTES)
        {
            LogF("ClrBridge: bridge assembly not found: %ls", _netDllPath.c_str());
            return false;
        }

        HMODULE mscoree = LoadLibraryW(L"mscoree.dll");
        if (!mscoree) { LogF("ClrBridge: LoadLibrary(mscoree) failed: %lu", GetLastError()); return false; }

        CLRCreateInstance_t pCLRCreateInstance =
            (CLRCreateInstance_t)::GetProcAddress(mscoree, "CLRCreateInstance");
        if (!pCLRCreateInstance) { LogF("ClrBridge: CLRCreateInstance not found"); return false; }

        ICLRMetaHost* metaHost = nullptr;
        HRESULT hr = pCLRCreateInstance(CLSID_CLRMetaHost_, IID_ICLRMetaHost_, (LPVOID*)&metaHost);
        if (FAILED(hr)) { LogF("ClrBridge: CLRCreateInstance hr=0x%08lx", hr); return false; }

        ICLRRuntimeInfo* runtimeInfo = nullptr;
        hr = metaHost->GetRuntime(L"v4.0.30319", IID_ICLRRuntimeInfo_, (LPVOID*)&runtimeInfo);
        if (FAILED(hr)) { LogF("ClrBridge: GetRuntime hr=0x%08lx", hr); return false; }

        hr = runtimeInfo->GetInterface(CLSID_CLRRuntimeHost_, IID_ICLRRuntimeHost_, (LPVOID*)&_host);
        if (FAILED(hr)) { LogF("ClrBridge: GetInterface hr=0x%08lx", hr); return false; }

        hr = _host->Start();
        if (FAILED(hr)) { LogF("ClrBridge: Start hr=0x%08lx", hr); return false; }

        LogF("ClrBridge: CLR v4 started; bridge=%ls", _netDllPath.c_str());
        return true;
    }

    // Calls static int Xwa32bppPlayerNet.Bridge.<method>(string arg).
    // Returns the managed int, or `fallback` on hosting failure.
    DWORD Call(const wchar_t* method, const std::wstring& arg, DWORD fallback = 0)
    {
        if (!_host) return fallback;
        DWORD ret = 0;
        HRESULT hr = _host->ExecuteInDefaultAppDomain(
            _netDllPath.c_str(), L"Xwa32bppPlayerNet.Bridge", method, arg.c_str(), &ret);
        if (FAILED(hr))
        {
            LogF("ClrBridge: %ls hr=0x%08lx (see xwa32bpp-bridge.log for managed exceptions)", method, hr);
            return fallback;
        }
        return ret;
    }

private:
    ICLRRuntimeHost* _host = nullptr;
    std::wstring _netDllPath;
};

static ClrBridge g_clr;

// ANSI (game structs) -> wide, CP_ACP like the original LPStr marshaling.
static std::wstring Widen(const char* s)
{
    if (!s || !*s) return std::wstring();
    int n = MultiByteToWideChar(CP_ACP, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_ACP, 0, s, -1, &w[0], n);
    return w;
}

// ---------------------------------------------------------------------------
// WM_COPYDATA protocol — identical to upstream 32bpp.cpp
// ---------------------------------------------------------------------------

enum ExeDataType
{
    ExeDataType_None,
    ExeDataType_ShowMessage,
    ExeDataType_SetSettings,
    ExeDataType_ReadOpt,
    ExeDataType_GetOptVersion,
    ExeDataType_WriteOpt,
    ExeDataType_FreeOptMemory,
};

struct ExeSetSettingsParameters
{
    char missionFileName[256];
    int missionFileNameIndex;
    int isTechLibraryGameStateUpdate;
    char hangar[256];
    int hangarIff;
};

struct ExeReadOptParameters
{
    char optFilename[256];
    int loadSkins;
    int groupFaceGroups;
};

static unsigned int g_optRequiredSize = 0;
static SharedMemoryWriter g_optSharedMemory;

static LRESULT HandleMessage(ULONG_PTR dwData, DWORD cbData, PVOID lpData)
{
    switch (dwData)
    {
    case ExeDataType_ShowMessage:
    {
        // Headless-friendly: log instead of a blocking MessageBox.
        LogF("ShowMessage: %s", (const char*)lpData);
        return 0;
    }

    case ExeDataType_SetSettings:
    {
        ExeSetSettingsParameters* data = (ExeSetSettingsParameters*)lpData;
        wchar_t tail[128];
        swprintf(tail, 128, L"\n%d\n%d\n", data->missionFileNameIndex, data->isTechLibraryGameStateUpdate);
        std::wstring arg = Widen(data->missionFileName) + tail + Widen(data->hangar);
        swprintf(tail, 128, L"\n%d", data->hangarIff);
        arg += tail;
        g_clr.Call(L"SetSettings", arg, (DWORD)-1);
        return 0;
    }

    case ExeDataType_ReadOpt:
    {
        ExeReadOptParameters* data = (ExeReadOptParameters*)lpData;
        wchar_t tail[64];
        swprintf(tail, 64, L"\n%d\n%d", data->loadSkins, data->groupFaceGroups);
        std::wstring arg = Widen(data->optFilename) + tail;
        unsigned int requiredFileSize = g_clr.Call(L"ReadOpt", arg, 0);
        g_optRequiredSize = requiredFileSize;
        LogF("ReadOpt(%s, skins=%d, group=%d) -> %u", data->optFilename, data->loadSkins, data->groupFaceGroups, requiredFileSize);
        return requiredFileSize;
    }

    case ExeDataType_GetOptVersion:
        return g_clr.Call(L"GetOptVersion", L"", 0);

    case ExeDataType_WriteOpt:
    {
        g_optSharedMemory.Create(L"Local\\Xwa32bppHookSemaphore", g_optRequiredSize);
        if (!g_optSharedMemory._lpData) return 0;
        // Log the view address: the round-3 Bridge.WriteOpt overflow only
        // fired for views >= 2GB, so this is the regime marker (plan
        // magical-jumping-pascal A0).
        LogF("WriteOpt: mapping %u bytes, view at %p%s", g_optRequiredSize,
            g_optSharedMemory._lpData,
            ((ULONG_PTR)g_optSharedMemory._lpData >= 0x80000000u) ? " (HIGH >=2GB)" : "");
        wchar_t ptrStr[32];
        swprintf(ptrStr, 32, L"%lu", (unsigned long)(ULONG_PTR)g_optSharedMemory._lpData);
        g_clr.Call(L"WriteOpt", ptrStr, (DWORD)-1);
        return 0;
    }

    case ExeDataType_FreeOptMemory:
        g_optSharedMemory.Close();
        return 0;
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Window shell — class name MUST be XWA32BPPPLAYER (hook_32bpp FindWindow)
// ---------------------------------------------------------------------------

static LRESULT CALLBACK WndProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_PAINT:
    {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hWnd, &ps);
        LPCWSTR text = L"32-bit XWA sideload player (Linux/wine port).\n"
                       L"Used by X-Wing Alliance; do not close while the game runs.";
        RECT rc;
        GetClientRect(hWnd, &rc);
        DrawTextW(hdc, text, -1, &rc, DT_WORDBREAK);
        EndPaint(hWnd, &ps);
        break;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        break;
    case WM_COPYDATA:
    {
        PCOPYDATASTRUCT pCDS = (PCOPYDATASTRUCT)lParam;
        return HandleMessage(pCDS->dwData, pCDS->cbData, pCDS->lpData);
    }
    default:
        return DefWindowProcW(hWnd, message, wParam, lParam);
    }
    return 0;
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int)
{
    LogF("player32 starting (pid %lu)", GetCurrentProcessId());

    // Test knob (plan magical-jumping-pascal A0): XWA32BPP_RESERVE_VA_MB=<n>
    // reserves n MB of address space (MEM_RESERVE only, no commit) so later
    // mapping views are forced into the >=2GB large-address region, headlessly
    // reproducing the in-game VA-pressure regime where the round-3 WriteOpt
    // overflow used to zero-fill blobs. Unset in normal use.
    {
        char reserveStr[32] = {};
        if (GetEnvironmentVariableA("XWA32BPP_RESERVE_VA_MB", reserveStr, sizeof(reserveStr)) > 0)
        {
            unsigned long wantMb = strtoul(reserveStr, nullptr, 10);
            unsigned long gotMb = 0;
            while (gotMb < wantMb)
            {
                unsigned long chunkMb = (wantMb - gotMb >= 256) ? 256 : (wantMb - gotMb);
                if (!VirtualAlloc(nullptr, chunkMb * 1024u * 1024u, MEM_RESERVE, PAGE_NOACCESS))
                    break;
                gotMb += chunkMb;
            }
            LogF("VA-pressure knob: reserved %lu of %lu MB requested", gotMb, wantMb);
        }
    }

    if (!g_clr.Init())
    {
        // Refuse to register the window class: hook_32bpp must NOT find a
        // player that cannot serve requests (it would get zero-sized OPTs).
        LogF("player32: CLR init failed; exiting WITHOUT registering XWA32BPPPLAYER");
        return 1;
    }

    WNDCLASSEXW wcex{};
    wcex.cbSize = sizeof(WNDCLASSEXW);
    wcex.style = CS_HREDRAW | CS_VREDRAW;
    wcex.lpfnWndProc = WndProc;
    wcex.hInstance = hInstance;
    wcex.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wcex.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wcex.lpszClassName = L"XWA32BPPPLAYER";
    RegisterClassExW(&wcex);

    // WS_EX_NOACTIVATE: the system must never give this window focus —
    // during the game's Esc/mode-switch transitions wine may hand focus to
    // another window of the session, and if that's us the game loses its
    // keyboard (controller polling keeps working). WS_EX_TOOLWINDOW also
    // keeps it out of alt-tab. WM_COPYDATA via SendMessage is unaffected.
    HWND hWnd = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
        L"XWA32BPPPLAYER", L"Xwa32bppPlayer32",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 300, 150,
        nullptr, nullptr, hInstance, nullptr);
    if (!hWnd) { LogF("player32: CreateWindow failed: %lu", GetLastError()); return 1; }

    // Keep the window HIDDEN: under wine a visible (even minimized) window in
    // the same session can steal focus from the fullscreen game — the game's
    // keyboard path needs focus while winmm joystick polling doesn't, which
    // produced "keyboard dead, controller alive" in testing. FindWindow and
    // WM_COPYDATA (SendMessage) both work fine on hidden windows.
    ShowWindow(hWnd, SW_HIDE);
    LogF("player32 ready: window class XWA32BPPPLAYER registered (hidden)");

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    LogF("player32 exiting (wParam=%d)", (int)msg.wParam);
    return (int)msg.wParam;
}
