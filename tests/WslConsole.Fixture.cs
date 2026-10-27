// Harmless console/job fixture. Never executes WSL or installs anything.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
internal static class WslConsoleFixture {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint id);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr handle,int kind,StringBuilder text,uint length,out uint needed);
    static void Save(string path,object value) { File.WriteAllText(path,new JavaScriptSerializer().Serialize(value)); }
    static int Main(string[] args) {
        string path=Environment.GetEnvironmentVariable("KILOVIEW_WSL_FIXTURE_OUTPUT");
        if (String.IsNullOrEmpty(path)) { return 94; }
        if (args.Length>0 && args[0]=="--fixture-child") {
            Save(path+".child.json",new {processId=Process.GetCurrentProcess().Id,complete=false});
            Thread.Sleep(2200);
            Save(path+".child.json",new {processId=Process.GetCurrentProcess().Id,complete=true});
            return 0;
        }
        uint inputMode,outputMode,needed;StringBuilder desktop=new StringBuilder(256);
        GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()),2,desktop,512,out needed);
        Save(path,new {processId=Process.GetCurrentProcess().Id,arguments=args,
            stdinConsole=GetConsoleMode(GetStdHandle(-10),out inputMode),stdoutConsole=GetConsoleMode(GetStdHandle(-11),out outputMode),
            hasConsole=GetConsoleWindow()!=IntPtr.Zero,visible=IsWindowVisible(GetConsoleWindow()),desktop=desktop.ToString()});
        string mode=Environment.GetEnvironmentVariable("KILOVIEW_WSL_FIXTURE_MODE");
        if (mode=="descendant") {
            Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName,"--fixture-child") {UseShellExecute=false,CreateNoWindow=true});
            return 0;
        }
        if (mode=="slow" || mode=="supervisor-crash") { Thread.Sleep(2400); }
        if (mode=="failure") { return 9; }
        if (mode=="restart") { return 3010; }
        return 0;
    }
}
