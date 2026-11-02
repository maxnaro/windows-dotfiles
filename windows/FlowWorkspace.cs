// Windows PowerShell 5.1 / .NET Framework. No downloaded runtime or build tools.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;

namespace Dotfiles.FlowWorkspace
{
    public sealed class ManagedWindow
    {
        public string Id, Workspace, Process;
        public long Handle;
    }

    public sealed class WorkspaceInfo
    {
        public string Id, Name;
        public bool IsDisplayed;
        public int X, Y, Width, Height;
        public bool Contains(int x, int y) { return x >= X && x < X + Width && y >= Y && y < Y + Height; }
    }

    // A snapshot is published once and is never modified by the bridge afterwards.
    public sealed class Snapshot
    {
        public string Workspace;
        public long FocusedHandle;
        public DateTime CapturedAt = DateTime.UtcNow;
        public readonly Dictionary<long, ManagedWindow> Windows = new Dictionary<long, ManagedWindow>();
        public readonly Dictionary<string, WorkspaceInfo> Workspaces = new Dictionary<string, WorkspaceInfo>();

        public string AtPoint(int x, int y)
        {
            foreach (var workspace in Workspaces.Values)
                if (workspace.IsDisplayed && workspace.Contains(x, y)) return workspace.Name;
            return null;
        }

        public static Snapshot Parse(string json)
        {
            var root = Ipc.Decode(json);
            Ipc.RequireSuccess(root);
            var data = (Dictionary<string, object>)root["data"];
            var result = new Snapshot();
            foreach (Dictionary<string, object> workspace in (object[])data["workspaces"])
            {
                string name = (string)workspace["name"];
                if ((bool)workspace["hasFocus"]) result.Workspace = name;
                result.Workspaces[name] = new WorkspaceInfo {
                    Name = name, Id = Text(workspace, "id"), IsDisplayed = Flag(workspace, "isDisplayed"),
                    X = Number(workspace, "x"), Y = Number(workspace, "y"),
                    Width = Number(workspace, "width"), Height = Number(workspace, "height")
                };
                result.ReadChildren((object[])workspace["children"], name);
            }
            return result;
        }

        static string Text(Dictionary<string, object> value, string key) { return value.ContainsKey(key) ? Convert.ToString(value[key]) : null; }
        static int Number(Dictionary<string, object> value, string key) { return value.ContainsKey(key) ? Convert.ToInt32(value[key]) : 0; }
        static bool Flag(Dictionary<string, object> value, string key) { return value.ContainsKey(key) && Convert.ToBoolean(value[key]); }

        void ReadChildren(object[] children, string workspace)
        {
            foreach (Dictionary<string, object> item in children)
            {
                if ((string)item["type"] == "window")
                {
                    var window = new ManagedWindow {
                        Id = (string)item["id"], Handle = Convert.ToInt64(item["handle"]),
                        Process = (string)item["processName"], Workspace = workspace
                    };
                    Windows[window.Handle] = window;
                    if ((bool)item["hasFocus"]) FocusedHandle = window.Handle;
                }
                else if (item.ContainsKey("children")) ReadChildren((object[])item["children"], workspace);
            }
        }
    }

    // Pure handoff decisions: existing restoration windows are never generic results.
    public sealed class Placement
    {
        public string Workspace;
        public long OriginalHandle, Candidate;
        public DateTime Deadline;
        public bool Committed, Hidden;
        public string ExpectedText = "";
        readonly HashSet<long> existing = new HashSet<long>();
        readonly Dictionary<long, string> existingProcesses = new Dictionary<long, string>();
        DateTime committedAt;
        bool newCandidate;
        public int IdentifiedWindowCount
        {
            get {
                int count = 0;
                foreach (string process in existingProcesses.Values)
                    if (MatchesProcess(ExpectedText, process)) count++;
                return count;
            }
        }

        public void Begin(Snapshot snapshot, long previousHandle)
        {
            Cancel();
            if (snapshot == null || String.IsNullOrEmpty(snapshot.Workspace)) return;
            Workspace = snapshot.Workspace;
            OriginalHandle = previousHandle;
            foreach (var window in snapshot.Windows.Values) {
                existing.Add(window.Handle);
                existingProcesses[window.Handle] = window.Process;
            }
            if (previousHandle != 0) existing.Add(previousHandle); // Empty origins may have the desktop HWND.
        }

        public void Commit(DateTime now, string expectedText)
        {
            if (Workspace == null || Committed) return;
            Committed = true;
            committedAt = now;
            Deadline = now.AddSeconds(10);
            ExpectedText = expectedText ?? "";
        }

