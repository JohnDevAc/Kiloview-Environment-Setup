using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class InstallerLogReader : IDisposable
{
    private FileStream stream;
    private Timer timer;
    public InstallerLogReader(string path, bool cooperative, int releaseMilliseconds)
    {
        stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            cooperative ? FileShare.ReadWrite | FileShare.Delete : FileShare.Read);
        if (releaseMilliseconds > 0) { timer = new Timer(delegate { Dispose(); }, null, releaseMilliseconds, Timeout.Infinite); }
    }
    public void Dispose()
    {
        FileStream file = Interlocked.Exchange(ref stream, null); if (file != null) { file.Dispose(); }
        Timer tick = Interlocked.Exchange(ref timer, null); if (tick != null) { tick.Dispose(); }
    }
}

internal static class InstallerLoggingFixture
{
    private static int Main(string[] args)
    {
        if (args.Length != 2 || !Directory.Exists(args[0])) { return 90; }
        Process current = Process.GetCurrentProcess();
        File.WriteAllText(Path.Combine(args[0], "started.json"), new JavaScriptSerializer().Serialize(new {
            processId = current.Id, startedUtc = current.StartTime.ToUniversalTime().ToString("o"), file = current.MainModule.FileName
        }));
        Console.WriteLine("native stdout"); Console.Error.WriteLine("native diagnostic");
        if (args[1] == "hold") { Thread.Sleep(3200); }
        // No pipe writes after the parent may have stopped observing this child.
        File.WriteAllText(Path.Combine(args[0], "completed.txt"), "natural completion");
        return args[1] == "failure" ? 23 : 0;
    }
}
