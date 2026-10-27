using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;

internal static class WslReadinessFixture
{
    private static int Main(string[] args)
    {
        string directory = Environment.GetEnvironmentVariable("KILOVIEW_READINESS_DIRECTORY");
        string mode = Environment.GetEnvironmentVariable("KILOVIEW_READINESS_MODE");
        if (String.IsNullOrEmpty(directory) || !Directory.Exists(directory)) { return 90; }
        int attempt = Directory.GetFiles(directory, "started-*.json").Length + 1;
        Process current = Process.GetCurrentProcess();
        File.WriteAllText(Path.Combine(directory, "started-" + current.Id + ".json"),
            new JavaScriptSerializer().Serialize(new {
                processId = current.Id, startedUtc = current.StartTime.ToUniversalTime().ToString("o"),
                file = current.MainModule.FileName, arguments = args, mode = mode, attempt = attempt
            }));
        if (mode == "fail-then-hang") { mode = attempt == 1 ? "failure" : "silent"; }
        if (mode == "silent") { Thread.Sleep(60000); return 91; }
        if (mode == "chatty-hang") {
            while (true) { Console.WriteLine(" still starting\0 "); Thread.Sleep(100); }
        }
        Console.WriteLine(" launch\0 detail ");
        Console.Error.WriteLine(" diagnostic detail ");
        return mode == "failure" ? 23 : 0;
    }
}
