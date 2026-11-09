// Everything the launcher does that isn't drawing: find the game, check for updates (GitHub, Google Drive),
// download and install new versions, copy and patch the game, shortcuts, uninstall.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

namespace DeltaruneOnline
{
    class Release
    {
        public string Name;
        public int Version;
        public string Url;    // a direct download (GitHub release)
        public string Id;     // or a Google Drive file id
        public string Path;   // or a local file (testing)
        public string Feed;   // the update source that listed it
        public int Rank;      // that source's place in update.txt (0 = first choice)
        public List<Release> Alternates = new List<Release>();   // the same version from other sources
    }

    class Core
    {
        public const string ExeName = "DELTARUNE Online.exe";
        public readonly string Root, App, Game, Logs, StateFile, InstalledExe;
        readonly Dictionary<string, string> state = new Dictionary<string, string>();

        // Progress for the window to show. -1 = no bar, otherwise 0..1.
        public volatile string Status = "", Detail = "";
        public double Progress = -1;

        public Core()
        {
            Root = Environment.GetEnvironmentVariable("DRO_ROOT");
            if (string.IsNullOrEmpty(Root))
                Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeltaruneOnline");
            App = Path.Combine(Root, "app");
            Game = Path.Combine(Root, "game");
            Logs = Path.Combine(Root, "logs");
            StateFile = Path.Combine(Root, "state.txt");
            InstalledExe = Path.Combine(Root, ExeName);
            LoadState();
        }

        public static bool TestMode => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DRO_ROOT"));
        public static string RunningExe => Assembly.GetExecutingAssembly().Location;

        public void Report(string status, string detail = "", double progress = -1)
        {
            Status = status;
            Detail = detail;
            Progress = progress;
        }

