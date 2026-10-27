// Copyright (c) 2026 John Lightfoot. SPDX-License-Identifier: MIT
// Compiled from the embedded sources into an owned operation directory. This
// independent observer keeps the job alive if the PowerShell caller times out.
namespace KiloLink.Lifecycle
{
    internal static class WslBootstrapHost
    {
        private static int Main(string[] args) {
            if (args.Length != 2) { return 87; }
            var principal = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent());
            if (!principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator)) { return 5; }
            return Run(System.IO.Path.Combine(System.Environment.SystemDirectory,"wsl.exe"),
                new string[]{"--install","--no-distribution","--web-download"},args[0],args[1]);
        }
        internal static int Run(string file,string[] arguments,string jobName,string resultPath) {
            ConsoleBootstrapProcess owned=null;
            string failure="";
            int code=1;
            var state=new System.Collections.Generic.Dictionary<string,object> {
                {"schemaVersion",1},{"jobName",jobName},{"phase","starting"},
                {"hostProcessId",System.Diagnostics.Process.GetCurrentProcess().Id},
                {"hostStartedUtc",System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o")}};
            try {
                Write(resultPath,state);
                owned=new ConsoleBootstrapProcess(file,arguments,jobName);
                state["rootProcessId"]=owned.Id;state["rootStartedUtc"]=owned.StartedUtc.ToString("o");state["phase"]="running";
                Write(resultPath,state);
                while(!owned.HasExited) {System.Threading.Thread.Sleep(100);}
                code=owned.ExitCode;
            } catch(System.Exception error) {
                failure=error.Message;
                // Even a receipt failure must not release job ownership during
                // servicing. The caller can time out; this observer stays alive.
                if(owned!=null) {
                    while(!owned.HasExited) {System.Threading.Thread.Sleep(200);}
                    code=owned.ExitCode;
                }
            } finally {
                if(owned!=null) {owned.Dispose();}
            }
            state["phase"]="completed";state["exitCode"]=code;state["error"]=failure;state["finishedUtc"]=System.DateTime.UtcNow.ToString("o");
            try {Write(resultPath,state);} catch(System.Exception error) {System.Console.Error.WriteLine(error.Message);return 1;}
            if(failure.Length!=0) {System.Console.Error.WriteLine(failure);return 1;}
            return code;
        }
        private static void Write(string path,System.Collections.Generic.Dictionary<string,object> state) {
            path=System.IO.Path.GetFullPath(path);SafePath.CheckParent(path);
            if(System.IO.File.Exists(path)) {SafePath.Check(path);}
            using(AtomicFile.Acquire(path)) {
                string temporary=System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path),".bootstrap-"+System.Guid.NewGuid().ToString("N")+".tmp");
                try {
                    using(var stream=new System.IO.FileStream(temporary,System.IO.FileMode.CreateNew,System.IO.FileAccess.Write,System.IO.FileShare.None)) {
                        byte[] bytes=new System.Text.UTF8Encoding(false).GetBytes(new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(state));
                        stream.Write(bytes,0,bytes.Length);stream.Flush(true);
                    }
                    AtomicFile.Commit(temporary,path,delegate {SafePath.CheckParent(path);if(System.IO.File.Exists(path)){SafePath.Check(path);}});
                } finally {if(System.IO.File.Exists(temporary)){System.IO.File.Delete(temporary);}}
            }
        }
    }
}
