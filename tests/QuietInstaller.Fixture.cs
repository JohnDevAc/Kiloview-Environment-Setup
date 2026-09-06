// A harmless stand-in for an installer that launches an unsolicited GUI child.
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
class Fixture
{
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint id);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder name, int length, out int needed);
    [STAThread] static int Main(string[] args)
    {
        string root = args[0];
        if (args.Length == 1)
        {
            var start = new ProcessStartInfo(Application.ExecutablePath, "\"" + root + "\" child");
            start.UseShellExecute = false;
            using (var child = Process.Start(start))
            {
                for (int i = 0; i < 100 && !File.Exists(root + ".child"); i++) System.Threading.Thread.Sleep(50);
                return File.Exists(root + ".child") ? 3010 : 1;
            }
        }
        var form = new Form { Text = "Kiloview hidden installer test fixture" };
        form.Shown += delegate {
            var desktop = new StringBuilder(256); int needed;
            GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()), 2, desktop, desktop.Capacity * 2, out needed);
            File.WriteAllText(root + ".child", Process.GetCurrentProcess().Id + "\n" + desktop + "\n" + form.Visible);
        };
        Application.Run(form);
        return 0;
    }
}
