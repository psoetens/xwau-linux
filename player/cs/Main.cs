using JeremyAnsel.Xwa.Opt;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO.Compression;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System;
using System.Linq;

namespace Xwa32bppPlayerNet
{
    public static class Main
    {
        private static string _settingsMissionFileName;
        private static int _settingsMmissionFileNameIndex;
        private static bool _settingsIsTechLibraryGameStateUpdate;
        private static string _settingsHangar;
        private static byte _settingsHangarIff;

        private static IList<string> _getCustomFileLines_lines;
        private static string _getCustomFileLines_name;
        private static string _getCustomFileLines_mission;
        private static int _getCustomFileLines_missionIndex;
        private static string _getCustomFileLines_hangar;
        private static byte _getCustomFileLines_hangarIff;

        [DllExport(CallingConvention.Cdecl)]
        public static void SetSettingsFunction(
            [MarshalAs(UnmanagedType.LPStr)] string missionFileName,
            int missionFileNameIndex,
            int isTechLibraryGameStateUpdate,
            [MarshalAs(UnmanagedType.LPStr)] string hangar,
            int hangarIff
            )
        {
            _settingsMissionFileName = missionFileName;
            _settingsMmissionFileNameIndex = missionFileNameIndex;
            _settingsIsTechLibraryGameStateUpdate = isTechLibraryGameStateUpdate != 0;
            _settingsHangar = hangar;
            _settingsHangarIff = (byte)hangarIff;
        }

        private static IList<string> GetCustomFileLines(string name)
        {
            string xwaMissionFileName = _settingsMissionFileName;
            int xwaMissionFileNameIndex = _settingsMmissionFileNameIndex;
            bool isTechLibraryGameStateUpdate = _settingsIsTechLibraryGameStateUpdate;
            string hangar = _settingsHangar;
            byte hangarIff = _settingsHangarIff;

            if (isTechLibraryGameStateUpdate)
            {
                _getCustomFileLines_name = name;
                _getCustomFileLines_mission = null;
                _getCustomFileLines_missionIndex = 0;
                _getCustomFileLines_lines = XwaHooksConfig.GetFileLines("FlightModels\\" + name + ".txt");
                _getCustomFileLines_hangar = null;
                _getCustomFileLines_hangarIff = 0;

                if (_getCustomFileLines_lines.Count == 0)
                {
                    _getCustomFileLines_lines = XwaHooksConfig.GetFileLines("FlightModels\\default.ini", name);
                }
            }
            else
            {
                if (_getCustomFileLines_name != name
                    || _getCustomFileLines_mission != xwaMissionFileName
                    || _getCustomFileLines_missionIndex != xwaMissionFileNameIndex
                    || _getCustomFileLines_hangar != hangar
                    || _getCustomFileLines_hangarIff != hangarIff)
                {
                    _getCustomFileLines_name = name;
                    _getCustomFileLines_mission = xwaMissionFileName;
                    _getCustomFileLines_missionIndex = xwaMissionFileNameIndex;
                    _getCustomFileLines_hangar = hangar;
                    _getCustomFileLines_hangarIff = hangarIff;

                    string mission = XwaHooksConfig.GetStringWithoutExtension(xwaMissionFileName);
                    _getCustomFileLines_lines = XwaHooksConfig.GetFileLines(mission + "_" + name + ".txt");

                    if (_getCustomFileLines_lines.Count == 0)
                    {
                        _getCustomFileLines_lines = XwaHooksConfig.GetFileLines(mission + ".ini", name);
                    }

                    if (_getCustomFileLines_hangar != null && !_getCustomFileLines_hangar.EndsWith("\\"))
                    {
                        IList<string> hangarLines = new List<string>();

                        if (hangarLines.Count == 0)
                        {
                            hangarLines = XwaHooksConfig.GetFileLines(_getCustomFileLines_hangar + name + _getCustomFileLines_hangarIff + ".txt");
                        }

                        if (hangarLines.Count == 0)
                        {
                            hangarLines = XwaHooksConfig.GetFileLines(_getCustomFileLines_hangar + ".ini", name + _getCustomFileLines_hangarIff);
                        }

                        if (hangarLines.Count == 0)
                        {
                            hangarLines = XwaHooksConfig.GetFileLines(_getCustomFileLines_hangar + name + ".txt");
                        }

                        if (hangarLines.Count == 0)
                        {
                            hangarLines = XwaHooksConfig.GetFileLines(_getCustomFileLines_hangar + ".ini", name);
                        }

                        foreach (string line in hangarLines)
                        {
                            _getCustomFileLines_lines.Add(line);
                        }
                    }

                    if (_getCustomFileLines_lines.Count == 0)
                    {
                        _getCustomFileLines_lines = XwaHooksConfig.GetFileLines("FlightModels\\" + name + ".txt");
                    }

                    if (_getCustomFileLines_lines.Count == 0)
                    {
                        _getCustomFileLines_lines = XwaHooksConfig.GetFileLines("FlightModels\\default.ini", name);
                    }
                }
            }

            return _getCustomFileLines_lines;
        }

