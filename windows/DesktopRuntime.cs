using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Dotfiles.Desktop {
    public sealed class MemorySnapshot {
        public ulong AvailableMBytes, CommittedBytes, CommitLimit;
    }
    public static class Performance {
        [StructLayout(LayoutKind.Sequential)] struct PerformanceInfo {
            public uint Size;
            public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable,
                SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
            public uint HandleCount, ProcessCount, ThreadCount;
        }
        [DllImport("psapi.dll", SetLastError = true)]
        static extern bool GetPerformanceInfo(out PerformanceInfo info, uint size);
        public static MemorySnapshot Memory() {
            PerformanceInfo info;
            if (!GetPerformanceInfo(out info, (uint)Marshal.SizeOf(typeof(PerformanceInfo))))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            ulong page = info.PageSize.ToUInt64();
            return new MemorySnapshot {
                AvailableMBytes = info.PhysicalAvailable.ToUInt64() * page / 1048576,
                CommittedBytes = info.CommitTotal.ToUInt64() * page,
                CommitLimit = info.CommitLimit.ToUInt64() * page
            };
        }
    }
    public sealed class ProbeResult {
        public string QueryStatus, QueryError;
        public double ConnectionMilliseconds, QueryMilliseconds;
        public int QueryExitCode;
    }
    public sealed class MonitorProbe : IDisposable {
        readonly Uri address;
        ClientWebSocket socket;
        readonly object gate = new object();
        Task<ProbeResult> pending;
        Stopwatch pendingWatch;
        int pendingTimeout, pendingConnected;
        double pendingConnectionMilliseconds, pendingCompletedMilliseconds;
        bool delivered, disposed;
        public MonitorProbe() : this("ws://127.0.0.1:6123") { }
        public MonitorProbe(string endpoint) { address = new Uri(endpoint); }
        public bool BeginQuery(int timeoutMilliseconds) {
            if (disposed) throw new ObjectDisposedException("MonitorProbe");
            if (pending != null && !pending.IsCompleted) return false;
            pendingTimeout = Math.Max(1, timeoutMilliseconds);
            pendingWatch = Stopwatch.StartNew(); delivered = false;
            pendingConnected = 0; pendingConnectionMilliseconds = 0;
            int budget = pendingTimeout;
            pending = Task.Run(() => {
                try { return QueryCore(budget); }
                finally { pendingCompletedMilliseconds = pendingWatch.Elapsed.TotalMilliseconds; }
            });
            return true;
        }
        public ProbeResult PollQuery() {
            if (pending == null || delivered) return null;
            bool completed = pending.IsCompleted;
            // Judge the worker's completion time, not the time this loop next polls.
            // A late success must not evade the deadline; an on-time result remains
            // valid even if dispatch/system load delayed the caller's next poll.
            if (completed && pendingCompletedMilliseconds <= pendingTimeout) { delivered = true; return pending.GetAwaiter().GetResult(); }
            if (!completed && pendingWatch.Elapsed.TotalMilliseconds < pendingTimeout) return null;
            double elapsed = completed ? pendingCompletedMilliseconds : pendingWatch.Elapsed.TotalMilliseconds;
            bool connected = Volatile.Read(ref pendingConnected) != 0;
            double connection = connected ? pendingConnectionMilliseconds : elapsed;
            delivered = true; Abort();
            return new ProbeResult {
                QueryStatus = "timeout", QueryExitCode = 1, QueryError = "Monitor probe deadline exceeded.",
                ConnectionMilliseconds = connection, QueryMilliseconds = connected ? Math.Max(0, elapsed - connection) : 0
            };
        }
        public ProbeResult Query(int timeoutMilliseconds) {
            if (!BeginQuery(timeoutMilliseconds)) return new ProbeResult { QueryStatus = "timeout", QueryExitCode = 1, QueryError = "Previous monitor probe is still stopping." };
            pending.Wait(Math.Max(1, timeoutMilliseconds));
            return PollQuery();
        }
        ProbeResult QueryCore(int timeoutMilliseconds) {
            var result = new ProbeResult { QueryStatus = "error", QueryExitCode = 1 };
            var timer = Stopwatch.StartNew();
            bool connected = false;
            using (var timeout = new CancellationTokenSource(Math.Max(1, timeoutMilliseconds))) {
                try {
                    ClientWebSocket connection;
                    lock (gate) {
                        if (disposed) throw new ObjectDisposedException("MonitorProbe");
                        if (socket == null) { socket = new ClientWebSocket(); socket.Options.Proxy = null; }
                        connection = socket;
                    }
                    if (connection.State == WebSocketState.None) connection.ConnectAsync(address, timeout.Token).GetAwaiter().GetResult();
                    result.ConnectionMilliseconds = timer.Elapsed.TotalMilliseconds;
                    pendingConnectionMilliseconds = pendingWatch.Elapsed.TotalMilliseconds;
                    Volatile.Write(ref pendingConnected, 1);
                    connected = true;
                    timer.Restart();
                    byte[] command = Encoding.UTF8.GetBytes("query monitors");
                    connection.SendAsync(new ArraySegment<byte>(command), WebSocketMessageType.Text, true, timeout.Token).GetAwaiter().GetResult();
                    using (var output = new MemoryStream()) {
                        var buffer = new byte[8192];
                        WebSocketReceiveResult message;
                        do {
                            message = connection.ReceiveAsync(new ArraySegment<byte>(buffer), timeout.Token).GetAwaiter().GetResult();
                            if (message.MessageType == WebSocketMessageType.Close) throw new IOException("GlazeWM disconnected.");
                            output.Write(buffer, 0, message.Count);
                            if (output.Length > 8 * 1024 * 1024) throw new IOException("Response exceeded 8 MiB.");
                        } while (!message.EndOfMessage);
                        var data = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.DeserializeObject(Encoding.UTF8.GetString(output.ToArray())) as Dictionary<string, object>;
                        object success;
                        bool ok = data != null && data.TryGetValue("success", out success) && success is bool && (bool)success;
                        result.QueryStatus = ok ? "ok" : "failed";
                        result.QueryExitCode = ok ? 0 : 1;
                    }
                } catch (Exception ex) {
                    result.QueryStatus = timeout.IsCancellationRequested ? "timeout" : "error";
                    result.QueryError = ex.Message;
                    Abort();
                } finally {
                    if (connected) result.QueryMilliseconds = timer.Elapsed.TotalMilliseconds;
                    else result.ConnectionMilliseconds = timer.Elapsed.TotalMilliseconds;
                }
            }
            return result;
        }
        void Abort() { lock (gate) { if (socket != null) { socket.Abort(); socket.Dispose(); socket = null; } } }
        public void Dispose() { lock (gate) { disposed = true; Abort(); } }
    }

    public sealed class WindowSnapshot {
        public long Handle, RootHandle;
        public int ProcessId, SessionId, Left, Top, Right, Bottom;
        public string ProcessName, ClassName;
        public bool Visible, Topmost, Cloaked;
    }
    public static class StartupWindows {
        delegate bool EnumProc(IntPtr window, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int count);
        [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr window, int index);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out NativeRect rect);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
        public static WindowSnapshot DescribeWindow(long handle) {
            if (handle == 0) { Point point; GetCursorPos(out point); handle = WindowFromPoint(point).ToInt64(); }
            var window = new IntPtr(handle);
            if (!IsWindow(window)) throw new ArgumentException("Window does not exist.");
            window = GetAncestor(window, 2);
            uint pid; GetWindowThreadProcessId(window, out pid);
            var name = new StringBuilder(256); GetClassName(window, name, name.Capacity);
            NativeRect rect; GetWindowRect(window, out rect);
            int cloaked; DwmGetWindowAttribute(window, 14, out cloaked, sizeof(int));
            using (var process = Process.GetProcessById((int)pid)) return new WindowSnapshot {
                Handle = handle, RootHandle = window.ToInt64(), ProcessId = (int)pid, SessionId = process.SessionId,
                ProcessName = process.ProcessName, ClassName = name.ToString(), Visible = IsWindowVisible(window),
                Topmost = (GetWindowLong(window, -20) & 8) != 0, Cloaked = cloaked != 0,
                Left = rect.Left, Top = rect.Top, Right = rect.Right, Bottom = rect.Bottom
            };
        }
        public static bool EverythingResponds(int process) {
            bool ready = false;
            EnumWindows((window, unused) => {
                uint owner; GetWindowThreadProcessId(window, out owner);
                if (owner != process) return true;
                var name = new StringBuilder(256); GetClassName(window, name, name.Capacity);
                if (name.ToString() != "EVERYTHING_TASKBAR_NOTIFICATION") return true;
                IntPtr result;
                ready = SendMessageTimeout(window, 0, IntPtr.Zero, IntPtr.Zero, 3, 200, out result) != IntPtr.Zero;
                return !ready;
            }, IntPtr.Zero);
            return ready;
        }
    }

    // COM vtable order follows shobjidl_core.h, including the unused slideshow methods.
    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopWallpaper {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitor);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint index);
        uint GetMonitorDevicePathCount();
        void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitor, out NativeRect rect);
        void SetBackgroundColor(uint color);
        uint GetBackgroundColor();
        void SetPosition(int position);
        int GetPosition();
        void SetSlideshow(IntPtr items);
        IntPtr GetSlideshow();
        void SetSlideshowOptions(uint options, uint tick);
        void GetSlideshowOptions(out uint options, out uint tick);
        void AdvanceSlideshow([MarshalAs(UnmanagedType.LPWStr)] string monitor, int direction);
        uint GetStatus();
        void Enable([MarshalAs(UnmanagedType.Bool)] bool enable);
    }
    [StructLayout(LayoutKind.Sequential)] struct NativeRect { public int Left, Top, Right, Bottom; }
    public sealed class WallpaperMonitor { public string Monitor, Path; }
    public sealed class WallpaperState {
        public int Position;
        public uint BackgroundColor;
        public bool SlideshowActive;
        public List<WallpaperMonitor> Monitors = new List<WallpaperMonitor>();
    }
    public static class Wallpaper {
        static IDesktopWallpaper Open() { return (IDesktopWallpaper)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD"))); }
        public static WallpaperState Capture() {
            var api = Open();
            try {
                var result = new WallpaperState { Position = api.GetPosition(), BackgroundColor = api.GetBackgroundColor(), SlideshowActive = (api.GetStatus() & 2) != 0 };
                for (uint i = 0; i < api.GetMonitorDevicePathCount(); i++) {
                    string monitor = api.GetMonitorDevicePathAt(i);
                    result.Monitors.Add(new WallpaperMonitor { Monitor = monitor, Path = api.GetWallpaper(monitor) });
                }
                return result;
            } finally { Marshal.FinalReleaseComObject(api); }
        }
        public static bool Matches(string path) {
            var state = Capture();
            return !state.SlideshowActive && state.Position == 4 && state.Monitors.Count > 0 && state.Monitors.TrueForAll(m => String.Equals(m.Path, path, StringComparison.OrdinalIgnoreCase));
        }
        public static void Apply(string path) {
            if (!File.Exists(path)) throw new FileNotFoundException("Wallpaper image not found.", path);
            // Do not replace a slideshow whose shell item array cannot be faithfully backed up.
            if (Capture().SlideshowActive) throw new InvalidOperationException("An active slideshow is preserved; use the image overlay.");
            var api = Open();
            try { api.SetWallpaper(null, Path.GetFullPath(path)); api.SetPosition(4); }
            finally { Marshal.FinalReleaseComObject(api); }
            if (!Matches(Path.GetFullPath(path))) throw new IOException("Windows did not retain the requested wallpaper.");
        }
        public static void Restore(string json) {
            var state = new JavaScriptSerializer().Deserialize<WallpaperState>(json);
            if (state.SlideshowActive) return; // Apply never changes active slideshows.
            var api = Open();
            try {
                api.SetBackgroundColor(state.BackgroundColor); api.SetPosition(state.Position);
                foreach (var monitor in state.Monitors) api.SetWallpaper(monitor.Monitor, monitor.Path);
            } finally { Marshal.FinalReleaseComObject(api); }
        }
    }

    public sealed class WallpaperWindow : Form {
        IntPtr desktopHost;
        IntPtr desktopAfter = new IntPtr(1);
        readonly Image image;
        public WallpaperWindow(Image picture, Rectangle bounds) {
            image = picture; Text = "Dotfiles wallpaper"; Name = "DotfilesWallpaper";
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.None; Bounds = bounds;
            DoubleBuffered = true; BackColor = Color.FromArgb(34, 26, 15);
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80 | 0x80000 | 0x20; return p; }
        }
        protected override void OnShown(EventArgs e) {
            base.OnShown(e); Hide();
            if (!AttachDesktop()) return;
            SetLayeredWindowAttributes(Handle, 0, 255, 2);
            Show();
            SetWindowPos(Handle, desktopAfter, 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
        }
        bool AttachDesktop() {
            IntPtr host = IntPtr.Zero;
            var progman = FindWindow("Progman", null);
            if (progman == IntPtr.Zero) return false;
            IntPtr result;
            SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, 2, 1000, out result);
            EnumWindows((h, l) => {
                if (FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) {
                    host = FindWindowEx(IntPtr.Zero, h, "WorkerW", null);
                    if (host == IntPtr.Zero) host = h;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            if (host == IntPtr.Zero) return false;
            var origin = new Point(Left, Top);
            MapWindowPoints(IntPtr.Zero, host, ref origin, 1);
            SetWindowLong(Handle, -16, (GetWindowLong(Handle, -16) & ~unchecked((int)0x80000000)) | 0x40000000);
            if (SetParent(Handle, host) == IntPtr.Zero && GetParent(Handle) != host) return false;
            desktopHost = host;
            var icons = FindWindowEx(host, IntPtr.Zero, "SHELLDLL_DefView", null);
            desktopAfter = icons == IntPtr.Zero ? new IntPtr(1) : icons;
            Location = origin;
            return true;
        }
        public void CheckHost() {
            if (desktopHost != IntPtr.Zero && IsWindow(desktopHost) && GetParent(Handle) == desktopHost) return;
            Hide();
            if (AttachDesktop()) {
                Show();
                SetWindowPos(Handle, desktopAfter, 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
            }
        }
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc c, IntPtr l);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
        [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
        [DllImport("user32.dll")] static extern IntPtr SetParent(IntPtr h, IntPtr p);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] static extern int MapWindowPoints(IntPtr a, IntPtr b, ref Point p, uint n);
        [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
        public static RectangleF Cover(Size image, Size target) {
            float scale = Math.Max((float)target.Width / image.Width, (float)target.Height / image.Height);
            return new RectangleF((target.Width - image.Width * scale) / 2, (target.Height - image.Height * scale) / 2, image.Width * scale, image.Height * scale);
        }
        protected override void OnPaint(PaintEventArgs e) { e.Graphics.DrawImage(image, Cover(image.Size, ClientSize)); }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x84) { m.Result = new IntPtr(-1); return; }
            if (m.Msg == 0x21) { m.Result = new IntPtr(3); return; }
            base.WndProc(ref m);
        }
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr window, uint key, byte alpha, uint flags);
    }
    public sealed class WallpaperOverlay : ApplicationContext {
        readonly List<WallpaperWindow> windows = new List<WallpaperWindow>();
        readonly Image image;
        readonly Control dispatcher = new Control();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 500 };
        WallpaperOverlay(string path, EventWaitHandle stop, EventWaitHandle ready) {
            using (var original = Image.FromFile(path)) image = new Bitmap(original);
            IntPtr unused = dispatcher.Handle;
            Rebuild();
            SystemEvents.DisplaySettingsChanged += DisplayChanged;
            SystemEvents.PowerModeChanged += PowerChanged;
            timer.Tick += delegate { if (stop.WaitOne(0)) ExitThread(); else foreach (var window in windows) window.CheckHost(); };
            timer.Start(); ready.Set();
        }
        void Rebuild() {
            foreach (var window in windows) { window.Close(); window.Dispose(); }
            windows.Clear();
            foreach (var screen in Screen.AllScreens) {
                var window = new WallpaperWindow(image, screen.Bounds); windows.Add(window); window.Show();
            }
        }
        void QueueRebuild() { if (!dispatcher.IsDisposed) dispatcher.BeginInvoke((Action)Rebuild); }
        void DisplayChanged(object sender, EventArgs args) { QueueRebuild(); }
        void PowerChanged(object sender, PowerModeChangedEventArgs args) { if (args.Mode == PowerModes.Resume) QueueRebuild(); }
        protected override void Dispose(bool disposing) {
            if (disposing) {
                SystemEvents.DisplaySettingsChanged -= DisplayChanged; SystemEvents.PowerModeChanged -= PowerChanged;
                timer.Dispose(); dispatcher.Dispose();
                foreach (var window in windows) window.Dispose();
                image.Dispose();
            }
            base.Dispose(disposing);
        }
        public static void Run(string path, EventWaitHandle stop, EventWaitHandle ready) {
            SetThreadDpiAwarenessContext(new IntPtr(-4));
            using (var overlay = new WallpaperOverlay(path, stop, ready)) Application.Run(overlay);
        }
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    }
}