        public void Dismiss(DateTime now)
        {
            if (Workspace == null || Hidden) return;
            Hidden = true;
            if (!Committed) Deadline = now.AddSeconds(1);
        }

        public void CancelRouting()
        {
            Committed = false;
            Candidate = 0;
            newCandidate = false;
            ExpectedText = "";
        }

        public void Foreground(long handle, DateTime now)
        {
            if (Workspace == null || handle == 0) return;
            bool isNew = !existing.Contains(handle);
            // Remember a new app that became foreground just before Flow hid, even
            // if Windows subsequently restores an older window over it.
            string candidateProcess;
            bool identified = existingProcesses.TryGetValue(Candidate, out candidateProcess) &&
                MatchesProcess(ExpectedText, candidateProcess);
            if (isNew || (!newCandidate && !identified)) { Candidate = handle; newCandidate = isNew; }
        }

        public ManagedWindow Resolve(Snapshot snapshot, long foreground, DateTime now)
        {
            if (!Committed || snapshot == null) return null;
            if (now >= Deadline) { Cancel(); return null; }
            ManagedWindow window;
            if (Candidate == 0 || !snapshot.Windows.TryGetValue(Candidate, out window)) return null;
            if (window.Process == "Flow.Launcher" || window.Process == "zebar") return null;
            if (existing.Contains(Candidate))
            {
                // Metadata is optional for new windows but mandatory for reused ones.
                if ((foreground != Candidate && !(Hidden && existing.Contains(foreground))) ||
                    now < committedAt.AddMilliseconds(300) ||
                    !MatchesProcess(ExpectedText, window.Process)) return null;
            }
            else if (foreground != Candidate && !existing.Contains(foreground)) return null;
            return window;
        }

        public bool IsExisting(long handle) { return existing.Contains(handle); }

        public bool NeedsRestore(Snapshot snapshot, DateTime now)
        {
            return Workspace != null && Hidden && now < Deadline &&
                snapshot != null && snapshot.Workspace != Workspace &&
                !(Committed && existingProcesses.ContainsKey(Candidate) && MatchesProcess(ExpectedText, existingProcesses[Candidate]));
        }

        public static bool MatchesProcess(string text, string process)
        {
            if (String.IsNullOrEmpty(text) || String.IsNullOrEmpty(process)) return false;
            string name = Path.GetFileNameWithoutExtension(process.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? process : process + ".exe");
            // UIA rows can also contain plugin names/help such as "Explorer".
            // Those labels are not executable identity. Require the executable
            // filename, not a substring of arbitrary result or help text.
            // WPF may concatenate Title and Subtitle in the row's accessible
            // name: "app.exeC:\Apps". A drive prefix is also a field boundary.
            string ending = @"(?=$|[\s""'\),\]]|[A-Za-z]:[\\/])";
            string pattern = @"(?:^|[\\/\s""'])" + Regex.Escape(name) + @"\.exe" + ending;
            if (Regex.IsMatch(text, pattern, RegexOptions.IgnoreCase)) return true;
            return name.Equals("WindowsTerminal", StringComparison.OrdinalIgnoreCase) &&
                Regex.IsMatch(text, @"(?:^|[\\/\s""'])wt\.exe" + ending, RegexOptions.IgnoreCase);
        }

        public void Cancel()
        {
            Workspace = null;
            OriginalHandle = Candidate = 0;
            Committed = Hidden = newCandidate = false;
            ExpectedText = "";
            existing.Clear();
            existingProcesses.Clear();
        }
    }

    // Replayable event reducer. It consumes the actual snapshot carried by each
    // event, not whichever global snapshot happens to exist when a queue drains.
    public sealed class SessionState
    {
        public Snapshot Current;
        public readonly Placement Placement = new Placement();
        public bool FlowVisible;
        public long FlowHandle;
        bool intent, originLocated;
        int centerX, centerY;
        DateTime shownAt;

        public void ObserveSnapshot(Snapshot snapshot)
        {
            Current = snapshot;
            if (Placement.Committed && snapshot.FocusedHandle != 0 && snapshot.FocusedHandle != FlowHandle)
                Placement.Foreground(snapshot.FocusedHandle, snapshot.CapturedAt);
            if (FlowVisible && !originLocated && !Placement.Committed && snapshot.CapturedAt >= shownAt)
            {
                string origin = snapshot.AtPoint(centerX, centerY);
                if (origin != null) { Placement.Workspace = origin; originLocated = true; }
            }
        }