        private static int GetFlightgroupsDefaultCount(string optName)
        {
            int count = 0;

            //for (int index = 255; index >= 0; index--)
            //{
            //    string skinName = "Default_" + index.ToString(CultureInfo.InvariantCulture);

            //    if (GetSkinDirectoryLocatorPath(optName, skinName) != null)
            //    {
            //        count = index + 1;
            //        break;
            //    }
            //}

            var locker = new object();
            var partition = Partitioner.Create(0, 256);

            Parallel.ForEach(
                partition,
                () => 0,
                (range, _, localValue) =>
                {
                    int localCount = 0;

                    for (int index = range.Item2 - 1; index >= range.Item1; index--)
                    {
                        string skinName = "Default_" + index.ToString(CultureInfo.InvariantCulture);

                        if (GetSkinDirectoryLocatorPath(optName, skinName) != null)
                        {
                            localCount = index + 1;
                            break;
                        }
                    }

                    return Math.Max(localCount, localValue);
                },
                localCount =>
                {
                    lock (locker)
                    {
                        if (localCount > count)
                        {
                            count = localCount;
                        }
                    }
                });

            return count;
        }

        private static int GetFlightgroupsCount(IList<string> objectLines, string optName)
        {
            int count = 0;

            //for (int index = 255; index >= 0; index--)
            //{
            //    string key = optName + "_fgc_" + index.ToString(CultureInfo.InvariantCulture);
            //    string value = XwaHooksConfig.GetFileKeyValue(objectLines, key);

            //    if (!string.IsNullOrEmpty(value))
            //    {
            //        count = index + 1;
            //        break;
            //    }
            //}

            var locker = new object();
            var partition = Partitioner.Create(0, 256);

            Parallel.ForEach(
                partition,
                () => 0,
                (range, _, localValue) =>
                {
                    int localCount = 0;

                    for (int index = range.Item2 - 1; index >= range.Item1; index--)
                    {
                        string key = optName + "_fgc_" + index.ToString(CultureInfo.InvariantCulture);
                        string value = XwaHooksConfig.GetFileKeyValue(objectLines, key);

                        if (!string.IsNullOrEmpty(value))
                        {
                            localCount = index + 1;
                            break;
                        }
                    }

                    return Math.Max(localCount, localValue);
                },
                localCount =>
                {
                    lock (locker)
                    {
                        if (localCount > count)
                        {
                            count = localCount;
                        }
                    }
                });

            return count;
        }

