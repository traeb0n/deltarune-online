using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Threading;
using System.Windows.Forms;

namespace DeltaruneOnline
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // Test hooks: --render <folder> draws every screen to PNGs; --auto installs or updates without a window.
            if (args.Length >= 2 && args[0] == "--render") { MainForm.RenderScreens(args[1]); return 0; }
            if (args.Length >= 1 && args[0] == "--auto") return Auto();

            using (var mutex = new Mutex(true, "DeltaruneOnlineLauncher", out bool first))
            {
                if (!first) return 0;   // already open
                var core = new Core();
                core.CleanOldLauncher();
                // Started from a download while it's already installed: hand over to the installed launcher.
                var local = Core.LocalPackage();
                bool isInstalledExe = string.Equals(Path.GetFullPath(Core.RunningExe), Path.GetFullPath(core.InstalledExe), StringComparison.OrdinalIgnoreCase);
                if (!isInstalledExe && core.IsInstalled && File.Exists(core.InstalledExe)
                    && (local == null || Core.ReadVersion(local) <= core.AppVersion))
                {
                    mutex.ReleaseMutex();
                    Process.Start(core.InstalledExe);
                    return 0;
                }
                Application.Run(new MainForm(core, Array.IndexOf(args, "--after-update") >= 0, local != null && core.IsInstalled && !isInstalledExe));
            }
            return 0;
        }

        static int Auto()
        {
            var core = new Core();
            try
            {
                if (!Core.IsGame(core.GameDir)) core.GameDir = Core.FindGame();
                string note = core.IsInstalled ? Flow.Update(core, true, out _) : Flow.Install(core);
                core.Log("auto: " + note);
                return 0;
            }
            catch (Exception e)
            {
                core.Log("auto failed: " + e);
                return 1;
            }
        }
    }
}
