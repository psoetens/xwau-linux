// generic_dump.cpp — LoadLibrary's whatever hook_patcher.dll is in the CWD and
// dumps its emitted patches via the native hook ABI. Works for BOTH the managed
// upstream dll (needs a CLR in the prefix) and our native port → true parity diff.
#include <windows.h>
#include <cstdio>

struct HookPatchItem { int Offset; const char* From; const char* To; };
struct HookPatch { const char* Name; int Count; const HookPatchItem* Items; };

int main()
{
    HMODULE m = LoadLibraryA("hook_patcher.dll");
    if (!m) { fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError()); return 2; }

    auto count = (int(*)())GetProcAddress(m, "GetHookPatchesCount");
    auto get   = (const HookPatch*(*)(int))GetProcAddress(m, "GetHookPatch");
    if (!count || !get) { fprintf(stderr, "missing exports\n"); return 3; }

    int n = count();
    for (int i = 0; i < n; i++)
    {
        const HookPatch* p = get(i);
        if (!p) continue;
        for (int j = 0; j < p->Count; j++)
            printf("%s | %06X | %s | %s\n", p->Name, p->Items[j].Offset, p->Items[j].From, p->Items[j].To);
    }
    return 0;
}
