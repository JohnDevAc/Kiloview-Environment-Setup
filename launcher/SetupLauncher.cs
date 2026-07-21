using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

[assembly: AssemblyTitle("Kiloview Environment Setup")]
[assembly: AssemblyDescription("Launcher for KiloLink Server Pro and NDI Environment Setup")]
[assembly: AssemblyCompany("JohnDevAc")]
[assembly: AssemblyProduct("Kiloview Environment Setup")]
[assembly: AssemblyCopyright("Copyright JohnDevAc 2026")]
[assembly: AssemblyVersion("1.2.5.0")]
[assembly: AssemblyFileVersion("1.2.5.0")]

namespace KiloLink.Setup
{
    internal static class SetupLauncher
    {
        private const string InstallerResourceName = "KiloLink.Setup.Install-KiloLinkSuite.ps1";
        private const string InstallerFileName = "Install-KiloLinkSuite.ps1";

        [STAThread]
        private static int Main(string[] arguments)
        {
            try
            {
                bool autoResume = false;
                foreach (string argument in arguments)
                {
                    if (String.Equals(argument, "--resume", StringComparison.OrdinalIgnoreCase))
                    {
                        autoResume = true;
                    }
                }
                if (!IsAdministrator())
                {
                    ProcessStartInfo elevation = new ProcessStartInfo();
                    elevation.FileName = Assembly.GetExecutingAssembly().Location;
                    elevation.Arguments = autoResume ? "--resume" : String.Empty;
                    elevation.Verb = "runas";
                    elevation.UseShellExecute = true;
                    Process.Start(elevation);
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new SetupForm(autoResume));
                return Environment.ExitCode;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "Kiloview Environment Setup could not start.\r\n\r\n" + exception.Message,
                    "Kiloview Environment Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

        internal static void ExtractInstaller(string destination)
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

        internal static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static bool IsAdministrator()
        {
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            WindowsPrincipal principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly Button startButton;
        private readonly Button logButton;
        private readonly Label statusLabel;
        private Process installerProcess;
        private readonly string launcherDirectory;
        private readonly string persistentLauncherPath;
        private readonly string legacyPersistentLauncherPath;
        private readonly string installerPath;
        private readonly string logPath;
        private readonly bool autoResume;

        internal SetupForm(bool resume)
        {
            autoResume = resume;
            string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
            launcherDirectory = Path.Combine(programData, "KiloLink", "Launcher");
            persistentLauncherPath = Path.Combine(launcherDirectory, "Kiloview-Environment-Setup.exe");
            legacyPersistentLauncherPath = Path.Combine(launcherDirectory, "KiloLink-Environment-Setup.exe");
            installerPath = Path.Combine(launcherDirectory, "Install-KiloLinkSuite.ps1");
            logPath = Path.Combine(programData, "KiloLink", "setup-launcher.log");

            Text = "Kiloview Environment Setup";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new System.Drawing.Size(500, 225);
            Font = new System.Drawing.Font("Segoe UI", 9F);
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);

            Label title = new Label();
            title.Text = "KiloLink Server Pro + NDI Environment";
            title.Font = new System.Drawing.Font("Segoe UI Semibold", 15F);
            title.AutoSize = true;
            title.Location = new System.Drawing.Point(24, 22);

            Label description = new Label();
            description.Text = "Starts the guided Windows 11 installer with Administrator access.\r\nThe PowerShell menu will open in a separate window.";
            description.AutoSize = true;
            description.Location = new System.Drawing.Point(27, 65);

            startButton = new Button();
            startButton.Text = autoResume ? "Resume setup" : "Start setup";
            startButton.Size = new System.Drawing.Size(135, 36);
            startButton.Location = new System.Drawing.Point(29, 111);
            startButton.Click += StartButtonClick;

            logButton = new Button();
            logButton.Text = "View diagnostic log";
            logButton.Size = new System.Drawing.Size(150, 36);
            logButton.Location = new System.Drawing.Point(174, 111);
            logButton.Enabled = File.Exists(logPath);
            logButton.Click += LogButtonClick;

            Button closeButton = new Button();
            closeButton.Text = "Close";
            closeButton.Size = new System.Drawing.Size(100, 36);
            closeButton.Location = new System.Drawing.Point(334, 111);
            closeButton.Click += delegate { Close(); };

            statusLabel = new Label();
            statusLabel.Text = "Ready to start.";
            statusLabel.AutoSize = false;
            statusLabel.Size = new System.Drawing.Size(440, 42);
            statusLabel.Location = new System.Drawing.Point(27, 169);

            Controls.Add(title);
            Controls.Add(description);
            Controls.Add(startButton);
            Controls.Add(logButton);
            Controls.Add(closeButton);
            Controls.Add(statusLabel);
            AcceptButton = startButton;
            if (autoResume)
            {
                statusLabel.Text = "Waiting for Windows to finish sign-in before resuming setup...";
                Shown += delegate { BeginInvoke((MethodInvoker)StartInstaller); };
            }
        }

        private void StartButtonClick(object sender, EventArgs eventArgs)
        {
            StartInstaller();
        }

        private void StartInstaller()
        {
            try
            {
                Directory.CreateDirectory(launcherDirectory);
                string currentLauncher = Assembly.GetExecutingAssembly().Location;
                if (!String.Equals(
                    Path.GetFullPath(currentLauncher),
                    Path.GetFullPath(persistentLauncherPath),
                    StringComparison.OrdinalIgnoreCase))
                {
                    File.Copy(currentLauncher, persistentLauncherPath, true);
                }
                if (File.Exists(legacyPersistentLauncherPath)
                    && !String.Equals(
                        Path.GetFullPath(currentLauncher),
                        Path.GetFullPath(legacyPersistentLauncherPath),
                        StringComparison.OrdinalIgnoreCase))
                {
                    try { File.Delete(legacyPersistentLauncherPath); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
                SetupLauncher.ExtractInstaller(installerPath);

                string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string powershellPath = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershellPath))
                {
                    powershellPath = "powershell.exe";
                }

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = powershellPath;
                startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File "
                    + SetupLauncher.Quote(installerPath)
                    + (autoResume ? " -Action Resume -AcceptLicenses" : String.Empty)
                    + " -LauncherMode -LogPath "
                    + SetupLauncher.Quote(logPath);
                startInfo.WorkingDirectory = launcherDirectory;
                startInfo.UseShellExecute = true;
                startInfo.WindowStyle = ProcessWindowStyle.Normal;

                installerProcess = new Process();
                installerProcess.StartInfo = startInfo;
                installerProcess.EnableRaisingEvents = true;
                installerProcess.Exited += InstallerProcessExited;
                if (!installerProcess.Start())
                {
                    throw new InvalidOperationException("Windows did not start the PowerShell installer.");
                }

                startButton.Enabled = false;
                statusLabel.Text = autoResume
                    ? "Resumed installer running. Windows and WSL state are being verified."
                    : "Installer running. Follow the menu in the PowerShell window.";
            }
            catch (Exception exception)
            {
                Environment.ExitCode = 1;
                statusLabel.Text = "Setup could not start: " + exception.Message;
                logButton.Enabled = File.Exists(logPath);
                MessageBox.Show(
                    "Setup could not start.\r\n\r\n" + exception.Message,
                    "Kiloview Environment Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private void InstallerProcessExited(object sender, EventArgs eventArgs)
        {
            int exitCode = installerProcess.ExitCode;
            BeginInvoke((MethodInvoker)delegate
            {
                startButton.Enabled = true;
                logButton.Enabled = File.Exists(logPath);
                if (exitCode == 0)
                {
                    statusLabel.Text = autoResume
                        ? "Resumed setup finished. Review the PowerShell completion summary."
                        : "Installer closed. You can run it again if required.";
                }
                else
                {
                    Environment.ExitCode = exitCode == 0 ? 1 : exitCode;
                    statusLabel.Text = "Installer exited unexpectedly. Open the diagnostic log for details.";
                    MessageBox.Show(
                        "The PowerShell installer exited before completing startup.\r\n\r\n"
                        + "Exit code: " + exitCode + "\r\n"
                        + "Diagnostic log: " + logPath,
                        "Kiloview Environment Setup",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Warning);
                }
                installerProcess.Dispose();
                installerProcess = null;
            });
        }

        private void LogButtonClick(object sender, EventArgs eventArgs)
        {
            try
            {
                if (!File.Exists(logPath))
                {
                    MessageBox.Show("No diagnostic log has been created yet.", Text);
                    return;
                }
                Process.Start(new ProcessStartInfo("notepad.exe", SetupLauncher.Quote(logPath)) { UseShellExecute = true });
            }
            catch (Exception exception)
            {
                MessageBox.Show("Could not open the diagnostic log.\r\n\r\n" + exception.Message, Text);
            }
        }
    }
}
