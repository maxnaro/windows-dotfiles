using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

// Loopback-only RFC6455 fixture; does not bind GlazeWM's production port or require URLACLs.
public sealed class TitleBarSocketFixture : IDisposable {
    readonly TcpListener listener;
    readonly Thread thread;
    volatile bool stopped;
    public volatile bool Paused, Managed=true;
    public long Handle;
    Stream subscriber;
    readonly object sendLock=new object();
    readonly System.Collections.Generic.List<TcpClient> clients=new System.Collections.Generic.List<TcpClient>();
    public void Notify(string type) {
        lock(sendLock) {if(subscriber!=null)Send(subscriber,"{\"data\":{\"eventType\":\""+type+"\"}}",true,1);}
    }
    public void Disconnect() {lock(clients){foreach(var client in clients)client.Close();}}

    public int Connections, Requests;
    public readonly int Port;
    public TitleBarSocketFixture() {
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
        while(!stopped) {
            try {
                var client=listener.AcceptTcpClient();
                lock(clients)clients.Add(client);
                var worker=new Thread(()=>Serve(client)){IsBackground=true};worker.Start();
            }catch {if(stopped)return;}
        }
    }
    void Serve(TcpClient client) {
        try {
            using(client)using(var stream=client.GetStream()) {
                var header=new StringBuilder();
                while(!header.ToString().EndsWith("\r\n\r\n"))header.Append((char)Read(stream,1)[0]);
                string key=null;
                foreach(var line in header.ToString().Split(new[]{"\r\n"},StringSplitOptions.None))
                    if(line.StartsWith("Sec-WebSocket-Key:",StringComparison.OrdinalIgnoreCase))key=line.Substring(line.IndexOf(':')+1).Trim();
                string accept;
                using(var sha=SHA1.Create())accept=Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                var reply=Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "+accept+"\r\n\r\n");
                stream.Write(reply,0,reply.Length);stream.Flush();
                while(!stopped) {
                    var prefix=Read(stream,2);if((prefix[0]&15)==8)return;
                    int length=prefix[1]&127;
                    if(length==126){var size=Read(stream,2);length=size[0]*256+size[1];}
                    var mask=Read(stream,4);var data=Read(stream,length);
                    for(int i=0;i<length;i++)data[i]^=mask[i%4];
                    string command=Encoding.UTF8.GetString(data);
                    string response;
                    if(command.StartsWith("sub ")) {
                        lock(sendLock){subscriber=stream;Send(stream,"{\"success\":true,\"data\":{\"subscriptionId\":\"fixture\"}}",true,1);}
                        continue;
                    }
                    if(command=="query paused")response="{\"success\":true,\"data\":"+(Paused?"true":"false")+"}";
                    else if(command=="query windows")response="{\"success\":true,\"data\":{\"windows\":"+(Managed?"[{\"handle\":"+Handle+"}]":"[]")+"}}";
                    else throw new IOException("Unexpected command: "+command);
                    Send(stream,response,true,1);
                }
            }
        }catch { }finally{lock(clients)clients.Remove(client);}
    }
    public void Dispose(){stopped=true;listener.Stop();Disconnect();thread.Join(3000);}
}

public static class TitleBarLifecycleFixture {
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern IntPtr GetWindowLongPtrW(IntPtr h,int index);
    static void Wait(Func<bool> condition,string message) {
        var end=DateTime.UtcNow.AddSeconds(6);
        while(!condition()) {
            System.Windows.Forms.Application.DoEvents();
            if(DateTime.UtcNow>=end)throw new Exception(message);
            Thread.Sleep(10);
        }
    }
    public static void Run(string path) {
        using(var form=new System.Windows.Forms.Form())
        using(var server=new TitleBarSocketFixture())
        using(var stop=new ManualResetEvent(false)) {
            server.Handle=form.Handle.ToInt64();
            IntPtr handle=form.Handle;
            Func<bool> visible=()=>((GetWindowLongPtrW(handle,-16).ToInt64()&0x400000)!=0);
            var info=new System.Diagnostics.ProcessStartInfo("ping.exe","-n 61 127.0.0.1") { UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true };
            using(var owner=System.Diagnostics.Process.Start(info)) {
                Exception failure=null;
                Func<Thread> start=()=> {
                    stop.Reset();
                    var thread=new Thread(()=>{try{Dotfiles.TitleBars.Run(stop,path,"ws://127.0.0.1:"+server.Port,owner.Id);}catch(Exception error){failure=error;}}){IsBackground=true};
                    thread.Start();return thread;
                };
                Thread worker=null;
                try {
                    worker=start();Wait(()=>!visible(),"Initial managed frame was not hidden");
                    server.Paused=true;server.Notify("pause_changed");Wait(visible,"Pause did not restore frame");
                    server.Paused=false;server.Notify("pause_changed");Wait(()=>!visible(),"Resume did not hide frame");
                    server.Managed=false;server.Notify("window_unmanaged");Wait(visible,"Unmanage did not restore frame");
                    server.Managed=true;server.Notify("window_managed");Wait(()=>!visible(),"Remanage did not hide frame");
                    server.Notify("application_exiting");Wait(()=>!worker.IsAlive,"Exit event did not stop helper");
                    if(!visible())throw new Exception("Exit did not restore frame");
                    worker=start();Wait(()=>!visible(),"Second connection did not hide frame");
                    server.Disconnect();Wait(visible,"Disconnect did not restore frame");
                    stop.Set();Wait(()=>!worker.IsAlive,"Disconnected helper did not stop");
                    worker=start();Wait(()=>!visible(),"Reconnect did not hide frame");
                    owner.Kill();Wait(()=>!worker.IsAlive,"Owner crash did not stop helper");
                    if(!visible())throw new Exception("Owner crash did not restore frame");
                    if(failure!=null)throw failure;
                } finally {
                    stop.Set();
                    if(worker!=null)Wait(()=>!worker.IsAlive,"Fixture helper did not stop");
                    if(!owner.HasExited)owner.Kill();
                }
            }
        }
    }
}
