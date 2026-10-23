// Ambient Workspace Native Messaging launcher. Uses OS-owned stdio, never TCP.
// No pairing secret, media, or exception text is written to diagnostic output.
using System;
using System.IO;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
class AmbientNativeHost {
  static int Main(string[] args) {
    Process child=null;
    try {
      string directory=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
      if(args.Length<1||!Regex.IsMatch(args[0],"^chrome-extension://[a-p]{32}/$"))return 2;
      string[] allowed=File.ReadAllLines(Path.Combine(directory,"native-host-origins.txt"));
      if(allowed.Length==0||allowed.Length>8||Array.IndexOf(allowed,args[0])<0)return 2;
      foreach(string origin in allowed)if(!Regex.IsMatch(origin,"^chrome-extension://[a-p]{32}/$"))return 2;
      var info=new ProcessStartInfo();
      info.FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell\\v1.0\\powershell.exe");
      info.Arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \""+Path.Combine(directory,"NativeHost.ps1")+"\" -CallerOrigin \""+args[0]+"\"";
      info.WorkingDirectory=directory;info.UseShellExecute=false;info.CreateNoWindow=true;
      info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
      child=Process.Start(info);
      Stream input=Console.OpenStandardInput(),output=Console.OpenStandardOutput();
      var pumpIn=Task.Run(async delegate {
        try {
          var bytes=new byte[8192];int count;
          while((count=await input.ReadAsync(bytes,0,bytes.Length))>0){await child.StandardInput.BaseStream.WriteAsync(bytes,0,count);await child.StandardInput.BaseStream.FlushAsync();}
        } catch {} finally {try{child.StandardInput.Close();}catch{}}
      });
      var pumpOut=Task.Run(async delegate {
        var bytes=new byte[8192];int count;
        while((count=await child.StandardOutput.BaseStream.ReadAsync(bytes,0,bytes.Length))>0){await output.WriteAsync(bytes,0,count);await output.FlushAsync();}
      });
      var drainError=Task.Run(delegate {var chars=new char[1024];while(child.StandardError.Read(chars,0,chars.Length)>0){}});
      child.WaitForExit();pumpOut.Wait();drainError.Wait();return child.ExitCode;
    } catch {return 3;}
    finally {if(child!=null){try{if(!child.HasExited)child.Kill();}catch{}child.Dispose();}}
  }
}