        private static List<int> GetFlightgroupsColors(IList<string> objectLines, string optName, int fgCount, bool hasDefaultSkin)
        {
            bool hasBaseSkins = hasDefaultSkin || !string.IsNullOrEmpty(XwaHooksConfig.GetFileKeyValue(objectLines, optName));

            var colors = new List<int>();

            //for (int index = 0; index < 256; index++)
            //{
            //    string key = optName + "_fgc_" + index.ToString(CultureInfo.InvariantCulture);
            //    string value = XwaHooksConfig.GetFileKeyValue(objectLines, key);

            //    if (!string.IsNullOrEmpty(value) || (hasBaseSkins && index < fgCount))
            //    {
            //        colors.Add(index);
            //    }
            //}

            var locker = new object();
            var partition = Partitioner.Create(0, 256);

            Parallel.ForEach(
                partition,
                () => new List<int>(),
                (range, _, localValue) =>
                {
                    for (int index = range.Item1; index < range.Item2; index++)
                    {
                        string key = optName + "_fgc_" + index.ToString(CultureInfo.InvariantCulture);
                        string value = XwaHooksConfig.GetFileKeyValue(objectLines, key);

                        if (!string.IsNullOrEmpty(value) || (hasBaseSkins && index < fgCount))
                        {
                            localValue.Add(index);
                        }
                    }

                    return localValue;
                },
                localCount =>
                {
                    lock (locker)
                    {
                        colors.AddRange(localCount);
                    }
                });

            return colors;
        }

        private static string GetSkinDirectoryLocatorPath(string optName, string skinName)
        {
            string[] skinNameParts = skinName.Split('-');
            skinName = skinNameParts[0];
            string path = "FlightModels\\Skins\\" + optName + "\\" + skinName; // was C#6 $-interpolation; framework csc is C#5

            var baseDirectoryInfo = new DirectoryInfo(path);
            bool baseDirectoryExists = baseDirectoryInfo.Exists && baseDirectoryInfo.EnumerateFiles().Any();

            if (baseDirectoryExists)
            {
                return path;
            }

            if (File.Exists(path + ".zip"))
            {
                return path + ".zip";
            }

            return null;
        }

        private static OptFile _tempOptFile;
        private static int _tempOptFileSize;

        [DllExport(CallingConvention.Cdecl)]
        public static int ReadOptFunction([MarshalAs(UnmanagedType.LPStr)] string optFilename, int loadSkins, int groupFaceGroups)
        {
            _tempOptFile = null;
            _tempOptFileSize = 0;

            if (!File.Exists(optFilename))
            {
                return 0;
            }

            string optName = Path.GetFileNameWithoutExtension(optFilename);

            var opt = OptFile.FromFile(optFilename, false);

            if (Directory.Exists("FlightModels\\Skins\\" + optName)) // was C#6 $-interpolation
            {
                IList<string> objectLines = loadSkins == 0 ? new List<string>() : GetCustomFileLines("Skins");
                IList<string> baseSkins = loadSkins == 0 ? new List<string>() : XwaHooksConfig.Tokennize(XwaHooksConfig.GetFileKeyValue(objectLines, optName));
                bool hasDefaultSkin = GetSkinDirectoryLocatorPath(optName, "Default") != null || (loadSkins == 0 ? GetSkinDirectoryLocatorPath(optName, "Default_0") != null : GetFlightgroupsDefaultCount(optName) != 0);
                int fgCount = loadSkins == 0 ? 0 : GetFlightgroupsCount(objectLines, optName);
                bool hasSkins = hasDefaultSkin || baseSkins.Count != 0 || fgCount != 0;

                if (hasSkins)
                {
                    if (loadSkins == 0)
                    {
                        fgCount = 1;
                    }
                    else
                    {
                        fgCount = Math.Max(fgCount, opt.MaxTextureVersion);
                        fgCount = Math.Max(fgCount, GetFlightgroupsDefaultCount(optName));
                    }

                    UpdateOptFile(optName, opt, objectLines, baseSkins, fgCount, hasDefaultSkin);
                }
            }

            if (groupFaceGroups != 0)
            {
                opt.GroupFaceGroups();
            }

            _tempOptFile = opt;
            _tempOptFileSize = opt.GetSaveRequiredFileSize(false);

            return _tempOptFileSize;
        }

