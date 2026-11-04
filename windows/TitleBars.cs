using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
namespace Dotfiles {
 public static class TitleBars {
  const int Mask=0x400000;
  const string Property="Dotfiles.TitleBars.Owner";
  static readonly JavaScriptSerializer Json=new JavaScriptSerializer { MaxJsonLength=8388608 };
  public class Record {public long Handle,Start,Token;public int Pid,Bits;}
  [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr h,int i);
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowLongPtrW(IntPtr h,int i,IntPtr v);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out int pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool SetPropW(IntPtr h,string name,IntPtr value);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetPropW(IntPtr h,string name);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr RemovePropW(IntPtr h,string name);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
  static void Log(string path,string message) {
   try {string log=path+".log";if(File.Exists(log) && new FileInfo(log).Length>262144)File.WriteAllText(log,"");File.AppendAllText(log,DateTime.UtcNow.ToString("o")+" "+message+Environment.NewLine);}catch { }
  }
  static long ProcessStart(int pid){using(var process=Process.GetProcessById(pid))return process.StartTime.ToUniversalTime().Ticks;}
  static bool Valid(Record r){try{int pid;GetWindowThreadProcessId(new IntPtr(r.Handle),out pid);return pid==r.Pid && ProcessStart(pid)==r.Start && GetPropW(new IntPtr(r.Handle),Property).ToInt64()==r.Token;}catch{return false;}}
  static void Frame(IntPtr h,int style){SetWindowLongPtrW(h,-16,new IntPtr(style));SetWindowPos(h,IntPtr.Zero,0,0,0,0,0x37);}
  static void Save(string path,List<Record> records){string tmp=path+".tmp";File.WriteAllText(tmp,Json.Serialize(records));if(File.Exists(path))File.Replace(tmp,path,null);else File.Move(tmp,path);}
  static void RestoreRecords(List<Record> records){foreach(var r in records.ToArray()){if(Valid(r)){var h=new IntPtr(r.Handle);Frame(h,(int)GetWindowLongPtrW(h,-16).ToInt64()|r.Bits);if(((int)GetWindowLongPtrW(h,-16).ToInt64()&r.Bits)!=r.Bits)continue;RemovePropW(h,Property);}records.Remove(r);}}
  static void Restore(string path,List<Record> records){if(records.Count==0)return;RestoreRecords(records);Save(path,records);}
  public static void Recover(string path){if(File.Exists(path)){var records=Json.Deserialize<List<Record>>(File.ReadAllText(path));Restore(path,records);if(records.Count!=0)throw new IOException("Some title bars could not be restored; recovery journal retained.");}}
  static string Receive(ClientWebSocket socket,CancellationToken token){var buffer=new byte[8192];using(var output=new MemoryStream()){WebSocketReceiveResult r;do{r=socket.ReceiveAsync(new ArraySegment<byte>(buffer),token).GetAwaiter().GetResult();if(r.MessageType==WebSocketMessageType.Close)throw new IOException("GlazeWM disconnected");output.Write(buffer,0,r.Count);if(output.Length>8388608)throw new IOException("IPC response too large");}while(!r.EndOfMessage);return Encoding.UTF8.GetString(output.ToArray());}}
  static object Query(ClientWebSocket s,string command){using(var timeout=new CancellationTokenSource(2000)){var bytes=Encoding.UTF8.GetBytes(command);s.SendAsync(new ArraySegment<byte>(bytes),WebSocketMessageType.Text,true,timeout.Token).GetAwaiter().GetResult();var result=Json.Deserialize<Dictionary<string,object>>(Receive(s,timeout.Token));if(!(bool)result["success"])throw new IOException("IPC query failed");return result["data"];}}
  sealed class Subscription : IDisposable {
   readonly ClientWebSocket socket = new ClientWebSocket();
   readonly CancellationTokenSource lifetime = new CancellationTokenSource();
   public readonly AutoResetEvent Changed = new AutoResetEvent(true);
   public volatile bool Failed, Exiting;
   Thread reader;
   public Subscription(string endpoint) {
    try {
     socket.Options.Proxy=null;
     using(var timeout=new CancellationTokenSource(2000)) {
      socket.ConnectAsync(new Uri(endpoint),timeout.Token).GetAwaiter().GetResult();
      var command=Encoding.UTF8.GetBytes("sub -e window_managed window_unmanaged pause_changed user_config_changed focus_changed application_exiting");
      socket.SendAsync(new ArraySegment<byte>(command),WebSocketMessageType.Text,true,timeout.Token).GetAwaiter().GetResult();
      var response=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Receive(socket,timeout.Token));
      if(!(bool)response["success"])throw new IOException("Subscription failed");
     }
     reader=new Thread(Read);reader.IsBackground=true;reader.Start();
    }catch {Dispose();throw;}
   }
   void Read() {
    try {while(!lifetime.IsCancellationRequested) {
     var response=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(Receive(socket,lifetime.Token));
     object data;
     if(response.TryGetValue("data",out data) && data is Dictionary<string,object>) {
      object type;
      if(((Dictionary<string,object>)data).TryGetValue("eventType",out type) && (string)type=="application_exiting")Exiting=true;
     }
     Changed.Set();
    }}catch {Failed=true;Changed.Set();}
   }
   public void Dispose(){lifetime.Cancel();socket.Abort();if(reader!=null)reader.Join(3000);socket.Dispose();lifetime.Dispose();Changed.Dispose();}
  }
  public static void Run(EventWaitHandle stop,string path) {
   Run(stop,path,"ws://127.0.0.1:6123",0);
  }
  // Explicit endpoint and owner make lifecycle tests independent of the desktop.
  public static void Run(EventWaitHandle stop,string path,string endpoint,int ownerId) {
   var records=new List<Record>();int delay=1000;
   try {
    while(!stop.WaitOne(0)) {
     Process owner=null;
     if(ownerId!=0) {
      try {owner=Process.GetProcessById(ownerId);}catch(ArgumentException){return;}
     }
     foreach(var process in ownerId==0 ? Process.GetProcessesByName("GlazeWM") : new Process[0]) {
      try {if(process.SessionId==Process.GetCurrentProcess().SessionId && process.MainModule.FileName.IndexOf("\\cli\\",StringComparison.OrdinalIgnoreCase)<0){owner=process;break;}}
      catch { }
      process.Dispose();
     }
     if(owner==null)return;
     try {
      using(owner)using(var subscription=new Subscription(endpoint))using(var socket=new ClientWebSocket()) {
       socket.Options.Proxy=null;
       using(var timeout=new CancellationTokenSource(2000)){socket.ConnectAsync(new Uri(endpoint),timeout.Token).GetAwaiter().GetResult();}
       delay=1000;
       var waits=new WaitHandle[]{stop,subscription.Changed};
       while(!owner.HasExited) {
        int signaled=WaitHandle.WaitAny(waits,1000);
        if(signaled==0 || subscription.Exiting)return;
        if(subscription.Failed)throw new IOException("Subscription disconnected");
        if(signaled==WaitHandle.WaitTimeout)continue;
        bool paused=(bool)Query(socket,"query paused");
        if(paused){Restore(path,records);continue;}
        var windows=(System.Collections.IEnumerable)((Dictionary<string,object>)Query(socket,"query windows"))["windows"];
        var handles=new HashSet<long>();
        foreach(Dictionary<string,object> window in windows) {
         long handle=Convert.ToInt64(window["handle"]);handles.Add(handle);
         if(records.Exists(r=>r.Handle==handle && Valid(r))) {
          var tracked=new IntPtr(handle);
          int current=(int)GetWindowLongPtrW(tracked,-16).ToInt64();
          if((current&Mask)!=0)Frame(tracked,current&~Mask);
          continue;
         }
         try {
          var h=new IntPtr(handle);int style=(int)GetWindowLongPtrW(h,-16).ToInt64();
          if((style&0xC00000)!=0xC00000)continue;
          int pid;GetWindowThreadProcessId(h,out pid);
          long start;using(var process=Process.GetProcessById(pid))start=process.StartTime.ToUniversalTime().Ticks;
          var record=new Record{Handle=handle,Pid=pid,Start=start,Token=Guid.NewGuid().GetHashCode()&0x7fffffff,Bits=style&Mask};
          if(record.Token==0)record.Token=1;
          if(!SetPropW(h,Property,new IntPtr(record.Token))){Log(path,"Cannot mark window "+handle);continue;}
          records.Add(record);Save(path,records);Frame(h,style&~Mask);
         }catch(Exception error){Log(path,"Window "+handle+": "+error.Message);}
        }
        var removed=records.FindAll(r=>!handles.Contains(r.Handle));
        int removedCount=removed.Count;
        RestoreRecords(removed);
        records.RemoveAll(r=>!handles.Contains(r.Handle) && !removed.Contains(r));
        if(removedCount>0)Save(path,records);
       }
      }
     }catch(Exception error){Log(path,error.Message);Restore(path,records);if(stop.WaitOne(delay))return;delay=Math.Min(delay*2,30000);}
    }
   }finally{Restore(path,records);}
  }
 }
}
