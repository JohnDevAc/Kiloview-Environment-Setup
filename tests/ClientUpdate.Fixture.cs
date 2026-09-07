// Harmless replacement for PC Agent Setup. All writes stay beneath a test-owned
// directory passed by the isolated harness; no configuration or agent is run.
using System;
using System.IO;
using System.Reflection;
using System.Threading;

[assembly: AssemblyProduct("NDI Configurator PC Agent")]
[assembly: AssemblyFileVersion("0.7.2.0")]
[assembly: AssemblyInformationalVersion("0.7.2+fixture")]
internal static class ClientUpdateFixture
{
    private static int Main()
    {
        string root = Environment.GetEnvironmentVariable("KILOLINK_CLIENT_UPDATE_FIXTURE");
        if (string.IsNullOrEmpty(root) || !File.Exists(Path.Combine(root, "fixture-only"))) return 99;
        string mode = File.ReadAllText(Path.Combine(root, "mode"));
        Thread.Sleep(mode == "fast" ? 0 : 650);
        if (mode == "cancel") return 2;
        if (mode == "fail-before") return 1;
        string installed = Path.Combine(root, "program-files", "NDI Configurator", "PC Agent");
        Directory.CreateDirectory(installed);
        string source = Assembly.GetExecutingAssembly().Location;
        File.Copy(source, Path.Combine(installed, "NDI Configurator PC Agent Setup.exe"), true);
        if (mode != "mixed") File.Copy(Path.Combine(Path.GetDirectoryName(source), "Agent", "NDI Configurator PC Agent.exe"),
            Path.Combine(installed, "NDI Configurator PC Agent.exe"), true);
        string state = Path.Combine(root, "profile", "AppData", "Local", "NDI Configurator", "PC Agent");
        Directory.CreateDirectory(state);
        if (mode != "unconfigured") File.WriteAllText(Path.Combine(state, "agent-state.json"), File.ReadAllText(Path.Combine(root, "valid-state.json")));
        return mode.StartsWith("fail-after", StringComparison.Ordinal) ? 1 : 0;
    }
}