        // plan magical-jumping-pascal A1: the win32-wine game has only
        // ~250-500MB contiguous VA free (host .so's share the 4GB space), so
        // fully-skinned hero blobs (341-385MB; view+buffer = 2x) can never be
        // received reliably. Instead of DROPPING skins (the old cap), halve
        // the per-FG skin textures (the "_fg_" copies are ~80% of the blob)
        // until the save size fits the budget. Box-filtered, mipmaps
        // regenerated; base textures untouched.
        public static int DownscaleToFit(int budget)
        {
            if (_tempOptFile == null)
            {
                return _tempOptFileSize;
            }

            for (int pass = 0; pass < 3; pass++)
            {
                int size = _tempOptFile.GetSaveRequiredFileSize(false);
                if (size <= budget)
                {
                    break;
                }

                int floor = pass == 0 ? 512 : 256; // first halve big maps, then medium
                bool changed = false;

                foreach (var kv in _tempOptFile.Textures)
                {
                    Texture tex = kv.Value;
                    if (kv.Key.IndexOf("_fg_", StringComparison.Ordinal) == -1) continue;
                    if (tex.BitsPerPixel != 32) continue;
                    int w = tex.Width, h = tex.Height;
                    if (w < floor || h < floor || (w / 2) * 2 != w || (h / 2) * 2 != h) continue;

                    tex.RemoveMipmaps();
                    int nw = w / 2, nh = h / 2;
                    byte[] srcData = tex.ImageData;
                    byte[] dst = new byte[nw * nh * 4];
                    for (int y = 0; y < nh; y++)
                    {
                        int r0 = (y * 2) * w * 4, r1 = (y * 2 + 1) * w * 4, o = y * nw * 4;
                        for (int x = 0; x < nw; x++)
                        {
                            int s0 = r0 + x * 8, s1 = r1 + x * 8, d = o + x * 4;
                            for (int c = 0; c < 4; c++)
                                dst[d + c] = (byte)((srcData[s0 + c] + srcData[s0 + 4 + c] + srcData[s1 + c] + srcData[s1 + 4 + c] + 2) >> 2);
                        }
                    }

                    byte[] alpha = tex.AlphaIllumData;
                    byte[] nalpha = null;
                    if (alpha != null && alpha.Length >= w * h)
                    {
                        nalpha = new byte[nw * nh];
                        for (int y = 0; y < nh; y++)
                        {
                            int r0 = (y * 2) * w, r1 = (y * 2 + 1) * w, o = y * nw;
                            for (int x = 0; x < nw; x++)
                                nalpha[o + x] = (byte)((alpha[r0 + x * 2] + alpha[r0 + x * 2 + 1] + alpha[r1 + x * 2] + alpha[r1 + x * 2 + 1] + 2) >> 2);
                        }
                    }

                    tex.Width = nw;
                    tex.Height = nh;
                    tex.ImageData = dst;
                    tex.AlphaIllumData = nalpha;
                    tex.GenerateMipmaps();
                    changed = true;
                }

                if (!changed)
                {
                    break;
                }
            }

            _tempOptFileSize = _tempOptFile.GetSaveRequiredFileSize(false);
            return _tempOptFileSize;
        }

        [DllExport(CallingConvention.Cdecl)]
        public static int GetOptVersionFunction()
        {
            if (_tempOptFile == null)
            {
                return 0;
            }

            return _tempOptFile.Version;
        }

        [DllExport(CallingConvention.Cdecl)]
        public static unsafe void WriteOptFunction(IntPtr ptr)
        {
            if (ptr == IntPtr.Zero || _tempOptFile == null || _tempOptFileSize == 0)
            {
                _tempOptFile = null;
                _tempOptFileSize = 0;
                return;
            }

            using (var stream = new UnmanagedMemoryStream((byte*)ptr, _tempOptFileSize, _tempOptFileSize, FileAccess.Write))
            {
                _tempOptFile.Save(stream, false, false, false);
            }

            _tempOptFile = null;
            _tempOptFileSize = 0;
        }

