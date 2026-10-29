// Compiled into a uniquely named temporary GUI executable by Test-FlowWorkspace.ps1.
// A second launch activates the first instance, so the same fixture tests reuse.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Dotfiles.FlowWorkspace.Tests
{
    public static class Fixture
    {
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

        static void Trace(string message)
        {
            try {
                File.AppendAllText(Path.ChangeExtension(Application.ExecutablePath, ".invocations"),
                    DateTime.UtcNow.ToString("o") + " pid=" + Process.GetCurrentProcess().Id + " " + message + Environment.NewLine);
            } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        [STAThread]
        public static void Main()
        {
            string name = Path.GetFileNameWithoutExtension(Application.ExecutablePath);
            Trace("startup");
            bool created;
            using (var single = new Mutex(true, "Local\\" + name, out created))
            {
                if (!created)
                {
                    for (int attempt = 0; attempt < 100; attempt++)
                    {
                        foreach (Process app in Process.GetProcessesByName(name))
                        {
                            using (app)
                            {
                                if (app.Id == Process.GetCurrentProcess().Id || app.MainWindowHandle == IntPtr.Zero) continue;
                                IntPtr target = app.MainWindowHandle;
                                bool shown = ShowWindow(target, 9);
                                bool focused = SetForegroundWindow(target);
                                Trace("reuse hwnd=" + target.ToInt64() + " showWindow=" + shown + " setForegroundWindow=" + focused);
                                return;
                            }
                        }
                        Thread.Sleep(50);
                    }
                    Trace("reuse target unavailable");
                    return;
                }
                string delayFile = Path.ChangeExtension(Application.ExecutablePath, ".delay");
                int delay;
                if (File.Exists(delayFile) && Int32.TryParse(File.ReadAllText(delayFile), out delay))
                    Thread.Sleep(Math.Max(0, Math.Min(delay, 5000)));
                Application.EnableVisualStyles();
                using (var window = new Form { Text = name, Width = 420, Height = 180 })
                {
                    window.Controls.Add(new Label { Dock = DockStyle.Fill, TextAlign = System.Drawing.ContentAlignment.MiddleCenter,
                        Text = "Temporary Flow workspace regression fixture\r\nThis window will close when the test finishes." });
                    window.Shown += delegate {
                        window.Activate();
                        Trace("shown hwnd=" + window.Handle.ToInt64() + " isForeground=" + (GetForegroundWindow() == window.Handle));
                    };
                    Application.Run(window);
                }
            }
        }
    }
}
