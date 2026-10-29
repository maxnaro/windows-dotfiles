using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

// Loopback-only RFC6455 fixture; does not bind GlazeWM's production port or require URLACLs.
public sealed class StartupSocketFixture : IDisposable {
    readonly TcpListener listener;
    readonly Thread thread;
    volatile bool stopped;
    public volatile string Mode = "ok";
    public int Connections, Requests;
    public readonly int Port;
    public StartupSocketFixture() {
        listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        thread = new Thread(Run) { IsBackground = true }; thread.Start();
    }
    static byte[] Read(Stream stream, int count) {
        var data = new byte[count]; int used = 0;
        while (used < count) { int got = stream.Read(data, used, count - used); if (got == 0) throw new EndOfStreamException(); used += got; }
        return data;
    }
    static void Send(Stream stream, string text, bool final, byte opcode) {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        stream.WriteByte((byte)((final ? 128 : 0) | opcode)); stream.WriteByte((byte)bytes.Length);
        stream.Write(bytes, 0, bytes.Length); stream.Flush();
    }
    void Run() {
        while (!stopped) {
            try {
                using (var client = listener.AcceptTcpClient()) {
                    Interlocked.Increment(ref Connections);
                    client.ReceiveTimeout = 3000;
                    using (var stream = client.GetStream()) {
                        var header = new StringBuilder();
                        while (!header.ToString().EndsWith("\r\n\r\n")) header.Append((char)Read(stream, 1)[0]);
                        string key = null;
                        foreach (var line in header.ToString().Split(new [] { "\r\n" }, StringSplitOptions.None))
                            if (line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)) key = line.Substring(line.IndexOf(':') + 1).Trim();
                        string accept;
                        using (var sha = SHA1.Create()) accept = Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                        var reply = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
                        stream.Write(reply, 0, reply.Length); stream.Flush();
                        while (!stopped) {
                            byte[] prefix = Read(stream, 2);
                            if ((prefix[0] & 15) == 8) break;
                            int length = prefix[1] & 127;
                            if (length >= 126) throw new IOException("Unexpected fixture request size.");
                            byte[] mask = (prefix[1] & 128) != 0 ? Read(stream, 4) : null;
                            byte[] data = Read(stream, length);
                            for (int i = 0; mask != null && i < length; i++) data[i] ^= mask[i % 4];
                            if (Encoding.UTF8.GetString(data) != "query monitors") throw new IOException("Unexpected command.");
                            Interlocked.Increment(ref Requests);
                            if (Mode == "hang") { Thread.Sleep(600); continue; }
                            if (Mode == "close") break;
                            if (Mode == "fragmented") { Send(stream, "{\"success\":", false, 1); Send(stream, "true}", true, 0); }
                            else Send(stream, Mode == "ok" ? "{\"success\":true}" : Mode == "failed" ? "{\"success\":false}" : "invalid-json", true, 1);
                        }
                    }
                }
            } catch { if (stopped) return; }
        }
    }
    public void Dispose() { stopped = true; listener.Stop(); thread.Join(3500); }
}
