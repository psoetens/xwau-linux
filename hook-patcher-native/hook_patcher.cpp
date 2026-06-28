// hook_patcher.cpp — native (unmanaged) reimplementation of XWA's hook_patcher.
// Plan: .claude/plans/glowing-popping-penguin.md (native-hook-patcher)
//
// The upstream hook_patcher is a managed (.Net) IJW assembly: loading it during
// the dinput hook-load storm bootstraps the CLR in DllMain, which DEADLOCKS on
// wine-mono (mono_runtime_init creates+waits-for threads under the loader lock).
// It does NO managed work though — it just reads hook_patcher.xml (+ patcher-xml/
// *.xml) and hook_patcher.txt (enable flags) and returns enabled byte-patches via
// the standard native hook ABI. This native port removes the CLR bootstrap.
//
// Behavior mirrors xwa_hook_patcher/hook_patcher/{HookMain,ExePatcher}.cs:
//  - GetHookFunctionsCount()=0, GetHookFunction()={}  (it installs no fn hooks)
//  - patches come from <Patch Name><Item Offset From To/></Patch>, enabled when
//    hook_patcher.txt has "<rawName> = <nonzero>"; HookPatch.Name is prefixed
//    "[hook_patcher] " like the managed dict key.
//  - From/To pass through as hex strings (the dinput applier parses hex itself,
//    verifies From|To before writing); only Offset is hex->int here.
// LOCAL TEST build (unlicensed source tree); intended as an upstream-quality port.

#include <windows.h>
#include <string>
#include <vector>
#include <deque>
#include <fstream>

// ---- native hook ABI (matches xwa_hook_main/dinput/hook_function.h) ----
struct HookFunction { int from; int(*function)(int* params); };
struct HookPatchItem { int Offset; const char* From; const char* To; };
struct HookPatch { const char* Name; int Count; const HookPatchItem* Items; };

// ---- config parser (faithful copy of xwa_hook_32bpp/hook_32bpp/config.cpp) ----
static std::string Trim(const std::string& str)
{
    const char* ws = " \t\n\r\f\v";
    std::string s = str;
    s.erase(str.find_last_not_of(ws) + 1);
    s.erase(0, s.find_first_not_of(ws));
    return s;
}

static std::vector<std::string> GetFileLines(const std::string& path)
{
    std::vector<std::string> values;
    std::ifstream file(path);
    if (file)
    {
        std::string line;
        while (std::getline(file, line))
        {
            line = Trim(line);
            if (!line.length()) continue;
            if (line[0] == '#' || line[0] == ';' || (line[0] == '/' && line[1] == '/')) continue;
            // hook_patcher.txt has no [sections]; section headers (if any) ignored.
            if (line[0] == '[' && line[line.length() - 1] == ']') continue;
            values.push_back(line);
        }
    }
    return values;
}

static int GetFileKeyValueInt(const std::vector<std::string>& lines, const std::string& key, int defaultValue)
{
    for (const auto& line : lines)
    {
        int pos = (int)line.find("=");
        if (pos == -1) continue;
        std::string name = Trim(line.substr(0, pos));
        if (!name.length()) continue;
        if (_stricmp(name.c_str(), key.c_str()) == 0)
        {
            std::string value = Trim(line.substr(pos + 1));
            if (value.empty()) return defaultValue;
            return std::stoi(value, 0, 0);
        }
    }
    return defaultValue;
}

