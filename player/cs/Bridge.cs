// Bridge for the 32-bit Xwa32bppPlayer port (plan controller-and-briefing-fixes N5-B).
//
// The upstream x64 player calls Xwa32bppPlayerNet.dll through DllExport native
// exports; DllExport assemblies are arch-specific and we have no .NET build
// toolchain for x86 ones. Instead the 32-bit player hosts the CLR and calls
// these wrappers via ICLRRuntimeHost::ExecuteInDefaultAppDomain, whose only
// supported signature is `static int Method(string)`. Arguments are
// '\n'-joined fields; pointers travel as decimal strings (same process).
//
// Compiled with the prefix's .NET 4.8 csc.exe (C# 5) together with the
// (lightly patched) upstream Main.cs + XwaHooksConfig.cs.

using System;

// Inert stand-in for the DllExport package attribute used in Main.cs.
// We keep the attributes for upstream-diff cleanliness; nothing reads them.
internal sealed class DllExportAttribute : Attribute
{
    public DllExportAttribute() { }
    public DllExportAttribute(System.Runtime.InteropServices.CallingConvention callingConvention) { }
}

namespace Xwa32bppPlayerNet
{
    public static class Bridge
    {
        private static void Log(Exception ex, string where)
        {
            try
            {
                System.IO.File.AppendAllText("xwa32bpp-bridge.log",
                    DateTime.Now.ToString("HH:mm:ss") + " " + where + ": " + ex + Environment.NewLine);
            }
            catch { }
        }

        // arg: missionFileName \n missionFileNameIndex \n isTechLibraryGameStateUpdate \n hangar \n hangarIff
        public static int SetSettings(string arg)
        {
            try
            {
                string[] p = arg.Split('\n');
                Main.SetSettingsFunction(p[0], int.Parse(p[1]), int.Parse(p[2]), p[3], int.Parse(p[4]));
                return 0;
            }
            catch (Exception ex) { Log(ex, "SetSettings"); return -1; }
        }

        // Skinned-blob size cap (bytes). The game must map + parse each served
        // blob inside its 32-bit address space; XWAU 2025 hero craft with skins
        // reach 340-385 MB serialized (X-Wing family ~1 GB total) which crashes
        // the simulator load (msvcrt _invalid_parameter on failed allocation).
        // Blobs above the cap are re-read WITHOUT skins (~80% smaller measured);
        // only that craft loses per-flightgroup paint jobs. 0 disables the cap.
        // Override via Xwa32bppPlayer32.cfg: "SkinsSizeThreshold = <bytes>".
        private static int _skinsSizeThreshold = -1;

        private static int SkinsSizeThreshold
        {
            get
            {
                if (_skinsSizeThreshold < 0)
                {
                    int value = 200000000;
                    try
                    {
                        // Test override (plan magical-jumping-pascal A0):
                        // env beats cfg so headless probes can disable the cap
                        // without touching the game-dir config.
                        string env = Environment.GetEnvironmentVariable("XWA32BPP_SKINS_THRESHOLD");
                        int envValue;
                        if (env != null && int.TryParse(env.Trim(), out envValue))
                        {
                            _skinsSizeThreshold = envValue;
                            return _skinsSizeThreshold;
                        }
                        if (System.IO.File.Exists("Xwa32bppPlayer32.cfg"))
                        {
                            foreach (string line in System.IO.File.ReadAllLines("Xwa32bppPlayer32.cfg"))
                            {
                                string[] kv = line.Split('=');
                                if (kv.Length == 2 && kv[0].Trim() == "SkinsSizeThreshold")
                                {
                                    value = int.Parse(kv[1].Trim());
                                }
                            }
                        }
                    }
                    catch { }
                    _skinsSizeThreshold = value;
                }
                return _skinsSizeThreshold;
            }
        }

        // arg: optFilename \n loadSkins \n groupFaceGroups  -> required size (0 on error)
        public static int ReadOpt(string arg)
        {
            try
            {
                string[] p = arg.Split('\n');
                int loadSkins = int.Parse(p[1]);
                int group = int.Parse(p[2]);
                int size = Main.ReadOptFunction(p[0], loadSkins, group);

                int threshold = SkinsSizeThreshold;
                if (threshold > 0 && loadSkins != 0 && size > threshold)
                {
                    // plan magical-jumping-pascal A1: downscale skin textures
                    // to fit the VA budget instead of dropping them.
                    int scaled = Main.DownscaleToFit(threshold);
                    try
                    {
                        System.IO.File.AppendAllText("xwa32bpp-bridge.log",
                            DateTime.Now.ToString("HH:mm:ss") + " skins-downscale: " + p[0] + " " +
                            size + " -> " + scaled + Environment.NewLine);
                    }
                    catch { }
                    size = scaled;

                    if (size > threshold)
                    {
                        // could not fit even downscaled: last resort, no skins
                        int slim = Main.ReadOptFunction(p[0], 0, group);
                        try
                        {
                            System.IO.File.AppendAllText("xwa32bpp-bridge.log",
                                DateTime.Now.ToString("HH:mm:ss") + " skins-cap: " + p[0] + " " +
                                size + " -> " + slim + " (no skins)" + Environment.NewLine);
                        }
                        catch { }
                        size = slim;
                    }
                }

                return size;
            }
            catch (Exception ex) { Log(ex, "ReadOpt"); return 0; }
        }

        public static int GetOptVersion(string arg)
        {
            try { return Main.GetOptVersionFunction(); }
            catch (Exception ex) { Log(ex, "GetOptVersion"); return 0; }
        }

        // arg: target pointer as decimal (32-bit process: fits uint).
        // NOTE: must reinterpret the unsigned value bit-exactly — on a 32-bit
        // CLR `new IntPtr(long)` THROWS OverflowException for addresses above
        // 2 GB, and this player is large-address-aware (mingw default), so
        // mappings do land up there. (Caused zero-filled blobs -> game crash.)
        public static int WriteOpt(string arg)
        {
            try
            {
                uint address = uint.Parse(arg);
                Main.WriteOptFunction(new IntPtr(unchecked((int)address)));
                return 0;
            }
            catch (Exception ex) { Log(ex, "WriteOpt"); return -1; }
        }
    }
}