        public void OpenIntent(Snapshot snapshot, long previous)
        {
            Placement.Begin(snapshot, previous);
            intent = true;
            originLocated = false;
        }

        public void FlowShown(long handle, int x, int y)
        {
            if (FlowVisible && FlowHandle == handle) return;
            if (!intent) Placement.Begin(Current, Current == null ? 0 : Current.FocusedHandle);
            FlowVisible = true;
            FlowHandle = handle;
            centerX = x; centerY = y;
            shownAt = DateTime.UtcNow;
            originLocated = false;
            // Prefer the workspace physically displaying Flow, including an empty
            // workspace whose hasFocus became false while an ignored overlay focused.
            string origin = Current == null ? null : Current.AtPoint(x, y);
            if (origin != null) Placement.Workspace = origin;
            intent = false;
        }

        public void FlowHidden(DateTime now) { FlowVisible = false; originLocated = true; Placement.Dismiss(now); }
        public void Commit(DateTime now, string text) { originLocated = true; Placement.Commit(now, text); }
        public void DismissOnly() { Placement.CancelRouting(); }
        public void Foreground(long handle, DateTime now) { Placement.Foreground(handle, now); }
        public void Cancel() { Placement.Cancel(); intent = false; originLocated = true; }
    }

    public static class Ipc
    {
        public static Dictionary<string, object> Decode(string json)
        {
            return new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }.DeserializeObject(json) as Dictionary<string, object>;
        }

        public static void RequireSuccess(Dictionary<string, object> json)
        {
            if (json == null || !json.ContainsKey("success") || !(bool)json["success"])
                throw new IOException("GlazeWM rejected command: " + (json != null && json.ContainsKey("error") ? json["error"] : "invalid response"));
        }

        public static ClientWebSocket Connect(CancellationToken token)
        {
            var socket = new ClientWebSocket();
            socket.Options.Proxy = null;
            try { socket.ConnectAsync(new Uri("ws://127.0.0.1:6123"), token).GetAwaiter().GetResult(); return socket; }
            catch { socket.Dispose(); throw; }
        }

