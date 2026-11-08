// The steps the launcher runs, shared by the window and the --auto test mode.
using System;
using System.IO;

namespace DeltaruneOnline
{
    static class Flow
    {
        // First install: the newest version (from the update folder, or the unzipped download it was started
        // from), the launcher in its place, shortcuts, then the patched game copy. Returns a note for the Ready screen.
        public static string Install(Core core)
        {
            core.Report("Getting ready...", "Looking for the newest version", -1);
            Release newest = null;
            string offline = null;
            try { newest = core.Newest(); }
            catch (Exception e) { offline = e.Message; core.Log("update folder: " + e.Message); }
            var local = Core.LocalPackage();
            if (local != null && (newest == null || Core.ReadVersion(local) >= newest.Version)) core.InstallFolder(local);
            else if (newest != null) core.InstallRelease(newest);
            else if (offline != null) throw new Exception("Couldn't reach the update folder: " + offline + ". Check your internet connection.");
            else throw new Exception("The update folder has no DeltaruneOnline zip in it yet. Ask whoever sent you this.");
            core.PlaceLauncher();
            core.CreateShortcuts();
            core.PatchGame();
            return $"Installed version {core.AppVersion}. There's a DELTARUNE Online shortcut on your desktop now.";
        }

        // Every start: install a newer version if there is one, then re-patch if the mod or the game changed.
        // restart = the launcher itself was updated: start the installed one and close this one.
        public static string Update(Core core, bool checkOnline, out bool restart)
        {
            restart = false;
            string note = "";
            if (checkOnline)
            {
                core.Report("Checking for updates...", "", -1);
                try
                {
                    var newest = core.Newest();
                    if (newest == null || newest.Version <= core.AppVersion) note = $"Mod version {core.AppVersion}, up to date.";
                    else if (core.GameRunning()) note = $"Version {newest.Version} is out. Close the game and open this again to update.";
                    else
                    {
                        core.InstallRelease(newest);
                        note = $"Updated to version {core.AppVersion}.";
                    }
                }
                catch (Exception e)
                {
                    core.Log("update check: " + e.Message);
                    note = $"Couldn't check for updates ({Short(e.Message)}). Mod version {core.AppVersion}.";
                }
            }
            else note = $"Updated to version {core.AppVersion}.";
            try { restart = core.PlaceLauncher(); }
            catch (Exception e) { core.Log("launcher update: " + e.Message); }
            if (restart) return note;
            if (core.NeedsPatch)
            {
                if (core.GameChangedOnly) note += " DELTARUNE was updated on Steam, so it was patched again.";
                core.PatchGame();
            }
            return note;
        }

        public static string Short(string s)
        {
            s = s.Split('\n')[0].Trim().TrimEnd('.');
            return s.Length > 90 ? s.Substring(0, 87) + "..." : s;
        }
    }
}
