using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("KiloLink Environment Setup")]
[assembly: AssemblyDescription("Launcher for KiloLink Server Pro and NDI Environment Setup")]
[assembly: AssemblyCompany("JohnDevAc")]
[assembly: AssemblyProduct("KiloLink Environment Setup")]
[assembly: AssemblyCopyright("Copyright © JohnDevAc 2026")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace KiloLink.Setup
{
    internal static class SetupLauncher
    {
        private const string InstallerResourceName = "KiloLink.Setup.Install-KiloLinkSuite.ps1";
        private const string InstallerFileName = "Install-KiloLinkSuite.ps1";

        [STAThread]
        private static int Main()
        {
            string extractionDirectory = null;
            string installerPath = null;

            try
            {
                extractionDirectory = Path.Combine(
                    Path.GetTempPath(),
                    "KiloLinkEnvironmentSetup",
                    Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(extractionDirectory);
                installerPath = Path.Combine(extractionDirectory, InstallerFileName);

                ExtractInstaller(installerPath);

                string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string powershellPath = Path.Combine(
                    systemDirectory,
                    "WindowsPowerShell",
                    "v1.0",
                    "powershell.exe");
                if (!File.Exists(powershellPath))
                {
                    powershellPath = "powershell.exe";
                }

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = powershellPath;
                startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " + Quote(installerPath);
                startInfo.WorkingDirectory = extractionDirectory;
                startInfo.UseShellExecute = true;
                startInfo.WindowStyle = ProcessWindowStyle.Normal;

                using (Process installer = Process.Start(startInfo))
                {
                    if (installer == null)
                    {
                        throw new InvalidOperationException("Windows did not start the PowerShell installer.");
                    }

                    installer.WaitForExit();
                    return installer.ExitCode;
                }
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "KiloLink Environment Setup could not start.\r\n\r\n" + exception.Message,
                    "KiloLink Environment Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                TryDelete(installerPath, extractionDirectory);
            }
        }

        private static void ExtractInstaller(string destination)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resource = assembly.GetManifestResourceStream(InstallerResourceName))
            {
                if (resource == null)
                {
                    throw new InvalidOperationException("The embedded PowerShell installer is missing.");
                }

                using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    resource.CopyTo(output);
                }
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void TryDelete(string installerPath, string extractionDirectory)
        {
            try
            {
                if (!String.IsNullOrWhiteSpace(installerPath) && File.Exists(installerPath))
                {
                    File.Delete(installerPath);
                }

                if (!String.IsNullOrWhiteSpace(extractionDirectory) && Directory.Exists(extractionDirectory))
                {
                    Directory.Delete(extractionDirectory, false);
                }
            }
            catch
            {
                // A temporary file left behind is safe and will be removed by
                // the user's normal temporary-file cleanup.
            }
        }
    }
}