        public static void Send(ClientWebSocket socket, string command, CancellationToken token)
        {
            socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(command)),
                WebSocketMessageType.Text, true, token).GetAwaiter().GetResult();
        }

        public static string Receive(ClientWebSocket socket, CancellationToken token)
        {
            var buffer = new byte[8192];
            using (var output = new MemoryStream())
            {
                WebSocketReceiveResult message;
                do {
                    message = socket.ReceiveAsync(new ArraySegment<byte>(buffer), token).GetAwaiter().GetResult();
                    if (message.MessageType == WebSocketMessageType.Close) throw new IOException("GlazeWM disconnected.");
                    output.Write(buffer, 0, message.Count);
                    if (output.Length > 8 * 1024 * 1024) throw new IOException("GlazeWM response exceeded 8 MiB.");
                } while (!message.EndOfMessage);
                return Encoding.UTF8.GetString(output.ToArray());
            }
        }

        public static string Request(string command)
        {
            using (var connection = new IpcSession(CancellationToken.None)) return connection.Request(command);
        }
    }

    public sealed class IpcSession : IDisposable
    {
        readonly CancellationToken lifetime;
        ClientWebSocket socket;
        public IpcSession(CancellationToken token) { lifetime = token; }
        public string Request(string command)
        {
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime))
            {
                timeout.CancelAfter(2000);
                try {
                    if (socket == null) socket = Ipc.Connect(timeout.Token);
                    Ipc.Send(socket, command, timeout.Token);
                    string response = Ipc.Receive(socket, timeout.Token);
                    Ipc.RequireSuccess(Ipc.Decode(response));
                    return response;
                } catch { Dispose(); throw; }
            }
        }
        public void Dispose() { if (socket != null) { socket.Abort(); socket.Dispose(); socket = null; } }
    }

    sealed class InputEvent
    {
        public string Kind, ExpectedText;
        public ManualResetEventSlim Acknowledged;
        public long Handle, Epoch;
        public int X, Y;
        public bool IsFlow;
        public Snapshot Snapshot;
        public DateTime Time = DateTime.UtcNow;
    }

    sealed class ResultRow
    {
        public string Text;
        public double Left, Top, Right, Bottom;
        public bool Selected;
    }

    sealed class SelectionCache
    {
        public long Handle;
        public long Revision;
        public DateTime Time = DateTime.UtcNow;
        public readonly List<ResultRow> Rows = new List<ResultRow>();
        public string Find(int x, int y, bool selected)
        {
            foreach (var row in Rows)
                if (selected ? row.Selected : x >= row.Left && x < row.Right && y >= row.Top && y < row.Bottom) return row.Text;
            return "";
        }
    }

    public sealed class Bridge : IDisposable
    {
        public const string Version = "4-native-handoff";
        readonly BlockingCollection<InputEvent> events = new BlockingCollection<InputEvent>();
        readonly CancellationTokenSource lifetime = new CancellationTokenSource();
        readonly SessionState state = new SessionState();
        readonly string logPath;
        readonly object logLock = new object();
        readonly Native.WinEventProc windowCallback;
        readonly Native.HookProc keyboardCallback, mouseCallback;
        readonly EventWaitHandle ready;
        readonly IpcSession commands;
        readonly List<IntPtr> windowHooks = new List<IntPtr>();
        IntPtr keyboardHook, mouseHook;
        Thread worker, tracker, automation, control;
        Snapshot publishedSnapshot;
        SelectionCache selection;
        long cancellationEpoch, sessionEpoch, automationHandle, resultRevision;
        int refreshQueued, subscriptionConnected;
        DateTime retryAt;

        Bridge(string log, EventWaitHandle readyEvent)
        {
            logPath = log; ready = readyEvent;
            commands = new IpcSession(lifetime.Token);
            windowCallback = WindowChanged;
            keyboardCallback = Keyboard;
            mouseCallback = Mouse;
        }

        public static void Run(EventWaitHandle stop, string log) { Run(stop, log, null); }
        public static void Run(EventWaitHandle stop, string log, EventWaitHandle ready)
        {
            using (var bridge = new Bridge(log, ready))
            {
                bridge.Start();
                using (var timer = new System.Windows.Forms.Timer { Interval = 100 })
                {
                    timer.Tick += delegate { if (stop.WaitOne(0)) Application.ExitThread(); };
                    timer.Start();
                    Application.Run();
                }
            }
        }

        void Start()
        {
            Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            // Flow 2.1 cloaks before its WPF hide. Foreground loss alone is not hide.
            foreach (uint type in new uint[] { 3, 0x8002, 0x8003, 0x8017, 0x8018 })
            {
                IntPtr hook = Native.SetWinEventHook(type, type, IntPtr.Zero, windowCallback, 0, 0, 0);
                if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                windowHooks.Add(hook);
            }
            IntPtr module = Native.GetModuleHandle(null);
            keyboardHook = Native.SetWindowsHookEx(13, keyboardCallback, module, 0);
            mouseHook = Native.SetWindowsHookEx(14, mouseCallback, module, 0);
            if (keyboardHook == IntPtr.Zero || mouseHook == IntPtr.Zero)
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not install Flow workspace hooks.");
            worker = new Thread(Work) { IsBackground = true, Name = "Flow workspace handoff" };
            worker.Start();
            tracker = new Thread(Track) { IsBackground = true, Name = "GlazeWM subscription" };
            tracker.Start();
            automation = new Thread(ReadSelections) { IsBackground = true, Name = "Optional Flow result metadata" };
            automation.SetApartmentState(ApartmentState.MTA);
            automation.Start();
            control = new Thread(Control) { IsBackground = true, Name = "Native Flow handoff" };
            control.Start();
            Log("started version=" + Version);
        }

        void Control()
        {
            string name = "DotfilesFlowWorkspaceControl-" + Process.GetCurrentProcess().SessionId;
            var security = new PipeSecurity();
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.FullControl, AccessControlType.Allow));
            while (!lifetime.IsCancellationRequested) {
                try {
                    using (var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous, 1024, 1024, security)) {
                        var connected = pipe.BeginWaitForConnection(null, null);
                        while (!connected.AsyncWaitHandle.WaitOne(100))
                            if (lifetime.IsCancellationRequested) return;
                        pipe.EndWaitForConnection(connected);
                        var reader = new StreamReader(pipe);
                        var line = reader.ReadLineAsync();
                        if (!line.Wait(2000) || line.Result != "release") continue;
                        var acknowledged = new ManualResetEventSlim(false);
                        Enqueue(new InputEvent { Kind = "native-handoff", Acknowledged = acknowledged, Epoch = Interlocked.Read(ref cancellationEpoch) });
                        if (!acknowledged.Wait(2500)) continue;
                        byte[] response = Encoding.ASCII.GetBytes("OK\n");
                        pipe.Write(response, 0, response.Length);
                        pipe.Flush();
                    }
                } catch (Exception ex) {
                    if (!lifetime.IsCancellationRequested) Log("native handoff unavailable: " + ex.GetType().Name);
                    if (lifetime.Token.WaitHandle.WaitOne(250)) return;
                }
            }
        }

        void Enqueue(InputEvent input) { if (!lifetime.IsCancellationRequested) events.TryAdd(input); }
        void RequestRefresh() { if (Interlocked.Exchange(ref refreshQueued, 1) == 0) Enqueue(new InputEvent { Kind = "refresh" }); }
        void CancelFromInput()
        {
            Interlocked.Increment(ref cancellationEpoch);
            Enqueue(new InputEvent { Kind = "cancel" });
        }

        void WindowChanged(IntPtr hook, uint type, IntPtr window, int objectId, int childId, uint thread, uint time)
        {
            if (objectId != 0 || childId != 0 || window == IntPtr.Zero) return;
            bool flow = Native.IsFlow(window);
            if (type != 3 && !flow) return;
            if (flow && type != 3 && type != 0x8017 && type != 0x8003 &&
                Native.GetForegroundWindow() != window) return;
            Native.Rect rect;
            Native.GetWindowRect(window, out rect);
            Enqueue(new InputEvent {
                Kind = type == 0x8017 || type == 0x8003 ? "hidden" : "foreground",
                Handle = window.ToInt64(), IsFlow = flow,
                X = (rect.Left + rect.Right) / 2, Y = (rect.Top + rect.Bottom) / 2,
                Snapshot = Interlocked.CompareExchange(ref publishedSnapshot, null, null)
            });
        }

        string CachedSelection(long handle, int x, int y, bool selected)
        {
            var cache = Interlocked.CompareExchange(ref selection, null, null);
            return cache != null && cache.Handle == handle && cache.Revision == Interlocked.Read(ref resultRevision) &&
                DateTime.UtcNow < cache.Time.AddMilliseconds(750)
                ? cache.Find(x, y, selected) : "";
        }

        IntPtr Keyboard(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0 && (message.ToInt32() == 0x100 || message.ToInt32() == 0x104))
            {
                int key = Marshal.ReadInt32(data);
                long foreground = Native.GetForegroundWindow().ToInt64();
                bool flow = Native.IsFlow(new IntPtr(foreground));
                string action = ClassifyKey(key, flow, Native.Down(0x12), Native.Down(0x11), Native.Down(0x10), Native.Down(0x5b) || Native.Down(0x5c));
                if (flow && action == "none" && key != 0x10 && key != 0x11 && key != 0x12 &&
                    key != 0xa0 && key != 0xa1 && key != 0xa2 && key != 0xa3 && key != 0xa4 && key != 0xa5)
                {
                    Interlocked.Increment(ref resultRevision);
                    Interlocked.Exchange(ref selection, null);
                }
                if (action == "cancel") CancelFromInput();
                else if (action == "intent") Enqueue(new InputEvent {
                    Kind = "intent", Handle = foreground, Epoch = Interlocked.Read(ref cancellationEpoch),
                    Snapshot = Interlocked.CompareExchange(ref publishedSnapshot, null, null)
                });
                else if (action == "dismiss" || action == "commit" || action == "quick")
                    Enqueue(new InputEvent {
                        Kind = action == "quick" ? "commit" : action, Handle = foreground,
                        ExpectedText = action == "quick" ? "" : CachedSelection(foreground, 0, 0, true), Epoch = Interlocked.Read(ref cancellationEpoch)
                    });
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, message, data);
        }

        public static string ClassifyKey(int key, bool flow, bool alt, bool control, bool shift, bool win)
        {
            bool navigation = win || (alt && (key == 9 || (key >= 0x31 && key <= 0x39) ||
                key == 0x41 || key == 0x44 || key == 0x53 ||
                (control && ((key >= 0x25 && key <= 0x28) || key == 0x48 || key == 0x4c))));
            if (navigation) return "cancel";
            if (flow && (key == 0x1b || (key == 0x20 && alt))) return "dismiss";
            if (key == 0x1b) return "cancel";
            if (key == 0x20 && alt) return "intent";
            if (flow && key == 0x0d && control) return "dismiss";
            if (flow && key == 0x0d && !shift && !alt && !win) return "commit";
            if (flow && key == 0x30 && alt && !control && !shift && !win) return "quick";
            if (!flow && key != 0x10 && key != 0x11 && key != 0x12 &&
                key != 0xa0 && key != 0xa1 && key != 0xa2 && key != 0xa3 && key != 0xa4 && key != 0xa5) return "cancel";
            return "none";
        }

        IntPtr Mouse(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0 && (message.ToInt32() == 0x201 || message.ToInt32() == 0x204 || message.ToInt32() == 0x207))
            {
                var point = (Native.Point)Marshal.PtrToStructure(data, typeof(Native.Point));
                IntPtr window = Native.GetAncestor(Native.WindowFromPoint(point), 2);
                if (!Native.IsFlow(window)) CancelFromInput();
                else if (message.ToInt32() == 0x201)
                {
                    string text = CachedSelection(window.ToInt64(), point.X, point.Y, false);
                    if (text.Length != 0) Enqueue(new InputEvent {
                        Kind = "commit", Handle = window.ToInt64(), ExpectedText = text, Epoch = Interlocked.Read(ref cancellationEpoch)
                    });
                }
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, message, data);
        }

        void Track()
        {
            while (!lifetime.IsCancellationRequested)
            {
                try {
                    using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token))
                    {
                        timeout.CancelAfter(2000);
                        using (var socket = Ipc.Connect(timeout.Token))
                        {
                            Ipc.Send(socket, "sub -e all", timeout.Token);
                            Ipc.RequireSuccess(Ipc.Decode(Ipc.Receive(socket, timeout.Token)));
                            Interlocked.Exchange(ref subscriptionConnected, 1);
                            RequestRefresh();
                            while (!lifetime.IsCancellationRequested)
                            {
                                string message = Ipc.Receive(socket, lifetime.Token);
                                if (message.Contains("application_exiting")) throw new IOException("GlazeWM is exiting.");
                                if (message.Contains("focus_changed") || message.Contains("window_managed") ||
                                    message.Contains("window_unmanaged") || message.Contains("workspace_") ||
                                    message.Contains("monitor_") || message.Contains("focused_container_moved")) RequestRefresh();
                            }
                        }
                    }
                } catch (Exception ex) {
                    if (!lifetime.IsCancellationRequested)
                    {
                        Interlocked.Exchange(ref subscriptionConnected, 0);
                        Interlocked.Increment(ref cancellationEpoch);
                        if (ready != null) ready.Reset();
                        Enqueue(new InputEvent { Kind = "disconnect" });
                        Log("subscription unavailable: " + ex.Message);
                    }
                }
                if (lifetime.Token.WaitHandle.WaitOne(1000)) break;
            }
        }

        void Refresh()
        {
            Interlocked.Exchange(ref refreshQueued, 0);
            var snapshot = Snapshot.Parse(commands.Request("query workspaces"));
            // A cloak may have happened while the IPC query was in flight. Do not
            // let that post-hide snapshot replace the origin pinned before closing.
            DetectHidden();
            state.ObserveSnapshot(snapshot);
            Interlocked.Exchange(ref publishedSnapshot, snapshot);
            if (ready != null && Volatile.Read(ref subscriptionConnected) != 0) ready.Set();
        }

        void DetectHidden()
        {
            if (state.FlowVisible && !Native.IsFlowVisible(new IntPtr(state.FlowHandle)))
            {
                state.FlowHidden(DateTime.UtcNow);
                Interlocked.Exchange(ref automationHandle, 0);
                Log("Flow hidden; preserving workspace " + state.Placement.Workspace);
            }
        }

        void Work()
        {
            Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            while (!lifetime.IsCancellationRequested)
            {
                try {
                    InputEvent input;
                    if (events.TryTake(out input, 20)) Handle(input);
                    DetectHidden();
                    if (state.Current == null && DateTime.UtcNow >= retryAt && Volatile.Read(ref subscriptionConnected) != 0) Refresh();
                    TryPlace();
                } catch (Exception ex) {
                    state.Cancel();
                    state.Current = null;
                    commands.Dispose();
                    Interlocked.Exchange(ref publishedSnapshot, null);
                    if (ready != null) ready.Reset();
                    retryAt = DateTime.UtcNow.AddSeconds(1);
                    if (!lifetime.IsCancellationRequested) Log("handoff cancelled: " + ex.Message);
                }
            }
        }

        void Handle(InputEvent input)
        {
            if (input.Kind == "native-handoff") { if (input.Epoch == Interlocked.Read(ref cancellationEpoch)) state.Cancel(); input.Acknowledged.Set(); Log("origin guard released for native selection"); return; }
            if (input.Kind == "refresh") { Refresh(); return; }
            if (input.Kind == "cancel" || input.Kind == "disconnect")
            {
                state.Cancel();
                if (input.Kind == "disconnect") { state.Current = null; commands.Dispose(); Interlocked.Exchange(ref publishedSnapshot, null); }
                return;
            }
            if (input.Kind == "intent")
            {
                if (input.Epoch != Interlocked.Read(ref cancellationEpoch)) return;
                state.OpenIntent(input.Snapshot, input.Handle);
                sessionEpoch = input.Epoch;
                return;
            }
            if (input.Kind == "hidden")
            {
                if (input.Handle == state.FlowHandle)
                {
                    if (state.FlowVisible) state.FlowHidden(input.Time);
                    Interlocked.Exchange(ref automationHandle, 0);
                }
                return;
            }
            if (input.Kind == "foreground")
            {
                if (input.IsFlow)
                {
                    bool first = !state.FlowVisible;
                    state.FlowShown(input.Handle, input.X, input.Y);
                    Interlocked.Exchange(ref automationHandle, input.Handle);
                    if (first) { sessionEpoch = Interlocked.Read(ref cancellationEpoch); RequestRefresh(); Log("Flow opened; origin workspace " + state.Placement.Workspace); }
                }
                else state.Foreground(input.Handle, input.Time);
                return;
            }
            if (input.Epoch != Interlocked.Read(ref cancellationEpoch)) return;
            if (input.Kind == "dismiss") { state.DismissOnly(); return; }
            if (input.Kind == "commit" && input.Handle == state.FlowHandle)
            {
                state.Commit(input.Time, input.ExpectedText);
                sessionEpoch = input.Epoch;
                if (state.Placement.Committed) Log("launch armed; workspace " + state.Placement.Workspace +
                    "; metadata=" + !String.IsNullOrEmpty(input.ExpectedText) + "; identified=" + state.Placement.IdentifiedWindowCount);
                RequestRefresh();
            }
        }

        void TryPlace()
        {
            var placement = state.Placement;
            if (placement.Workspace == null || state.Current == null) return;
            if (sessionEpoch != Interlocked.Read(ref cancellationEpoch)) { state.Cancel(); return; }
            if (!placement.Hidden) return;
            if (DateTime.UtcNow >= placement.Deadline) { state.Cancel(); return; }
            long foreground = Native.GetForegroundWindow().ToInt64();
            var target = placement.Resolve(state.Current, foreground, DateTime.UtcNow);
            string origin = placement.Workspace;
            int workspaceNumber;
            if (!Int32.TryParse(origin, out workspaceNumber)) { state.Cancel(); return; }
            if (target != null)
            {
                var fresh = Snapshot.Parse(commands.Request("query workspaces"));
                target = placement.Resolve(fresh, Native.GetForegroundWindow().ToInt64(), DateTime.UtcNow);
                if (target == null || sessionEpoch != Interlocked.Read(ref cancellationEpoch)) return;
                Guid id;
                if (!Guid.TryParse(target.Id, out id)) { state.Cancel(); return; }
                bool reuse = placement.IsExisting(target.Handle);
                string destination = reuse ? target.Workspace : origin;
                if (!reuse && target.Workspace != origin) commands.Request("command --id " + id + " move --workspace " + workspaceNumber);
                if (sessionEpoch != Interlocked.Read(ref cancellationEpoch)) { state.Cancel(); return; }
                // Move can change OS foreground itself. User cancellation, rather
                // than foreground equality after moving, controls the follow-focus.
                commands.Request("command focus --container-id " + id);
                var after = Snapshot.Parse(commands.Request("query workspaces"));
                ManagedWindow verified;
                if (after.Workspace != destination || !after.Windows.TryGetValue(target.Handle, out verified) || verified.Workspace != destination)
                    throw new IOException("Placement postcondition failed.");
                Log("placed process=" + target.Process + "; id=" + id + "; workspace=" + origin);
                state.Cancel();
                state.ObserveSnapshot(after);
                Interlocked.Exchange(ref publishedSnapshot, after);
            }
            else if (placement.NeedsRestore(state.Current, DateTime.UtcNow))
            {
                commands.Request("command focus --workspace " + workspaceNumber);
                Refresh();
                Log("restored origin workspace " + origin + "; existing windows unchanged");
            }
        }

        void ReadSelections()
        {
            Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            DateTime reportErrorAfter = DateTime.MinValue;
            while (!lifetime.IsCancellationRequested)
            {
                long handle = Interlocked.Read(ref automationHandle);
                if (handle != 0)
                {
                    try {
                        long revision = Interlocked.Read(ref resultRevision);
                        var cache = ReadRows(handle);
                        cache.Revision = revision;
                        if (Interlocked.Read(ref automationHandle) == handle && Interlocked.Read(ref resultRevision) == revision)
                            Interlocked.Exchange(ref selection, cache);
                    } catch (Exception ex) {
                        Interlocked.Exchange(ref selection, null);
                        if (DateTime.UtcNow >= reportErrorAfter) {
                            Log("optional result metadata unavailable; error=" + ex.GetType().Name);
                            reportErrorAfter = DateTime.UtcNow.AddMinutes(1);
                        }
                    }
                }
                if (lifetime.Token.WaitHandle.WaitOne(150)) break;
            }
        }

        static SelectionCache ReadRows(long handle)
        {
            var cache = new SelectionCache { Handle = handle };
            AutomationElement root = AutomationElement.FromHandle(new IntPtr(handle));
            if (root == null) return cache;
            AutomationElementCollection items;
            {
                var request = new CacheRequest();
                request.TreeScope = TreeScope.Element;
                request.Add(AutomationElement.NameProperty);
                request.Add(AutomationElement.IsOffscreenProperty);
                request.Add(AutomationElement.BoundingRectangleProperty);
                request.Add(SelectionItemPattern.IsSelectedProperty);
                using (request.Activate()) items = root.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem));
            }
            foreach (AutomationElement item in items)
            {
                if (item.Cached.IsOffscreen) continue;
                var rect = item.Cached.BoundingRectangle;
                if (rect.IsEmpty) continue;
                var text = new StringBuilder(item.Cached.Name);
                bool selected = Object.Equals(item.GetCachedPropertyValue(SelectionItemPattern.IsSelectedProperty), true);
                // Fetch all text names in one UIA request, and only for the
                // selected row. Scanning every descendant individually delayed
                // metadata until after a fast Enter/click had already hidden Flow.
                if (selected)
                {
                    {
                        var request = new CacheRequest();
                        request.TreeScope = TreeScope.Element;
                        request.Add(AutomationElement.NameProperty);
                        using (request.Activate())
                            foreach (AutomationElement part in item.FindAll(TreeScope.Descendants,
                                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Text)))
                                text.Append(" ").Append(part.Cached.Name);
                    }
                }
                cache.Rows.Add(new ResultRow { Text = text.ToString().Trim(), Left = rect.Left, Top = rect.Top,
                    Right = rect.Right, Bottom = rect.Bottom, Selected = selected });
            }
            cache.Time = DateTime.UtcNow;
            return cache;
        }

        // Kept as a small diagnostic seam for the opt-in real-Flow fixture test.
        static string ReadResult(long handle, InputEvent click, int resultIndex = -1)
        {
            var cache = ReadRows(handle);
            if (resultIndex >= 0) return resultIndex < cache.Rows.Count ? cache.Rows[resultIndex].Text : "";
            return cache.Find(click == null ? 0 : click.X, click == null ? 0 : click.Y, click == null);
        }

        void Log(string message)
        {
            try {
                lock (logLock) {
                    if (File.Exists(logPath) && new FileInfo(logPath).Length > 256 * 1024) File.Delete(logPath);
                    File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine);
                }
            } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        public void Dispose()
        {
            if (ready != null) ready.Reset();
            lifetime.Cancel();
            foreach (IntPtr hook in windowHooks) Native.UnhookWinEvent(hook);
            if (keyboardHook != IntPtr.Zero) Native.UnhookWindowsHookEx(keyboardHook);
            if (mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(mouseHook);
            if (worker != null) worker.Join(2500);
            if (tracker != null) tracker.Join(2500);
            if (control != null) control.Join(2500);
            commands.Dispose();
            // UIA is deliberately isolated on a background MTA; a stuck provider
            // must not hold shutdown or the input/event worker hostage.
            Log("stopped version=" + Version);
        }
    }

    static class Native
    {
        [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
        public delegate void WinEventProc(IntPtr hook, uint type, IntPtr window, int objectId, int childId, uint thread, uint time);
        public delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc callback, uint process, uint thread, uint flags);
        [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int type, HookProc callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("kernel32.dll", CharSet = CharSet.Auto)] public static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
        public static bool Down(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
        public static bool IsFlowVisible(IntPtr window)
        {
            int cloaked;
            return IsWindowVisible(window) && (DwmGetWindowAttribute(window, 14, out cloaked, 4) != 0 || cloaked == 0);
        }
        public static bool IsFlow(IntPtr window)
        {
            var title = new StringBuilder(256);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString() != "Flow.Launcher") return false;
            uint process;
            GetWindowThreadProcessId(window, out process);
            try { using (var app = Process.GetProcessById((int)process)) return app.ProcessName == "Flow.Launcher"; }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }
    }
}
