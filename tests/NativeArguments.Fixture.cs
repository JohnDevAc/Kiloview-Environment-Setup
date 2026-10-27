// Harmless raw-command-line consumer. Never starts WSL or installs software.
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Web.Script.Serialization;

internal static class NativeArgumentsFixture
{
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    private static extern IntPtr GetCommandLineW();

    private static int Main(string[] arguments)
    {
        string commandLine=Marshal.PtrToStringUni(GetCommandLineW());
        int end=commandLine[0]=='"' ? commandLine.IndexOf('"',1)+1 : commandLine.IndexOf(' ');
        string remainder=end<0 ? "" : commandLine.Substring(end).TrimStart(' ','\t');
        int boundary=remainder.IndexOfAny(new[]{' ','\t'});
        string verb=boundary<0 ? remainder : remainder.Substring(0,boundary);
        // Mirrors WSL's top-level ParseArgument/literal-switch dispatch, which
        // retains quotes. Normal argv-only tests cannot expose this difference.
        if(verb.StartsWith("\"--",StringComparison.Ordinal)) {
            Console.Error.WriteLine("Fixture: quoted WSL switch was not recognized.");
            return 1;
        }
        string json=new JavaScriptSerializer().Serialize(new {rawArguments=remainder,rawVerb=verb,arguments=arguments});
        // Keep the evidence independent of the Windows console code page.
        StringBuilder ascii=new StringBuilder();
        foreach(char c in json) { if(c>127){ascii.Append("\\u").Append(((int)c).ToString("x4"));}else{ascii.Append(c);} }
        Console.WriteLine(ascii.ToString());
        return 0;
    }
}