// ---- tiny XML attribute scanner for the fixed Patch/Item schema ----
static std::string ReadAllText(const std::string& path)
{
    std::ifstream f(path, std::ios::binary);
    if (!f) return std::string();
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// Extract value of attr `key="..."` within a single tag substring.
static std::string Attr(const std::string& tag, const char* key)
{
    std::string needle = std::string(key) + "=\"";
    size_t s = tag.find(needle);
    if (s == std::string::npos) return std::string();
    s += needle.size();
    size_t e = tag.find('"', s);
    if (e == std::string::npos) return std::string();
    return tag.substr(s, e - s);
}

// ---- persistent storage (stable pointers for the returned HookPatch*) ----
struct ParsedItem { int offset; std::string from; std::string to; };
struct ParsedPatch { std::string name; std::vector<ParsedItem> items; };

static bool g_built = false;
static std::deque<std::string> g_strings;              // stable c_str() backing
static std::vector<std::vector<HookPatchItem>> g_items; // one inner vector per patch
static std::vector<HookPatch> g_patches;                // returned to the loader

static const char* Keep(const std::string& s)
{
    g_strings.push_back(s);
    return g_strings.back().c_str();
}

static void ParseXmlInto(const std::string& path, std::vector<ParsedPatch>& out)
{
    std::string xml = ReadAllText(path);
    if (xml.empty()) return;

    size_t p = 0;
    while ((p = xml.find("<Patch", p)) != std::string::npos)
    {
        size_t tagEnd = xml.find('>', p);
        if (tagEnd == std::string::npos) break;
        std::string patchTag = xml.substr(p, tagEnd - p);
        std::string name = Attr(patchTag, "Name");

        size_t patchClose = xml.find("</Patch>", tagEnd);
        size_t scanEnd = (patchClose == std::string::npos) ? xml.size() : patchClose;

        ParsedPatch patch;
        patch.name = name;

        size_t ip = tagEnd;
        while ((ip = xml.find("<Item", ip)) != std::string::npos && ip < scanEnd)
        {
            size_t itEnd = xml.find('>', ip);
            if (itEnd == std::string::npos) break;
            std::string itemTag = xml.substr(ip, itEnd - ip);

            ParsedItem item;
            std::string offsetStr = Attr(itemTag, "Offset");
            item.offset = offsetStr.empty() ? 0 : (int)std::stoul(offsetStr, 0, 16);
            item.from = Attr(itemTag, "From");
            item.to = Attr(itemTag, "To");
            patch.items.push_back(item);

            ip = itEnd;
        }

        out.push_back(patch);
        p = (patchClose == std::string::npos) ? xml.size() : (patchClose + 8);
    }
}

static void Build()
{
    if (g_built) return;
    g_built = true;

    // 1. Read all patch definitions: hook_patcher.xml + patcher-xml/*.xml (merge).
    std::vector<ParsedPatch> defs;
    ParseXmlInto("hook_patcher.xml", defs);

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA("patcher-xml\\*.xml", &fd);
    if (h != INVALID_HANDLE_VALUE)
    {
        do
        {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
            std::string file = std::string("patcher-xml\\") + fd.cFileName;
            ParseXmlInto(file, defs);
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }

    // 2. Filter by hook_patcher.txt enable flags (key = raw name, default 0).
    std::vector<std::string> lines = GetFileLines("hook_patcher.txt");

    std::vector<ParsedPatch> enabled;
    for (const auto& d : defs)
    {
        if (GetFileKeyValueInt(lines, d.name, 0) != 0)
            enabled.push_back(d);
    }

    // 3. Materialize into the stable ABI structures (reserve so no realloc).
    g_items.reserve(enabled.size());
    g_patches.reserve(enabled.size());

    for (const auto& d : enabled)
    {
        std::vector<HookPatchItem> items;
        items.reserve(d.items.size());
        for (const auto& it : d.items)
        {
            HookPatchItem hpi;
            hpi.Offset = it.offset;
            hpi.From = Keep(it.from);
            hpi.To = Keep(it.to);
            items.push_back(hpi);
        }
        g_items.push_back(std::move(items));
    }

    for (size_t i = 0; i < enabled.size(); i++)
    {
        HookPatch hp;
        hp.Name = Keep(std::string("[hook_patcher] ") + enabled[i].name);
        hp.Count = (int)g_items[i].size();
        hp.Items = g_items[i].data();
        g_patches.push_back(hp);
    }
}

// ---- exported hook ABI ----
extern "C" {

__declspec(dllexport) int GetHookFunctionsCount() { return 0; }

__declspec(dllexport) HookFunction GetHookFunction(int /*index*/) { return HookFunction{}; }

__declspec(dllexport) int GetHookPatchesCount()
{
    Build();
    return (int)g_patches.size();
}

__declspec(dllexport) const HookPatch* GetHookPatch(int index)
{
    Build();
    if (index < 0 || index >= (int)g_patches.size()) return nullptr;
    return &g_patches[index];
}

} // extern "C"

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) { /* no CLR, no work — the whole point */ }
    return TRUE;
}

#ifdef PARITY_MAIN
// Headless parity dumper: prints every emitted patch as
//   name | offset(hex) | From | To  (one line per item)
// Run in a dir containing hook_patcher.xml/.txt + patcher-xml/. Works for BOTH
// this native dll's logic and (when this file is the dll loaded by the harness)
// the managed one — here we just exercise our own functions directly.
#include <cstdio>
int main()
{
    int n = GetHookPatchesCount();
    for (int i = 0; i < n; i++)
    {
        const HookPatch* p = GetHookPatch(i);
        for (int j = 0; j < p->Count; j++)
            printf("%s | %06X | %s | %s\n", p->Name, p->Items[j].Offset, p->Items[j].From, p->Items[j].To);
    }
    return 0;
}
#endif