        public void Log(string text)
        {
            try
            {
                Directory.CreateDirectory(Logs);
                File.AppendAllText(Path.Combine(Logs, "launcher.log"), $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {text}\r\n");
            }
            catch { }
        }

        // ---------- state ----------

        void LoadState()
        {
            state.Clear();
            if (!File.Exists(StateFile)) return;
            foreach (var line in File.ReadAllLines(StateFile))
            {
                int i = line.IndexOf('=');
                if (i > 0) state[line.Substring(0, i)] = line.Substring(i + 1);
            }
        }

        public void SaveState()
        {
            Directory.CreateDirectory(Root);
            File.WriteAllLines(StateFile, state.Select(kv => kv.Key + "=" + kv.Value));
        }

        string Get(string key) => state.TryGetValue(key, out var v) ? v : "";

        public string GameDir
        {
            get => Get("gamedir");
            set { state["gamedir"] = value; SaveState(); }
        }

        public static int ReadVersion(string dir)
        {
            try { return int.Parse(File.ReadAllText(Path.Combine(dir, "version.txt")).Trim()); }
            catch { return 0; }
        }

        public int AppVersion => ReadVersion(App);
        public bool IsInstalled => AppVersion > 0 && File.Exists(Path.Combine(App, "patcher", "drm-patcher.exe"));
        public bool CanPlay => File.Exists(Path.Combine(Game, "DELTARUNE.exe")) && Get("patched") != "";

        public bool NeedsPatch
        {
            get
            {
                if (!IsGame(GameDir)) return false;
                return Get("patched") != AppVersion.ToString() || Get("gamestamp") != GameStamp(GameDir)
                    || !File.Exists(Path.Combine(Game, "DELTARUNE.exe"));
            }
        }

        // True when Steam updated the game since the last patch (and the mod didn't change).
        public bool GameChangedOnly => Get("patched") == AppVersion.ToString() && Get("gamestamp") != "" && Get("gamestamp") != GameStamp(GameDir);

        // ---------- the Steam game ----------

        public static bool IsGame(string dir) =>
            !string.IsNullOrEmpty(dir) && File.Exists(Path.Combine(dir, "DELTARUNE.exe")) && File.Exists(Path.Combine(dir, "chapter1_windows", "data.win"));

        // Steam can keep games on any drive: its library list says where.
        public static string FindGame()
        {
            var roots = new List<string>();
            foreach (var (hive, key) in new[] {
                (Registry.CurrentUser, @"Software\Valve\Steam"),
                (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam"),
                (Registry.LocalMachine, @"SOFTWARE\Valve\Steam") })
            {
                try
                {
                    using (var k = hive.OpenSubKey(key))
                    {
                        foreach (var name in new[] { "SteamPath", "InstallPath" })
                            if (k?.GetValue(name) is string p && p != "") roots.Add(p.Replace('/', '\\'));
                    }
                }
                catch { }
            }
            roots.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam"));
            foreach (var r in roots.ToList())
            {
                try
                {
                    var vdf = Path.Combine(r, "steamapps", "libraryfolders.vdf");
                    if (!File.Exists(vdf)) continue;
                    foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
                        roots.Add(m.Groups[1].Value.Replace("\\\\", "\\"));
                }
                catch { }
            }
            foreach (var r in roots)
            {
                var d = Path.Combine(r, "steamapps", "common", "DELTARUNE");
                if (IsGame(d)) return d;
            }
            return "";
        }

        // Changes whenever Steam updates the game.
        static string GameStamp(string dir)
        {
            var parts = new List<string>();
            foreach (var f in new[] { "DELTARUNE.exe" }.Concat(Enumerable.Range(1, 9).Select(c => $"chapter{c}_windows\\data.win")))
            {
                var fi = new FileInfo(Path.Combine(dir, f));
                if (fi.Exists) parts.Add($"{f}:{fi.Length}:{fi.LastWriteTimeUtc.Ticks}");
            }
            return string.Join("|", parts);
        }

        public bool GameRunning()
        {
            foreach (var p in Process.GetProcessesByName("DELTARUNE"))
            {
                try
                {
                    if (p.MainModule.FileName.StartsWith(Game, StringComparison.OrdinalIgnoreCase)) return true;
                }
                catch { }
            }
            return false;
        }

        public void StartGame()
        {
            Process.Start(new ProcessStartInfo(Path.Combine(Game, "DELTARUNE.exe")) { WorkingDirectory = Game, UseShellExecute = true });
        }

        // ---------- updates ----------

        // Where updates come from, in order of preference: DRO_FEED (testing, several separated by |),
        // then the installed package's update.txt, then the one built into the exe.
        // A source is a GitHub repository (its latest release), a public Google Drive folder, or a local folder.
        public List<string> Feeds()
        {
            var env = Environment.GetEnvironmentVariable("DRO_FEED");
            if (!string.IsNullOrEmpty(env)) return env.Split('|').Select(s => s.Trim()).Where(s => s != "").ToList();
            var f = Path.Combine(App, "update.txt");
            if (File.Exists(f))
            {
                var links = Links(File.ReadAllText(f));
                if (links.Count > 0) return links;
            }
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("update.txt"))
                if (s != null) using (var r = new StreamReader(s)) return Links(r.ReadToEnd());
            return new List<string>();
        }

        static List<string> Links(string text)
        {
            var list = new List<string>();
            foreach (var raw in text.Split('\n'))
            {
                var l = raw.Trim();
                if (l == "" || l.StartsWith("#")) continue;
                if (l.Contains("github.com/") || l.Contains("drive.google.com") || Directory.Exists(l)) list.Add(l);
            }
            return list;
        }

        static HttpWebRequest Request(string url)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.UserAgent = "DeltaruneOnline-Launcher";
            req.Timeout = 15000;
            req.ReadWriteTimeout = 30000;
            return req;
        }

