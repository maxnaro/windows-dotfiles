using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class DesktopLauncher {
    // A Windows subsystem executable has no console to pass to its children.
    private static string Quote(string value) {
        if (value.IndexOf('"') >= 0) throw new ArgumentException("Paths cannot contain quotes.");
        int trailing = value.Length - value.TrimEnd('\\').Length;
        return "\"" + value + new string('\\', trailing) + "\"";
    }
    public static int Main(string[] args) {
        string directory = AppDomain.CurrentDomain.BaseDirectory;
        try {
            if (args.Length < 1 || args.Length > 2) throw new ArgumentException("Expected startup, companions, shutdown, or reload; startup optionally accepts a CLI path.");
            string script, flags;
            switch (args[0]) {
                case "startup": script = "Start-Desktop.ps1"; flags = args.Length == 2 ? " -GlazeCli '" + args[1].Replace("'", "''") + "'" : ""; break;
                case "companions": script = "Start-Desktop.ps1"; flags = " -CompanionsOnly"; break;
                case "shutdown": script = "Start-Desktop.ps1"; flags = " -StopCompanions"; break;
                case "reload": script = "Watch-FlowWorkspace.ps1"; flags = " -Restart"; break;
                default: throw new ArgumentException("Unknown launcher mode.");
            }
            string entry = Path.Combine(directory, "Invoke-DesktopLauncher.ps1");
            if (!File.Exists(entry)) throw new FileNotFoundException("Launcher entry script missing", entry);
            string arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(entry) + " -Mode " + args[0];
            if (args.Length == 2) {
                if (args[0] != "startup") throw new ArgumentException("Only startup accepts a CLI path.");
                arguments += " -GlazeCli " + Quote(args[1]);
            }
            var info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe"), arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WorkingDirectory = directory;
            using (var child = Process.Start(info)) {
                if (args[0] == "reload") return 0;
                child.WaitForExit();
                return child.ExitCode;
            }
        } catch (Exception error) {
            try { File.AppendAllText(Path.Combine(directory, "launcher-errors.log"), DateTime.Now.ToString("o") + " " + error + Environment.NewLine); } catch { }
            return 1;
        }
    }
}