        private static void UpdateOptFile(string optName, OptFile opt, IList<string> objectLines, IList<string> baseSkins, int fgCount, bool hasDefaultSkin)
        {
            List<List<string>> fgSkins = ReadFgSkins(optName, objectLines, baseSkins, fgCount);
            List<string> distinctSkins = fgSkins.SelectMany(t => t).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            ICollection<string> texturesExist = GetTexturesExist(optName, opt, distinctSkins);
            List<int> fgColors = GetFlightgroupsColors(objectLines, optName, fgCount, hasDefaultSkin);
            CreateSwitchTextures(opt, texturesExist, fgSkins, fgColors);
            UpdateSkins(optName, opt, distinctSkins, fgSkins);
        }

        private static List<List<string>> ReadFgSkins(string optName, IList<string> objectLines, IList<string> baseSkins, int fgCount)
        {
            var fgSkins = new List<List<string>>(fgCount);

            for (int i = 0; i < fgCount; i++)
            {
                var skins = new List<string>(baseSkins);
                string fgKey = optName + "_fgc_" + i.ToString(CultureInfo.InvariantCulture);
                skins.AddRange(XwaHooksConfig.Tokennize(XwaHooksConfig.GetFileKeyValue(objectLines, fgKey)));

                if (skins.Count == 0)
                {
                    string skinName = "Default_" + i.ToString(CultureInfo.InvariantCulture);

                    if (GetSkinDirectoryLocatorPath(optName, skinName) != null)
                    {
                        skins.Add(skinName);
                    }
                    else
                    {
                        skins.Add("Default");
                    }
                }

                fgSkins.Add(skins);
            }

            return fgSkins;
        }

        private static ICollection<string> GetTexturesExist(string optName, OptFile opt, List<string> distinctSkins)
        {
            var texturesExist = new SortedSet<string>();

            foreach (string skin in distinctSkins)
            {
                string path = GetSkinDirectoryLocatorPath(optName, skin);

                if (path == null)
                {
                    continue;
                }

                string[] filenames;

                if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                {
                    using (ZipArchive zip = ZipFile.OpenRead(path)) // was C#8 using-declaration
                    {
                        ZipArchiveEntry[] files = zip.Entries.ToArray();
                        filenames = Array.ConvertAll(files, t => t.Name);
                    }
                }
                else
                {
                    string[] files = Directory.GetFiles(path);
                    filenames = Array.ConvertAll(files, t => Path.GetFileName(t));
                }

                SortedSet<string> filesSet = new SortedSet<string>(filenames, StringComparer.OrdinalIgnoreCase); // was C#9 target-typed new

                foreach (string textureName in opt.Textures.Keys)
                {
                    if (TextureExists(filesSet, textureName, skin) != null)
                    {
                        texturesExist.Add(textureName);
                    }
                }
            }

            return texturesExist;
        }

