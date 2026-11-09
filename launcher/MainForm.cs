// The launcher window. Borderless and drawn by hand: drifting dust, three SOULs circling the title,
// pixel lettering for the title and buttons. All layout is in a 640x420 space scaled to the screen.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace DeltaruneOnline
{
    class MainForm : Form
    {
        const int W = 640, H = 420;
        enum Screen { Busy, Welcome, NoGame, Ready, Error, Starting }

        readonly Core core;
        float S = 1;
        volatile Screen screen = Screen.Busy;
        string note = "", error = "";
        Action retry;
        bool busyJob;

        // Look
        static readonly Color Yellow = Color.FromArgb(255, 214, 64);
        static readonly Color Dim = Color.FromArgb(160, 160, 175);
        static readonly Color Red = Color.FromArgb(255, 96, 96);
        static readonly Color[] Souls = { Color.FromArgb(232, 28, 40), Color.FromArgb(168, 64, 232), Color.FromArgb(40, 200, 96) };
        readonly Font fStatus = new Font("Segoe UI Semibold", 19f, GraphicsUnit.Pixel);
        readonly Font fDetail = new Font("Segoe UI", 14f, GraphicsUnit.Pixel);
        readonly Font fSmall = new Font("Segoe UI", 12.5f, GraphicsUnit.Pixel);

        // Animation
        float t;
        readonly Stopwatch clock = Stopwatch.StartNew();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 16 };
        struct Mote { public float X, Y, V, Size, Phase; }
        readonly Mote[] motes = new Mote[70];
        readonly Random rnd = new Random();

        // Clickable things, rebuilt every frame
        class Hit { public RectangleF R; public string Id; public Action Do; }
        readonly List<Hit> hits = new List<Hit>();
        string hover;
        Action mainAction;

        public MainForm(Core core, bool afterUpdate, bool fromNewerDownload)
        {
            this.core = core;
            Text = "DELTARUNE Online";
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.Black;
            KeyPreview = true;
            try { Icon = Icon.ExtractAssociatedIcon(Core.RunningExe); } catch { }
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
            using (var g = CreateGraphics()) S = g.DpiX / 96f;
            ClientSize = new Size((int)(W * S), (int)(H * S));
            for (int i = 0; i < motes.Length; i++) { motes[i] = NewMote(); motes[i].Y = (float)rnd.NextDouble() * H; }
            timer.Tick += (s, e) => { Animate(); Invalidate(); };
            timer.Start();

            if (!Core.IsGame(core.GameDir)) { var found = Core.FindGame(); if (found != "") core.GameDir = found; }
            if (fromNewerDownload)
                Run(() => { core.InstallFolder(Core.LocalPackage()); return Flow.Update(core, false, out var r) ; }, true);
            else if (!core.IsInstalled) screen = Core.IsGame(core.GameDir) ? Screen.Welcome : Screen.NoGame;
            else if (!Core.IsGame(core.GameDir)) screen = Screen.NoGame;
            else StartUpdate(!afterUpdate);
        }

        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ClassStyle |= 0x20000; cp.Style |= 0x20000; return cp; }   // drop shadow; minimize from the taskbar
        }

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            int round = 2;   // Windows 11 rounded corners
            try { DwmSetWindowAttribute(Handle, 33, ref round, 4); } catch { }
        }

        // ---------- jobs ----------

        void StartUpdate(bool online)
        {
            Run(() =>
            {
                var n = Flow.Update(core, online, out bool restart);
                if (restart)
                {
                    restarting = true;
                    Process.Start(core.InstalledExe, "--after-update");
                    BeginInvoke((Action)Close);
                }
                return n;
            }, online);
        }

        void Run(Func<string> job, bool online)
        {
            if (busyJob) return;
            busyJob = true;
            retry = () => Run(job, online);
            screen = Screen.Busy;
            core.Report("Getting ready...", "", -1);
            var th = new Thread(() =>
            {
                try
                {
                    var n = job();
                    note = n;
                    screen = Screen.Ready;
                }
                catch (Exception e)
                {
                    core.Log("error: " + e);
                    error = e.Message;
                    screen = Screen.Error;
                }
                busyJob = false;
            }) { IsBackground = true };
            th.Start();
        }

        void Install() => Run(() => Flow.Install(core), true);

        void FindGame()
        {
            using (var d = new OpenFileDialog
            {
                Title = "Find DELTARUNE.exe (in your Steam DELTARUNE folder)",
                Filter = "DELTARUNE|DELTARUNE.exe|Programs|*.exe",
                CheckFileExists = true,
            })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                var dir = Path.GetDirectoryName(d.FileName);
                if (!Core.IsGame(dir))
                {
                    MessageBox.Show(this, "That folder doesn't look like DELTARUNE: it needs DELTARUNE.exe and a chapter1_windows folder.", "DELTARUNE Online");
                    return;
                }
                core.GameDir = dir;
                if (core.IsInstalled) StartUpdate(false); else screen = Screen.Welcome;
            }
        }

        void Play()
        {
            if (core.GameRunning()) { note = "The game is already running."; return; }
            try { core.StartGame(); }
            catch (Exception e) { error = "Couldn't start the game: " + e.Message; screen = Screen.Error; return; }
            screen = Screen.Starting;
            var close = new System.Windows.Forms.Timer { Interval = 1800 };
            close.Tick += (s, e) => { close.Stop(); Close(); };
            close.Start();
        }

        void Repatch()
        {
            Run(() => { core.ForgetPatch(); core.PatchGame(); return $"Patched again. Mod version {core.AppVersionName}."; }, false);
        }

        void Uninstall()
        {
            var r = MessageBox.Show(this,
                "Remove DELTARUNE Online from this PC?\n\nThis deletes the patched game copy and the launcher. Your Steam DELTARUNE and normal saves were never changed.\n\n" +
                "The mod's own saves stay in %LOCALAPPDATA%\\DELTARUNE_ONLINE in case you come back.",
                "Uninstall DELTARUNE Online", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r != DialogResult.Yes) return;
            try { core.Uninstall(); }
            catch (Exception e) { MessageBox.Show(this, "Couldn't remove everything: " + e.Message, "DELTARUNE Online"); }
            Close();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (busyJob && e.CloseReason == CloseReason.UserClosing && screen == Screen.Busy && !restarting)
            {
                var r = MessageBox.Show(this, "It's still working. Stop now? It will pick up where it left off next time.", "DELTARUNE Online", MessageBoxButtons.YesNo);
                if (r != DialogResult.Yes) { e.Cancel = true; return; }
            }
            base.OnFormClosing(e);
        }
        volatile bool restarting;

        // ---------- input ----------

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            var h = HitAt(e.Location);
            hover = h?.Id;
            Cursor = h != null ? Cursors.Hand : Cursors.Default;
        }

        protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = null; }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;
            var h = HitAt(e.Location);
            if (h != null) { h.Do(); return; }
            ReleaseCapture();   // drag the window from anywhere else
            SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);
            if ((e.KeyCode == Keys.Enter || e.KeyCode == Keys.Z) && mainAction != null) mainAction();
            if (e.KeyCode == Keys.Escape) Close();
        }

        Hit HitAt(Point p)
        {
            var q = new PointF(p.X / S, p.Y / S);
            for (int i = hits.Count - 1; i >= 0; i--) if (hits[i].R.Contains(q)) return hits[i];
            return null;
        }

        // ---------- drawing ----------

        Mote NewMote() => new Mote
        {
            X = (float)rnd.NextDouble() * W,
            Y = H + (float)rnd.NextDouble() * 20,
            V = 6 + (float)rnd.NextDouble() * 18,
            Size = rnd.Next(4) == 0 ? 3 : 2,
            Phase = (float)rnd.NextDouble() * 6.28f,
        };

        void Animate()
        {
            float now = (float)clock.Elapsed.TotalSeconds, dt = Math.Min(0.1f, now - t);
            t = now;
            for (int i = 0; i < motes.Length; i++)
            {
                motes[i].Y -= motes[i].V * dt;
                motes[i].X += (float)Math.Sin(t * 0.7 + motes[i].Phase) * 4 * dt;
                if (motes[i].Y < -5) motes[i] = NewMote();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.ScaleTransform(S, S);
            Draw(g);
        }

        void Draw(Graphics g)
        {
            hits.Clear();
            mainAction = null;
            g.SmoothingMode = SmoothingMode.None;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            using (var bg = new LinearGradientBrush(new Rectangle(0, 0, W, H), Color.Black, Color.FromArgb(22, 10, 38), 90f))
                g.FillRectangle(bg, 0, 0, W, H);
            foreach (var m in motes)
            {
                int a = (int)(70 + 60 * Math.Sin(t * 2 + m.Phase));
                using (var b = new SolidBrush(Color.FromArgb(a, 200, 190, 255)))
                    g.FillRectangle(b, (float)Math.Round(m.X), (float)Math.Round(m.Y), m.Size, m.Size);
            }
            using (var p = new Pen(Color.FromArgb(70, 70, 90))) g.DrawRectangle(p, 0, 0, W - 1, H - 1);

            // Title, with the three SOULs circling it: the ones behind first.
            const float cx = W / 2f, cy = 84;
            var souls = new List<(float depth, float x, float y, Color c)>();
            for (int i = 0; i < 3; i++)
            {
                double a = t * 0.55 + i * Math.PI * 2 / 3;
                souls.Add(((float)Math.Sin(a), cx + (float)Math.Cos(a) * 250, cy + (float)Math.Sin(a) * 30 - 4, Souls[i]));
            }
            souls.Sort((a, b) => a.depth.CompareTo(b.depth));
            foreach (var s in souls) if (s.depth < 0) DrawSoul(g, s.x, s.y, s.depth, s.c);
            PixelFont.Draw(g, "DELTARUNE", cx, 48, 7, 7, Color.White, true);
            PixelFont.Draw(g, "ONLINE", cx, 114, 3, 9, Yellow, true);
            foreach (var s in souls) if (s.depth >= 0) DrawSoul(g, s.x, s.y, s.depth, s.c);

            // Window buttons
            WindowButton(g, "min", W - 64, () => WindowState = FormWindowState.Minimized, "-");
            WindowButton(g, "close", W - 34, Close, "X");

            switch (screen)
            {
                case Screen.Busy:
                    Status(g, core.Status, Color.White);
                    Detail(g, core.Detail);
                    Bar(g, core.Progress);
                    break;
                case Screen.Welcome:
                    Status(g, "Play DELTARUNE online with your friends.", Color.White);
                    Detail(g, "Uses your own DELTARUNE from Steam, found here:\n" + core.GameDir);
                    Link(g, "change", "Not this one?", W / 2f, 240, FindGame, true);
                    MainButton(g, "INSTALL", Install);
                    Footer(g, "About 1 GB. Your Steam copy and saves are never changed.");
                    break;
                case Screen.NoGame:
                    Status(g, "Couldn't find DELTARUNE.", Color.White);
                    Detail(g, "You need DELTARUNE on Steam. If it's installed somewhere unusual, point to its DELTARUNE.exe.");
                    MainButton(g, "FIND GAME", FindGame);
                    Footer(g, "");
                    break;
                case Screen.Ready:
                    Status(g, "Ready to play!", Color.White);
                    var d = note;
                    if (core.FailedChapters > 0) d += $" {core.FailedChapters} chapter(s) couldn't be patched and play without multiplayer.";
                    Detail(g, d + "\nIn game, press F9 for the multiplayer menu.");
                    MainButton(g, "PLAY", Play);
                    Footer(g, $"Mod version {core.AppVersionName}");
                    break;
                case Screen.Error:
                    Status(g, "Something went wrong.", Red);
                    Detail(g, error);
                    MainButton(g, "TRY AGAIN", () => retry?.Invoke());
                    if (core.CanPlay) Link(g, "playanyway", "Play the version you have", W / 2f, 352, Play, true);
                    Footer(g, core.IsInstalled ? $"Mod version {core.AppVersionName}" : "");
                    break;
                case Screen.Starting:
                    Status(g, "Have fun!", Color.White);
                    Detail(g, "Starting DELTARUNE Online...");
                    break;
            }
        }

        void DrawSoul(Graphics g, float x, float y, float depth, Color c)
        {
            int px = depth >= 0 ? 4 : 3;
            int alpha = (int)(150 + 105 * (depth + 1) / 2);
            PixelFont.Heart(g, x - 3.5f * px, y - 3 * px, px, Color.FromArgb(alpha, c));
        }

        void WindowButton(Graphics g, string id, float x, Action act, string glyph)
        {
            var r = new RectangleF(x, 8, 26, 22);
            hits.Add(new Hit { R = r, Id = id, Do = act });
            PixelFont.Draw(g, glyph, x + 13, 12, 2, 2, hover == id ? Yellow : Dim, true);
        }

        void Status(Graphics g, string text, Color c)
        {
            using (var b = new SolidBrush(c))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center })
                g.DrawString(text ?? "", fStatus, b, new RectangleF(20, 160, W - 40, 30), sf);
        }

        void Detail(Graphics g, string text)
        {
            using (var b = new SolidBrush(Dim))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter })
                g.DrawString(text ?? "", fDetail, b, new RectangleF(50, 194, W - 100, 62), sf);
        }

        void Bar(Graphics g, double p)
        {
            var r = new RectangleF(140, 262, 360, 14);
            using (var pen = new Pen(Color.White, 2)) g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
            float inner = r.Width - 6;
            if (p >= 0)
                g.FillRectangle(Brushes.White, r.X + 3, r.Y + 3, inner * (float)Math.Min(1, p), r.Height - 6);
            else
            {
                float w = 70, x = (float)((t * 160) % (inner + w)) - w;
                float x0 = Math.Max(0, x), x1 = Math.Min(inner, x + w);
                if (x1 > x0) g.FillRectangle(Brushes.White, r.X + 3 + x0, r.Y + 3, x1 - x0, r.Height - 6);
            }
        }

        void MainButton(Graphics g, string label, Action act)
        {
            var r = new RectangleF(W / 2f - 110, 280, 220, 54);
            bool on = hover == "main";
            hits.Add(new Hit { R = r, Id = "main", Do = act });
            mainAction = act;
            var c = on ? Yellow : Color.White;
            using (var bg = new SolidBrush(Color.FromArgb(on ? 40 : 0, 255, 214, 64))) g.FillRectangle(bg, r);
            using (var pen = new Pen(c, 2)) g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
            float tw = PixelFont.Width(label, 3, 3);
            PixelFont.Draw(g, label, W / 2f + (on ? 10 : 0), r.Y + 17, 3, 3, c, true);
            if (on) PixelFont.Heart(g, W / 2f - tw / 2 - 16, r.Y + 19, 2.5f, Souls[0]);
        }

        void Link(Graphics g, string id, string text, float x, float y, Action act, bool center)
        {
            var size = g.MeasureString(text, fSmall);
            var r = new RectangleF(center ? x - size.Width / 2 : x, y, size.Width, size.Height);
            hits.Add(new Hit { R = r, Id = id, Do = act });
            bool on = hover == id;
            using (var f = new Font(fSmall, on ? FontStyle.Underline : FontStyle.Regular))
            using (var b = new SolidBrush(on ? Color.White : Dim))
                g.DrawString(text, f, b, r.X, r.Y);
        }

        void Footer(Graphics g, string left)
        {
            using (var b = new SolidBrush(Color.FromArgb(120, 120, 135))) g.DrawString(left, fSmall, b, 16, H - 30);
            if (screen != Screen.Ready && screen != Screen.Error) return;
            if (!core.IsInstalled) return;
            float x = W - 16;
            foreach (var (id, text, act) in new (string, string, Action)[] {
                ("uninstall", "Uninstall", Uninstall),
                ("repatch", "Re-patch", Repatch),
                ("folder", "Open folder", () => Process.Start("explorer.exe", "\"" + core.Root + "\"")),
                ("check", "Check for updates", () => StartUpdate(true)),
                ("discord", "Discord", () => { try { Process.Start(Core.DiscordUrl); } catch { } }) })
            {
                x -= g.MeasureString(text, fSmall).Width + 8;
                Link(g, id, text, x, H - 30, act, false);
            }
        }

        // ---------- test hook: every screen as a PNG ----------

        public static void RenderScreens(string dir)
        {
            Directory.CreateDirectory(dir);
            var core = new Core();
            var f = new MainForm(core, false, false) { };
            f.timer.Stop();
            f.t = 1.3f;
            void Shot(string name, Screen s, Action setup = null)
            {
                f.screen = s;
                setup?.Invoke();
                foreach (var hv in new[] { (string)null, "main" })
                {
                    f.hover = hv;
                    using (var bmp = new Bitmap(W * 2, H * 2))
                    using (var g = Graphics.FromImage(bmp))
                    {
                        g.ScaleTransform(2, 2);
                        f.Draw(g);
                        bmp.Save(Path.Combine(dir, name + (hv == null ? "" : "_hover") + ".png"), ImageFormat.Png);
                    }
                }
            }
            Shot("welcome", Screen.Welcome);
            Shot("nogame", Screen.NoGame);
            Shot("busy_copy", Screen.Busy, () => core.Report("Copying the game...", "412 of 1034 MB  (your Steam copy is left alone)", 0.4));
            Shot("busy_check", Screen.Busy, () => core.Report("Checking for updates...", "", -1));
            Shot("ready", Screen.Ready, () => f.note = "Updated to version 1.0.");
            Shot("error", Screen.Error, () => f.error = "Couldn't download the mod: The remote name could not be resolved: 'github.com'. Check your internet connection.");
            Shot("starting", Screen.Starting);
        }
    }
}