        static string GetText(string url)
        {
            using (var resp = Request(url).GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return r.ReadToEnd();
        }

        static readonly Regex NameRx = new Regex(@"^DeltaruneOnline-v(\d+)\.zip$", RegexOptions.IgnoreCase);

        // Every DeltaruneOnline-v<N>.zip any update source offers. A source that can't be reached is
        // skipped, so one being down (or Google Drive's download limit) doesn't stop updates.
        public List<Release> ListReleases()
        {
            var feeds = Feeds();
            if (feeds.Count == 0) throw new Exception("this launcher has no update source set");
            var list = new List<Release>();
            Exception first = null;
            for (int i = 0; i < feeds.Count; i++)
            {
                try
                {
                    foreach (var r in ListFeed(feeds[i])) { r.Feed = feeds[i]; r.Rank = i; list.Add(r); }
                }
                catch (Exception e)
                {
                    Log($"update source {feeds[i]}: {e.Message}");
                    if (first == null) first = e;
                }
            }
            if (list.Count == 0 && first != null) throw first;
            return list;
        }

        static List<Release> ListFeed(string feed)
        {
            var list = new List<Release>();
            if (Directory.Exists(feed))
            {
                foreach (var f in Directory.GetFiles(feed, "DeltaruneOnline-v*.zip"))
                {
                    var m = NameRx.Match(Path.GetFileName(f));
                    if (m.Success) list.Add(new Release { Name = Path.GetFileName(f), Version = int.Parse(m.Groups[1].Value), Path = f });
                }
                return list;
            }
            var gh = Regex.Match(feed, @"github\.com/([\w.-]+)/([\w.-]+)");
            if (gh.Success)
            {
                // The latest release carries latest.txt naming its zip. These links aren't the GitHub API,
                // so there is no hourly request limit.
                var repo = Regex.Replace(gh.Groups[2].Value, @"\.git$", "");
                var basis = $"https://github.com/{gh.Groups[1].Value}/{repo}/releases/latest/download/";
                var name = GetText(basis + "latest.txt").Split('\n')[0].Trim();
                var m = NameRx.Match(name);
                if (!m.Success) throw new Exception("GitHub's latest release doesn't name a DeltaruneOnline zip");
                list.Add(new Release { Name = name, Version = int.Parse(m.Groups[1].Value), Url = basis + name });
                return list;
            }
            var id = Regex.Match(feed, @"(?:folders/|[?&]id=)([\w-]{10,})");
            if (!id.Success) throw new Exception("the update link isn't a GitHub or Google Drive link");
            // A public folder's file list, no sign-in needed.
            var html = GetText("https://drive.google.com/embeddedfolderview?id=" + id.Groups[1].Value);
            var entries = Regex.Matches(html, "id=\"entry-([\\w-]+)\"");
            for (int i = 0; i < entries.Count; i++)
            {
                int start = entries[i].Index;
                int end = i + 1 < entries.Count ? entries[i + 1].Index : html.Length;
                var t = Regex.Match(html.Substring(start, end - start), "flip-entry-title\">([^<]+)<");
                if (!t.Success) continue;
                var m = NameRx.Match(WebUtility.HtmlDecode(t.Groups[1].Value).Trim());
                if (m.Success) list.Add(new Release { Name = m.Value, Version = int.Parse(m.Groups[1].Value), Id = entries[i].Groups[1].Value });
            }
            return list;
        }

        // The highest version, from the first source in update.txt that has it; the others are fallbacks.
        public Release Newest()
        {
            var all = ListReleases().OrderByDescending(r => r.Version).ThenBy(r => r.Rank).ToList();
            if (all.Count == 0) return null;
            var best = all[0];
            best.Alternates = all.Skip(1).Where(r => r.Version == best.Version).ToList();
            return best;
        }

        static bool IsZip(string path)
        {
            using (var fs = File.OpenRead(path))
                return fs.ReadByte() == 'P' && fs.ReadByte() == 'K';
        }

        void DownloadTo(string url, string outPath, string what)
        {
            using (var resp = (HttpWebResponse)Request(url).GetResponse())
            using (var input = resp.GetResponseStream())
            using (var output = File.Create(outPath))
            {
                long total = resp.ContentLength, done = 0;
                var buf = new byte[81920];
                int n;
                var sw = Stopwatch.StartNew();
                while ((n = input.Read(buf, 0, buf.Length)) > 0)
                {
                    output.Write(buf, 0, n);
                    done += n;
                    if (sw.ElapsedMilliseconds > 100)
                    {
                        sw.Restart();
                        Report(what, total > 0 ? $"{done / 1048576.0:0.0} of {total / 1048576.0:0.0} MB" : $"{done / 1048576.0:0.0} MB",
                            total > 0 ? (double)done / total : -1);
                    }
                }
            }
        }

        // Tries the release's own source first, then the same version from the other sources.
        public void Download(Release rel, string outPath, string what)
        {
            Exception last = null;
            foreach (var r in new[] { rel }.Concat(rel.Alternates))
            {
                try { DownloadOne(r, outPath, what); return; }
                catch (Exception e)
                {
                    last = e;
                    Log($"download {r.Name} from {r.Feed}: {e.Message}");
                }
            }
            throw last;
        }

        void DownloadOne(Release rel, string outPath, string what)
        {
            if (rel.Path != null) { File.Copy(rel.Path, outPath, true); return; }
            if (rel.Url != null)
            {
                DownloadTo(rel.Url, outPath, what);
                if (!IsZip(outPath)) throw new Exception("the download isn't a zip file");
                return;
            }
            DownloadTo($"https://drive.usercontent.google.com/download?id={rel.Id}&export=download&confirm=t", outPath, what);
            if (IsZip(outPath)) return;
            // Big files get a "can't scan for viruses" page first: submit its form to get the file.
            var page = File.ReadAllText(outPath);
            var form = Regex.Match(page, "<form[^>]*id=\"download-form\"[^>]*action=\"([^\"]+)\"");
            if (!form.Success) throw new Exception("Google Drive didn't send the file. Is the folder shared as \"Anyone with the link\"?");
            var q = Regex.Matches(page, "<input type=\"hidden\" name=\"([^\"]+)\" value=\"([^\"]*)\"").Cast<Match>()
                .Select(m => m.Groups[1].Value + "=" + Uri.EscapeDataString(WebUtility.HtmlDecode(m.Groups[2].Value)));
            DownloadTo(WebUtility.HtmlDecode(form.Groups[1].Value) + "?" + string.Join("&", q), outPath, what);
            if (!IsZip(outPath)) throw new Exception("Google Drive sent a web page instead of the update");
        }

        // Like ZipFile.ExtractToDirectory, but retries a file an antivirus is still scanning.
        static void Extract(string zip, string dest)
        {
            var full = Path.GetFullPath(dest) + "\\";
            using (var z = ZipFile.OpenRead(zip))
            {
                foreach (var e in z.Entries)
                {
                    var name = e.FullName.Replace('/', '\\');
                    var outPath = Path.GetFullPath(Path.Combine(dest, name));
                    if (!outPath.StartsWith(full, StringComparison.OrdinalIgnoreCase)) throw new Exception("bad path in the zip: " + name);
                    if (name.EndsWith("\\")) { Directory.CreateDirectory(outPath); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(outPath));
                    for (int attempt = 1; ; attempt++)
                    {
                        try { e.ExtractToFile(outPath, true); break; }
                        catch (IOException) when (attempt < 20) { Thread.Sleep(500); }
                    }
                }
            }
        }

        static void DeleteDir(string dir)
        {
            for (int attempt = 1; Directory.Exists(dir); attempt++)
            {
                try { Directory.Delete(dir, true); }
                catch (Exception) when (attempt < 10) { Thread.Sleep(500); }
            }
        }

        static void CopyDir(string src, string dst)
        {
            foreach (var f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
            {
                var o = Path.Combine(dst, f.Substring(src.Length).TrimStart('\\'));
                Directory.CreateDirectory(Path.GetDirectoryName(o));
                File.Copy(f, o, true);
            }
        }

        // Puts an unpacked package (a folder with version.txt and patcher\) in place of app\.
        void PutPackage(string dir)
        {
            if (ReadVersion(dir) == 0 || !File.Exists(Path.Combine(dir, "patcher", "drm-patcher.exe")))
                throw new Exception("the download is missing files");
            var old = Path.Combine(Root, "app.old");
            DeleteDir(old);
            if (Directory.Exists(App)) MoveDir(App, old);
            try { MoveDir(dir, App); }
            catch
            {
                if (Directory.Exists(old) && !Directory.Exists(App)) MoveDir(old, App);
                throw;
            }
            try { DeleteDir(old); } catch { }
        }

        // Directory.Move fails while an antivirus is still scanning new files inside (seen with Trend Micro).
        // Wait a little; if it stays locked, copy instead (reading is allowed during a scan) and tidy up after.
        void MoveDir(string src, string dst)
        {
            for (int attempt = 1; attempt <= 12; attempt++)
            {
                try { Directory.Move(src, dst); return; }
                catch (IOException) { Thread.Sleep(500); }
                catch (UnauthorizedAccessException) { Thread.Sleep(500); }
            }
            Log($"move {src} -> {dst} stayed locked: copying instead");
            foreach (var f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
            {
                var o = Path.Combine(dst, f.Substring(src.Length).TrimStart('\\'));
                Directory.CreateDirectory(Path.GetDirectoryName(o));
                for (int attempt = 1; ; attempt++)
                {
                    try { File.Copy(f, o, true); break; }
                    catch (IOException) when (attempt < 20) { Thread.Sleep(500); }
                    catch (UnauthorizedAccessException) when (attempt < 20) { Thread.Sleep(500); }
                }
            }
            try { DeleteDir(src); } catch (Exception e) { Log("couldn't remove " + src + ": " + e.Message); }
        }

        // Downloads a release and installs it as app\.
        public void InstallRelease(Release rel)
        {
            Directory.CreateDirectory(Root);
            var zip = Path.Combine(Root, "download.zip");
            var staging = Path.Combine(Root, "staging");
            try
            {
                Download(rel, zip, $"Downloading version {rel.Version}...");
                Report($"Unpacking version {rel.Version}...", "", -1);
                DeleteDir(staging);
                Extract(zip, staging);
                var ver = Directory.GetFiles(staging, "version.txt", SearchOption.AllDirectories).OrderBy(f => f.Length).FirstOrDefault();
                if (ver == null) throw new Exception("the download is missing files");
                PutPackage(Path.GetDirectoryName(ver));
                Log($"installed version {rel.Version} from {rel.Name}");
            }
            finally
            {
                try { File.Delete(zip); } catch { }
                try { DeleteDir(staging); } catch { }
            }
        }

        // Installs an unzipped package folder (the exe was started from inside one).
        public void InstallFolder(string dir)
        {
            Report("Installing...", "", -1);
            var staging = Path.Combine(Root, "staging");
            DeleteDir(staging);
            CopyDir(dir, staging);
            PutPackage(staging);
            Log($"installed version {AppVersion} from {dir}");
        }

        // The package folder next to the running exe, if it was started from an unzipped download.
        public static string LocalPackage()
        {
            var dir = Path.GetDirectoryName(RunningExe);
            return ReadVersion(dir) > 0 && File.Exists(Path.Combine(dir, "patcher", "drm-patcher.exe")) ? dir : null;
        }

        static string Hash(string path)
        {
            using (var sha = SHA256.Create())
            using (var fs = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(fs));
        }

        // Puts the launcher in its installed place. Returns true when the running launcher is out of date
        // and the new one must be started instead (it was swapped in already).
        public bool PlaceLauncher()
        {
            Directory.CreateDirectory(Root);
            var running = RunningExe;
            var packaged = Path.Combine(App, ExeName);
            var best = File.Exists(packaged) ? packaged : running;
            bool runningIsInstalled = string.Equals(Path.GetFullPath(running), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);
            if (File.Exists(InstalledExe) && Hash(InstalledExe) == Hash(best)) return false;
            if (runningIsInstalled)
            {
                // A running exe can't be overwritten, but it can be renamed out of the way.
                var old = Path.Combine(Root, "DELTARUNE Online.old.exe");
                try { File.Delete(old); } catch { }
                File.Move(InstalledExe, old);
                File.Copy(best, InstalledExe, true);
                Log("launcher updated");
                return true;
            }
            File.Copy(best, InstalledExe, true);
            return false;
        }

        public void CleanOldLauncher()
        {
            try { File.Delete(Path.Combine(Root, "DELTARUNE Online.old.exe")); } catch { }
        }

        // ---------- copying and patching the game ----------

        public void PatchGame()
        {
            var src = GameDir;
            if (!IsGame(src)) throw new Exception("DELTARUNE wasn't found at " + src);
            if (GameRunning()) throw new Exception("DELTARUNE Online is running. Close the game, then try again.");
            var patcher = Path.Combine(App, "patcher", "drm-patcher.exe");
            if (!File.Exists(patcher)) throw new Exception("drm-patcher.exe is missing. Your antivirus may have removed it: restore it, or uninstall and install again.");

            CopyGame(src);

            var chapters = Enumerable.Range(1, 9).Where(c => File.Exists(Path.Combine(src, $"chapter{c}_windows", "data.win"))).ToList();
            int done = 0, failed = 0;
            Directory.CreateDirectory(Logs);
            for (int i = 0; i < chapters.Count; i++)
            {
                int ch = chapters[i];
                Report($"Patching Chapter {ch}...", $"{i + 1} of {chapters.Count}", (double)i / chapters.Count);
                var input = Path.Combine(src, $"chapter{ch}_windows", "data.win");
                var output = Path.Combine(Game, $"chapter{ch}_windows", "data.win");
                Directory.CreateDirectory(Path.GetDirectoryName(output));
                int code;
                string text;
                try
                {
                    var psi = new ProcessStartInfo(patcher)
                    {
                        Arguments = $"\"{input}\" \"{output}\" \"{Path.Combine(App, "mod")}\" {ch}",
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        WorkingDirectory = App,
                    };
                    // A separate game name keeps this mod's saves apart from the normal ones.
                    psi.EnvironmentVariables["DRM_SAVE_NAME"] = "DELTARUNE_ONLINE";
                    using (var p = Process.Start(psi))
                    {
                        var err = p.StandardError.ReadToEndAsync();
                        text = p.StandardOutput.ReadToEnd();
                        p.WaitForExit();
                        text += err.Result;
                        code = p.ExitCode;
                    }
                }
                catch (Exception e)
                {
                    File.Copy(input, output, true);
                    throw new Exception($"Windows or your antivirus wouldn't let the patcher start ({e.Message}). Allow \"{patcher}\" in your antivirus, then try again.");
                }
                File.WriteAllText(Path.Combine(Logs, $"patch_chapter{ch}.log"), text);
                if (code == 0) done++;
                else
                {
                    failed++;
                    Log($"chapter {ch} patch failed (code {code})");
                    File.Copy(input, output, true);
                }
            }
            if (done == 0) throw new Exception("No chapter could be patched. Your DELTARUNE may be a different version than this mod was made for.");
            state["patched"] = AppVersion.ToString();
            state["gamestamp"] = GameStamp(src);
            state["failed"] = failed.ToString();
            SaveState();
            Log($"patched version {AppVersion}: {done} chapters, {failed} failed");
        }

        public void ForgetPatch()
        {
            state["patched"] = "";
            SaveState();
        }

        public int FailedChapters => int.TryParse(Get("failed"), out var n) ? n : 0;

        // Mirrors the Steam folder into game\ (only changed files), leaving out data.win: the patcher writes those.
        void CopyGame(string src)
        {
            Report("Copying the game...", "Your Steam copy is left alone", 0);
            src = Path.GetFullPath(src).TrimEnd('\\');
            Directory.CreateDirectory(Game);
            var files = Directory.GetFiles(src, "*", SearchOption.AllDirectories);
            var wanted = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var todo = new List<(string from, string to, long len, DateTime time)>();
            long total = 0;
            foreach (var f in files)
            {
                var rel = f.Substring(src.Length + 1);
                wanted.Add(rel);
                if (Path.GetFileName(rel).Equals("data.win", StringComparison.OrdinalIgnoreCase)) continue;
                var fi = new FileInfo(f);
                var di = new FileInfo(Path.Combine(Game, rel));
                if (di.Exists && di.Length == fi.Length && di.LastWriteTimeUtc == fi.LastWriteTimeUtc) continue;
                todo.Add((f, di.FullName, fi.Length, fi.LastWriteTimeUtc));
                total += fi.Length;
            }
            var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(Root))).AvailableFreeSpace;
            long needed = total + files.Where(f => f.EndsWith("data.win", StringComparison.OrdinalIgnoreCase)).Sum(f => new FileInfo(f).Length);
            if (free < needed + 100L * 1048576)
                throw new Exception($"Not enough disk space: it needs about {needed / 1073741824.0 + 0.1:0.0} GB free on drive {Path.GetPathRoot(Root)}");

            long done = 0;
            var buf = new byte[1 << 20];
            var sw = Stopwatch.StartNew();
            foreach (var t in todo)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(t.to));
                using (var input = new FileStream(t.from, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (var output = new FileStream(t.to, FileMode.Create, FileAccess.Write))
                {
                    int n;
                    while ((n = input.Read(buf, 0, buf.Length)) > 0)
                    {
                        output.Write(buf, 0, n);
                        done += n;
                        if (sw.ElapsedMilliseconds > 100)
                        {
                            sw.Restart();
                            Report("Copying the game...", $"{done / 1048576} of {total / 1048576} MB  (your Steam copy is left alone)", (double)done / Math.Max(1, total));
                        }
                    }
                }
                File.SetLastWriteTimeUtc(t.to, t.time);
            }
            // Files Steam removed.
            foreach (var f in Directory.GetFiles(Game, "*", SearchOption.AllDirectories))
            {
                var rel = f.Substring(Game.Length).TrimStart('\\');
                if (!wanted.Contains(rel)) try { File.Delete(f); } catch { }
            }
        }

        // ---------- shortcuts and uninstall ----------

        static void MakeShortcut(string path, string target, string workDir, string description)
        {
            var type = Type.GetTypeFromProgID("WScript.Shell");
            var shell = Activator.CreateInstance(type);
            var lnk = type.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            var lt = lnk.GetType();
            lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
            lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { workDir });
            lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { description });
            lt.InvokeMember("IconLocation", BindingFlags.SetProperty, null, lnk, new object[] { target + ",0" });
            lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
        }

        static IEnumerable<string> ShortcutPaths() => new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "DELTARUNE Online.lnk"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "DELTARUNE Online.lnk"),
        };

        public void CreateShortcuts()
        {
            if (TestMode) return;   // a test install leaves the desktop alone
            foreach (var p in ShortcutPaths())
            {
                try { MakeShortcut(p, InstalledExe, Root, "Play DELTARUNE online with friends"); }
                catch (Exception e) { Log("shortcut failed: " + p + ": " + e.Message); }
            }
        }

        // Removes everything but the mod's saves. The running exe is deleted by a helper once this closes.
        public void Uninstall()
        {
            if (!TestMode) foreach (var p in ShortcutPaths()) try { File.Delete(p); } catch { }
            DeleteDir(Game);
            DeleteDir(App);
            try { File.Delete(StateFile); } catch { }
            Process.Start(new ProcessStartInfo("cmd.exe", $"/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"{Root}\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                WorkingDirectory = Path.GetTempPath(),
            });
        }
    }
}