        private static void CreateSwitchTextures(OptFile opt, ICollection<string> texturesExist, List<List<string>> fgSkins, List<int> fgColors)
        {
            int fgCount = fgSkins.Count;

            if (fgCount == 0)
            {
                return;
            }

            var newTextures = new ConcurrentBag<Texture>();

            foreach (var texture in opt.Textures.Where(texture => texturesExist.Contains(texture.Key)))
            {
                //texture.Value.Convert8To32(false, true);

                foreach (int i in fgColors)
                {
                    Texture newTexture = texture.Value.Clone();
                    newTexture.Name += "_fg_" + i.ToString(CultureInfo.InvariantCulture) + "_" + string.Join(",", fgSkins[i]);
                    newTextures.Add(newTexture);
                }
            }

            foreach (var newTexture in newTextures)
            {
                opt.Textures.Add(newTexture.Name, newTexture);
            }

            opt.Meshes
                .SelectMany(t => t.Lods)
                .SelectMany(t => t.FaceGroups)
                .AsParallel()
                .ForAll(faceGroup =>
                {
                    if (faceGroup.Textures.Count == 0)
                    {
                        return;
                    }

                    string name = faceGroup.Textures[0];

                    if (!texturesExist.Contains(name))
                    {
                        return;
                    }

                    for (int i = 0; i < fgCount; i++)
                    {
                        string textureName;

                        if (fgColors.Contains(i))
                        {
                            textureName = name + "_fg_" + i.ToString(CultureInfo.InvariantCulture) + "_" + string.Join(",", fgSkins[i]);
                        }
                        else
                        {
                            textureName = i < faceGroup.Textures.Count ? faceGroup.Textures[i] : name;
                        }

                        if (i < faceGroup.Textures.Count)
                        {
                            faceGroup.Textures[i] = textureName;
                        }
                        else
                        {
                            faceGroup.Textures.Add(textureName);
                        }
                    }
                });
        }

        private static void UpdateSkins(string optName, OptFile opt, List<string> distinctSkins, List<List<string>> fgSkins)
        {
            var locatorsPath = new ConcurrentDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var filesSets = new ConcurrentDictionary<string, SortedSet<string>>(StringComparer.OrdinalIgnoreCase);

            distinctSkins.AsParallel().ForAll(skin =>
            {
                string path = GetSkinDirectoryLocatorPath(optName, skin);
                locatorsPath[skin] = path;

                SortedSet<string> filesSet = null;

                if (path != null)
                {
                    string[] filenames;

                    if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                    {
                        using (ZipArchive zip = ZipFile.OpenRead(path)) // was C#8 using-declaration
                        {
                            ZipArchiveEntry[] files = zip.Entries.ToArray();
                            filenames = Array.ConvertAll(files, t => t.Name);
                        }
                    }
                    else
                    {
                        string[] files = Directory.GetFiles(path);
                        filenames = Array.ConvertAll(files, t => Path.GetFileName(t));
                    }

                    filesSet = new SortedSet<string>(filenames, StringComparer.OrdinalIgnoreCase); // was C#9 target-typed new
                }

                filesSets[skin] = filesSet ?? new SortedSet<string>();
            });

            opt.Textures.Where(texture => texture.Key.IndexOf("_fg_") != -1).AsParallel().ForAll(texture =>
            {
                int position = texture.Key.IndexOf("_fg_");

                if (position == -1)
                {
                    return;
                }

                texture.Value.Convert8To32(false, true);

                string textureName = texture.Key.Substring(0, position);
                int fgIndex = int.Parse(texture.Key.Substring(position + 4, texture.Key.IndexOf('_', position + 4) - position - 4), CultureInfo.InvariantCulture);

                foreach (string skin in fgSkins[fgIndex])
                {
                    string path = locatorsPath[skin];

                    if (path == null)
                    {
                        continue;
                    }

                    string filename = TextureExists(filesSets[skin], textureName, skin);

                    if (filename == null)
                    {
                        continue;
                    }

                    Stream file = null;
                    ZipArchive zip = null;

                    try
                    {
                        if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                        {
                            zip = ZipFile.OpenRead(path);
                            //file = zip.GetEntry(filename)!.Open();

                            foreach (ZipArchiveEntry entry in zip.Entries)
                            {
                                if (string.Equals(entry.Name, filename, StringComparison.OrdinalIgnoreCase))
                                {
                                    file = entry.Open();
                                    break;
                                }
                            }
                        }
                        else
                        {
                            file = File.OpenRead(Path.Combine(path, filename));
                        }

                        CombineTextures(texture.Value, file, filename, skin);
                    }
                    finally
                    {
                        if (file != null) file.Dispose(); // was C#6 null-conditional
                        if (zip != null) zip.Dispose();
                    }
                }

                texture.Value.GenerateMipmaps();
            });
        }

        private static void CombineTextures(Texture baseTexture, Stream file, string filename, string skin)
        {
            string[] skinParts = skin.Split('-');
            skin = skinParts[0];
            int skinOpacity = 100;
            int opacity; // was C#7 out-var
            if (skinParts.Length > 1 && int.TryParse(skinParts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out opacity))
            {
                opacity = Math.Max(0, Math.Min(100, opacity));
                skinOpacity = opacity;
            }

            Texture newTexture;

            newTexture = Texture.FromStream(file);
            newTexture.Name = Path.GetFileNameWithoutExtension(filename);

            if (newTexture.Width != baseTexture.Width || newTexture.Height != baseTexture.Height)
            {
                return;
            }

            newTexture.Convert8To32(false);
            FlipPixels(newTexture.ImageData, newTexture.Width, newTexture.Height, 32);

            int size = baseTexture.Width * baseTexture.Height;
            byte[] src = newTexture.ImageData;
            byte[] dst = baseTexture.ImageData;

            for (int i = 0; i < size; i++)
            {
                int a = src[i * 4 + 3];

                a = (a * skinOpacity + 50) / 100;

                dst[i * 4 + 0] = (byte)(dst[i * 4 + 0] * (255 - a) / 255 + src[i * 4 + 0] * a / 255);
                dst[i * 4 + 1] = (byte)(dst[i * 4 + 1] * (255 - a) / 255 + src[i * 4 + 1] * a / 255);
                dst[i * 4 + 2] = (byte)(dst[i * 4 + 2] * (255 - a) / 255 + src[i * 4 + 2] * a / 255);
            }

            //var partition = Partitioner.Create(0, size);

            //Parallel.ForEach(partition, range =>
            //{
            //    for (int i = range.Item1; i < range.Item2; i++)
            //    {
            //        int a = src[i * 4 + 3];

            //        a = (a * skinOpacity + 50) / 100;

            //        dst[i * 4 + 0] = (byte)(dst[i * 4 + 0] * (255 - a) / 255 + src[i * 4 + 0] * a / 255);
            //        dst[i * 4 + 1] = (byte)(dst[i * 4 + 1] * (255 - a) / 255 + src[i * 4 + 1] * a / 255);
            //        dst[i * 4 + 2] = (byte)(dst[i * 4 + 2] * (255 - a) / 255 + src[i * 4 + 2] * a / 255);
            //    }
            //});
        }

        private static void FlipPixels(byte[] pixels, int width, int height, int bpp)
        {
            int length = pixels.Length;
            int offset = 0;
            int w = width;
            int h = height;

            while (offset < length)
            {
                int stride = w * bpp / 8;

                for (int i = 0; i < h / 2; i++)
                {
                    for (int j = 0; j < stride; j++)
                    {
                        byte v = pixels[offset + i * stride + j];
                        pixels[offset + i * stride + j] = pixels[offset + (h - 1 - i) * stride + j];
                        pixels[offset + (h - 1 - i) * stride + j] = v;
                    }
                }

                offset += h * stride;

                w = w > 1 ? w / 2 : 1;
                h = h > 1 ? h / 2 : 1;
            }
        }

        private static readonly string[] _textureExtensions = new string[] { ".bmp", ".png", ".jpg" };

        private static string TextureExists(ICollection<string> files, string baseFilename, string skin)
        {
            string[] skinParts = skin.Split('-');
            skin = skinParts[0];

            foreach (string ext in _textureExtensions)
            {
                string filename = baseFilename + "_" + skin + ext;

                if (files.Contains(filename))
                {
                    return filename;
                }
            }

            foreach (string ext in _textureExtensions)
            {
                string filename = baseFilename + ext;

                if (files.Contains(filename))
                {
                    return filename;
                }
            }

            return null;
        }
    }
}
