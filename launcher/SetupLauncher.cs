// Copyright (c) 2026 John Lightfoot
// SPDX-License-Identifier: MIT

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Kiloview Environment Setup")]
[assembly: AssemblyDescription("Launcher for KiloLink Server Pro and NDI Environment Setup")]
[assembly: AssemblyCompany("John Lightfoot")]
[assembly: AssemblyProduct("Kiloview Environment Setup")]
[assembly: AssemblyCopyright("Copyright \u00A9 2026 John Lightfoot")]
[assembly: AssemblyVersion("1.2.5.0")]
[assembly: AssemblyFileVersion("1.2.5.0")]

namespace KiloLink.Setup
{
    internal static class SetupLauncher
    {
        internal const string InstallerResourceName = "KiloLink.Setup.Install-KiloLinkSuite.ps1";
        internal const string LicenseResourceName = "KiloLink.Setup.LICENSE";
        internal const string ThirdPartyNoticesResourceName = "KiloLink.Setup.THIRD_PARTY_NOTICES.md";
        internal const string ArtworkResourceName = "KiloLink.Setup.setup-icon.png";
        internal const string EventPrefix = "@@KILOVIEW_EVENT@@";

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

        internal static string ReadEmbeddedText(string resourceName)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resource = assembly.GetManifestResourceStream(resourceName))
            {
                if (resource == null)
                {
                    throw new InvalidOperationException("The embedded resource is missing: " + resourceName);
                }

                using (StreamReader reader = new StreamReader(resource))
                {
                    return reader.ReadToEnd();
                }
            }
        }

        internal static Image LoadArtwork()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream resource = assembly.GetManifestResourceStream(ArtworkResourceName))
            {
                if (resource == null)
                {
                    throw new InvalidOperationException("The embedded setup artwork is missing.");
                }

                using (Image source = Image.FromStream(resource))
                {
                    return new Bitmap(source);
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

    internal static class SetupTheme
    {
        internal static readonly Color Navy = Color.FromArgb(5, 20, 49);
        internal static readonly Color NavyLight = Color.FromArgb(18, 47, 92);
        internal static readonly Color Cyan = Color.FromArgb(0, 214, 238);
        internal static readonly Color Blue = Color.FromArgb(22, 115, 220);
        internal static readonly Color Surface = Color.FromArgb(244, 248, 252);
        internal static readonly Color Track = Color.FromArgb(216, 230, 241);
        internal static readonly Color Text = Color.FromArgb(18, 38, 64);
        internal static readonly Color Muted = Color.FromArgb(83, 105, 129);
        internal static readonly Color Success = Color.FromArgb(92, 190, 68);
        internal static readonly Color Error = Color.FromArgb(205, 61, 61);
    }

    internal sealed class InstallerProgressBar : Control
    {
        private int currentValue;
        private int pulseOffset;

        internal InstallerProgressBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            currentValue = 0;
            pulseOffset = 0;
            Height = 34;
        }

        internal int Value
        {
            get { return currentValue; }
            set
            {
                currentValue = Math.Max(0, Math.Min(100, value));
                Invalidate();
            }
        }

        internal void AdvancePulse()
        {
            pulseOffset = (pulseOffset + 8) % Math.Max(1, Width + 80);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            base.OnPaint(eventArgs);
            Graphics graphics = eventArgs.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF bounds = new RectangleF(1F, 1F, Math.Max(1, Width - 2), Math.Max(1, Height - 2));

            using (GraphicsPath trackPath = RoundedRectangle(bounds, 12F))
            using (SolidBrush trackBrush = new SolidBrush(SetupTheme.Track))
            {
                graphics.FillPath(trackBrush, trackPath);

                float fillWidth = bounds.Width * currentValue / 100F;
                if (fillWidth > 0F)
                {
                    GraphicsState state = graphics.Save();
                    graphics.SetClip(trackPath);
                    RectangleF fillBounds = new RectangleF(bounds.X, bounds.Y, Math.Max(2F, fillWidth), bounds.Height);
                    using (LinearGradientBrush fillBrush = new LinearGradientBrush(
                        fillBounds,
                        SetupTheme.Cyan,
                        SetupTheme.Blue,
                        LinearGradientMode.Horizontal))
                    {
                        graphics.FillRectangle(fillBrush, fillBounds);
                    }

                    float highlightX = bounds.X + pulseOffset - 80F;
                    using (LinearGradientBrush highlight = new LinearGradientBrush(
                        new RectangleF(highlightX, bounds.Y, 80F, bounds.Height),
                        Color.FromArgb(0, Color.White),
                        Color.FromArgb(115, Color.White),
                        LinearGradientMode.Horizontal))
                    {
                        graphics.FillRectangle(highlight, highlightX, bounds.Y, 80F, bounds.Height);
                    }
                    graphics.Restore(state);
                }
            }

            string percentage = currentValue + "%";
            using (Font percentageFont = new Font("Segoe UI Semibold", 9F))
            {
                TextRenderer.DrawText(
                    graphics,
                    percentage,
                    percentageFont,
                    Rectangle.Round(bounds),
                    currentValue >= 45 ? Color.White : SetupTheme.Text,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }

        private static GraphicsPath RoundedRectangle(RectangleF rectangle, float radius)
        {
            float diameter = radius * 2F;
            GraphicsPath path = new GraphicsPath();
            path.AddArc(rectangle.X, rectangle.Y, diameter, diameter, 180F, 90F);
            path.AddArc(rectangle.Right - diameter, rectangle.Y, diameter, diameter, 270F, 90F);
            path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0F, 90F);
            path.AddArc(rectangle.X, rectangle.Bottom - diameter, diameter, diameter, 90F, 90F);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly Button startButton;
        private readonly Button logButton;
        private readonly Button closeButton;
        private readonly Label welcomeStatusLabel;
        private readonly Panel welcomePanel;
        private readonly Panel progressPanel;
        private readonly InstallerProgressBar progressBar;
        private readonly Label activityLabel;
        private readonly Label progressStatusLabel;
        private readonly RichTextBox outputBox;
        private readonly Panel promptPanel;
        private readonly Label promptLabel;
        private readonly TextBox responseBox;
        private readonly Button responseButton;
        private readonly Timer pulseTimer;
        private readonly JavaScriptSerializer eventSerializer;
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
            eventSerializer = new JavaScriptSerializer();

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
            ClientSize = new Size(680, 370);
            Font = new Font("Segoe UI", 9F);
            BackColor = SetupTheme.Surface;
            AutoScaleMode = AutoScaleMode.Dpi;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            FormClosing += SetupFormClosing;

            Panel headerPanel = new Panel();
            headerPanel.Dock = DockStyle.Top;
            headerPanel.Height = 118;
            headerPanel.BackColor = SetupTheme.Navy;

            PictureBox artwork = new PictureBox();
            artwork.Location = new Point(20, 15);
            artwork.Size = new Size(88, 88);
            artwork.SizeMode = PictureBoxSizeMode.Zoom;
            artwork.BackColor = Color.Transparent;
            artwork.Image = SetupLauncher.LoadArtwork();

            Label title = new Label();
            title.Text = "Kiloview Environment Setup";
            title.Font = new Font("Segoe UI Semibold", 19F);
            title.ForeColor = Color.White;
            title.AutoSize = true;
            title.Location = new Point(122, 27);

            Label subtitle = new Label();
            subtitle.Text = "KiloLink Server Pro + NDI environment";
            subtitle.Font = new Font("Segoe UI", 10F);
            subtitle.ForeColor = SetupTheme.Cyan;
            subtitle.AutoSize = true;
            subtitle.Location = new Point(125, 68);

            Label singleFileBadge = new Label();
            singleFileBadge.Text = "SINGLE-FILE SETUP";
            singleFileBadge.Font = new Font("Segoe UI Semibold", 8F);
            singleFileBadge.ForeColor = Color.White;
            singleFileBadge.BackColor = SetupTheme.NavyLight;
            singleFileBadge.AutoSize = true;
            singleFileBadge.Padding = new Padding(9, 5, 9, 5);
            singleFileBadge.Location = new Point(526, 39);
            singleFileBadge.Anchor = AnchorStyles.Top | AnchorStyles.Right;

            headerPanel.Controls.Add(artwork);
            headerPanel.Controls.Add(title);
            headerPanel.Controls.Add(subtitle);
            headerPanel.Controls.Add(singleFileBadge);

            welcomePanel = new Panel();
            welcomePanel.Dock = DockStyle.Fill;
            welcomePanel.BackColor = SetupTheme.Surface;

            Label description = new Label();
            description.Text = "Guided Windows 11 deployment with restart-safe setup, repair, updates,\r\nand diagnostics in one application.";
            description.Font = new Font("Segoe UI", 10F);
            description.ForeColor = SetupTheme.Text;
            description.AutoSize = true;
            description.Location = new Point(31, 27);

            Label helper = new Label();
            helper.Text = "Administrator approval is required. Deployment status remains in this window.";
            helper.ForeColor = SetupTheme.Muted;
            helper.AutoSize = true;
            helper.Location = new Point(33, 77);

            startButton = CreateButton(autoResume ? "Resume setup" : "Start setup", true);
            startButton.Click += StartButtonClick;

            logButton = CreateButton("Diagnostic log", false);
            logButton.Enabled = File.Exists(logPath);
            logButton.Click += LogButtonClick;

            Button licencesButton = CreateButton("Licences", false);
            licencesButton.Click += LicencesButtonClick;

            closeButton = CreateButton("Close", false);
            closeButton.Click += delegate { Close(); };

            TableLayoutPanel buttonPanel = new TableLayoutPanel();
            buttonPanel.Location = new Point(31, 111);
            buttonPanel.Size = new Size(618, 48);
            buttonPanel.ColumnCount = 4;
            buttonPanel.RowCount = 1;
            buttonPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 29F));
            buttonPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 31F));
            buttonPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20F));
            buttonPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20F));
            buttonPanel.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            AddButtonToTable(buttonPanel, startButton, 0, 0, 5);
            AddButtonToTable(buttonPanel, logButton, 1, 5, 5);
            AddButtonToTable(buttonPanel, licencesButton, 2, 5, 5);
            AddButtonToTable(buttonPanel, closeButton, 3, 5, 0);

            welcomeStatusLabel = new Label();
            welcomeStatusLabel.Text = autoResume
                ? "Windows restart detected. Setup is ready to resume."
                : "Ready to begin.";
            welcomeStatusLabel.Font = new Font("Segoe UI Semibold", 9F);
            welcomeStatusLabel.ForeColor = SetupTheme.Blue;
            welcomeStatusLabel.AutoSize = true;
            welcomeStatusLabel.Location = new Point(33, 181);

            Label copyrightLabel = new Label();
            copyrightLabel.Text = "Copyright \u00A9 2026 John Lightfoot  \u2022  MIT licensed application";
            copyrightLabel.ForeColor = SetupTheme.Muted;
            copyrightLabel.AutoSize = true;
            copyrightLabel.Location = new Point(33, 215);

            welcomePanel.Controls.Add(description);
            welcomePanel.Controls.Add(helper);
            welcomePanel.Controls.Add(buttonPanel);
            welcomePanel.Controls.Add(welcomeStatusLabel);
            welcomePanel.Controls.Add(copyrightLabel);

            progressPanel = new Panel();
            progressPanel.Dock = DockStyle.Fill;
            progressPanel.BackColor = SetupTheme.Surface;
            progressPanel.Visible = false;

            activityLabel = new Label();
            activityLabel.Text = "Preparing deployment";
            activityLabel.Font = new Font("Segoe UI Semibold", 15F);
            activityLabel.ForeColor = SetupTheme.Text;
            activityLabel.AutoSize = true;
            activityLabel.Location = new Point(30, 19);

            progressBar = new InstallerProgressBar();
            progressBar.Location = new Point(30, 55);
            progressBar.Size = new Size(800, 34);

            progressStatusLabel = new Label();
            progressStatusLabel.Text = "Starting the deployment engine...";
            progressStatusLabel.ForeColor = SetupTheme.Muted;
            progressStatusLabel.AutoEllipsis = true;
            progressStatusLabel.Location = new Point(32, 99);
            progressStatusLabel.Size = new Size(796, 22);

            Label outputTitle = new Label();
            outputTitle.Text = "INSTALLER ACTIVITY";
            outputTitle.Font = new Font("Segoe UI Semibold", 8F);
            outputTitle.ForeColor = SetupTheme.Blue;
            outputTitle.AutoSize = true;
            outputTitle.Location = new Point(31, 130);

            outputBox = new RichTextBox();
            outputBox.Location = new Point(30, 153);
            outputBox.Size = new Size(800, 234);
            outputBox.ReadOnly = true;
            outputBox.BorderStyle = BorderStyle.None;
            outputBox.BackColor = SetupTheme.Navy;
            outputBox.ForeColor = Color.FromArgb(222, 239, 249);
            outputBox.Font = new Font("Consolas", 9F);
            outputBox.DetectUrls = false;

            promptPanel = new Panel();
            promptPanel.Location = new Point(30, 399);
            promptPanel.Size = new Size(800, 80);
            promptPanel.BackColor = Color.FromArgb(226, 247, 250);

            promptLabel = new Label();
            promptLabel.Text = "Waiting for the installer to request input...";
            promptLabel.Font = new Font("Segoe UI Semibold", 9F);
            promptLabel.ForeColor = SetupTheme.Text;
            promptLabel.AutoEllipsis = true;
            promptLabel.Location = new Point(15, 10);
            promptLabel.Size = new Size(770, 20);

            responseBox = new TextBox();
            responseBox.Location = new Point(16, 39);
            responseBox.Size = new Size(635, 24);
            responseBox.Enabled = false;
            responseBox.KeyDown += ResponseBoxKeyDown;

            responseButton = CreateButton("Continue", true);
            responseButton.Location = new Point(666, 35);
            responseButton.Size = new Size(118, 32);
            responseButton.Enabled = false;
            responseButton.Click += ResponseButtonClick;

            promptPanel.Controls.Add(promptLabel);
            promptPanel.Controls.Add(responseBox);
            promptPanel.Controls.Add(responseButton);

            Button progressLogButton = CreateButton("Open full log", false);
            progressLogButton.Location = new Point(30, 492);
            progressLogButton.Size = new Size(135, 38);
            progressLogButton.Click += LogButtonClick;

            Button progressLicencesButton = CreateButton("Licences", false);
            progressLicencesButton.Location = new Point(175, 492);
            progressLicencesButton.Size = new Size(110, 38);
            progressLicencesButton.Click += LicencesButtonClick;

            Label privacyLabel = new Label();
            privacyLabel.Text = "The deployment engine runs hidden; status and prompts remain in this window.";
            privacyLabel.ForeColor = SetupTheme.Muted;
            privacyLabel.AutoSize = true;
            privacyLabel.Location = new Point(309, 505);

            progressPanel.Controls.Add(activityLabel);
            progressPanel.Controls.Add(progressBar);
            progressPanel.Controls.Add(progressStatusLabel);
            progressPanel.Controls.Add(outputTitle);
            progressPanel.Controls.Add(outputBox);
            progressPanel.Controls.Add(promptPanel);
            progressPanel.Controls.Add(progressLogButton);
            progressPanel.Controls.Add(progressLicencesButton);
            progressPanel.Controls.Add(privacyLabel);

            Controls.Add(welcomePanel);
            Controls.Add(progressPanel);
            Controls.Add(headerPanel);
            AcceptButton = startButton;

            pulseTimer = new Timer();
            pulseTimer.Interval = 90;
            pulseTimer.Tick += delegate { progressBar.AdvancePulse(); };

            if (autoResume)
            {
                Shown += delegate
                {
                    ShowProgressView();
                    BeginInvoke((MethodInvoker)StartInstaller);
                };
            }
        }

        private static Button CreateButton(string text, bool primary)
        {
            Button button = new Button();
            button.Text = text;
            button.FlatStyle = FlatStyle.Flat;
            button.Cursor = Cursors.Hand;
            button.Font = new Font("Segoe UI Semibold", 9F);
            button.BackColor = primary ? SetupTheme.Blue : Color.White;
            button.ForeColor = primary ? Color.White : SetupTheme.Text;
            button.FlatAppearance.BorderColor = primary ? SetupTheme.Blue : Color.FromArgb(179, 201, 218);
            button.FlatAppearance.BorderSize = 1;
            button.UseVisualStyleBackColor = false;
            return button;
        }

        private static void AddButtonToTable(TableLayoutPanel table, Button button, int column, int left, int right)
        {
            button.Dock = DockStyle.Fill;
            button.Margin = new Padding(left, 4, right, 4);
            table.Controls.Add(button, column, 0);
        }

        private void ShowProgressView()
        {
            if (progressPanel.Visible)
            {
                return;
            }

            welcomePanel.Visible = false;
            progressPanel.Visible = true;
            ClientSize = new Size(860, 680);
            CenterToScreen();
            AcceptButton = responseButton;
            pulseTimer.Start();
            AppendOutput("Kiloview Environment Setup started.");
            AppendOutput("The deployment engine is running without a separate console window.");
        }

        private void StartButtonClick(object sender, EventArgs eventArgs)
        {
            ShowProgressView();
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
                startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "
                    + SetupLauncher.Quote(installerPath)
                    + (autoResume ? " -Action Resume -AcceptLicenses" : String.Empty)
                    + " -LauncherMode -LogPath "
                    + SetupLauncher.Quote(logPath);
                // WSL inherits the Windows process directory before applying its
                // own --cd option. ProgramData's protected launcher directory can
                // produce a noisy access-denied chdir warning, so start from the
                // Windows directory and explicitly use / inside every WSL call.
                startInfo.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                startInfo.UseShellExecute = false;
                startInfo.CreateNoWindow = true;
                startInfo.RedirectStandardOutput = true;
                startInfo.RedirectStandardError = true;
                startInfo.RedirectStandardInput = true;
                startInfo.WindowStyle = ProcessWindowStyle.Hidden;

                installerProcess = new Process();
                installerProcess.StartInfo = startInfo;
                installerProcess.EnableRaisingEvents = true;
                installerProcess.OutputDataReceived += InstallerOutputReceived;
                installerProcess.ErrorDataReceived += InstallerErrorReceived;
                installerProcess.Exited += InstallerProcessExited;
                if (!installerProcess.Start())
                {
                    throw new InvalidOperationException("Windows did not start the deployment engine.");
                }

                installerProcess.StandardInput.AutoFlush = true;
                installerProcess.BeginOutputReadLine();
                installerProcess.BeginErrorReadLine();
                activityLabel.Text = autoResume ? "Resuming setup" : "Inspecting this computer";
                progressStatusLabel.Text = autoResume
                    ? "Windows and WSL state are being verified."
                    : "Detecting installed components and available actions.";
            }
            catch (Exception exception)
            {
                Environment.ExitCode = 1;
                pulseTimer.Stop();
                activityLabel.Text = "Setup could not start";
                activityLabel.ForeColor = SetupTheme.Error;
                progressStatusLabel.Text = exception.Message;
                logButton.Enabled = File.Exists(logPath);
                AppendOutput("ERROR: " + exception.Message);
                MessageBox.Show(
                    "Setup could not start.\r\n\r\n" + exception.Message,
                    "Kiloview Environment Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private void InstallerOutputReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data == null || IsDisposed || !IsHandleCreated)
            {
                return;
            }

            try
            {
                BeginInvoke((MethodInvoker)delegate { HandleOutputLine(eventArgs.Data); });
            }
            catch (InvalidOperationException) { }
        }

        private void InstallerErrorReceived(object sender, DataReceivedEventArgs eventArgs)
        {
            if (eventArgs.Data == null || IsDisposed || !IsHandleCreated)
            {
                return;
            }

            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    AppendOutput("ERROR: " + eventArgs.Data);
                });
            }
            catch (InvalidOperationException) { }
        }

        private void HandleOutputLine(string line)
        {
            if (line.StartsWith(SetupLauncher.EventPrefix, StringComparison.Ordinal))
            {
                string json = line.Substring(SetupLauncher.EventPrefix.Length);
                try
                {
                    Dictionary<string, object> payload = eventSerializer.Deserialize<Dictionary<string, object>>(json);
                    string type = GetEventText(payload, "type");
                    if (String.Equals(type, "progress", StringComparison.OrdinalIgnoreCase)
                        || String.Equals(type, "pulse", StringComparison.OrdinalIgnoreCase))
                    {
                        int percent;
                        if (Int32.TryParse(GetEventText(payload, "percent"), out percent))
                        {
                            progressBar.Value = percent;
                        }

                        string activity = GetEventText(payload, "activity");
                        string status = GetEventText(payload, "status");
                        if (!String.IsNullOrWhiteSpace(activity))
                        {
                            activityLabel.Text = activity;
                        }
                        if (!String.IsNullOrWhiteSpace(status))
                        {
                            progressStatusLabel.Text = status;
                        }
                        return;
                    }

                    if (String.Equals(type, "prompt", StringComparison.OrdinalIgnoreCase))
                    {
                        ShowPrompt(GetEventText(payload, "prompt"));
                        return;
                    }

                    if (String.Equals(type, "log", StringComparison.OrdinalIgnoreCase))
                    {
                        AppendOutput(GetEventText(payload, "message"));
                        return;
                    }
                }
                catch (Exception exception)
                {
                    AppendOutput("Could not read installer status: " + exception.Message);
                }
                return;
            }

            AppendOutput(line);
        }

        private static string GetEventText(Dictionary<string, object> payload, string key)
        {
            object value;
            if (payload != null && payload.TryGetValue(key, out value) && value != null)
            {
                return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
            }
            return String.Empty;
        }

        private void ShowPrompt(string prompt)
        {
            promptLabel.Text = String.IsNullOrWhiteSpace(prompt) ? "Installer input required" : prompt;
            progressStatusLabel.Text = "Waiting for your response.";
            responseBox.Text = String.Empty;
            responseBox.Enabled = true;
            responseButton.Enabled = true;
            responseBox.Focus();
        }

        private void ResponseBoxKeyDown(object sender, KeyEventArgs eventArgs)
        {
            if (eventArgs.KeyCode == Keys.Enter && responseButton.Enabled)
            {
                eventArgs.SuppressKeyPress = true;
                SubmitResponse();
            }
        }

        private void ResponseButtonClick(object sender, EventArgs eventArgs)
        {
            SubmitResponse();
        }

        private void SubmitResponse()
        {
            try
            {
                if (installerProcess == null || installerProcess.HasExited)
                {
                    throw new InvalidOperationException("The installer is no longer waiting for input.");
                }

                installerProcess.StandardInput.WriteLine(responseBox.Text);
                AppendOutput("> Response submitted");
                responseBox.Text = String.Empty;
                responseBox.Enabled = false;
                responseButton.Enabled = false;
                promptLabel.Text = "Installer working...";
                progressStatusLabel.Text = "Continuing setup.";
            }
            catch (Exception exception)
            {
                MessageBox.Show("Could not submit the response.\r\n\r\n" + exception.Message, Text);
            }
        }

        private void InstallerProcessExited(object sender, EventArgs eventArgs)
        {
            int exitCode;
            try { exitCode = installerProcess.ExitCode; }
            catch { exitCode = 1; }

            if (IsDisposed || !IsHandleCreated)
            {
                return;
            }

            try
            {
                BeginInvoke((MethodInvoker)delegate
                {
                    pulseTimer.Stop();
                    responseBox.Enabled = false;
                    responseButton.Enabled = false;
                    promptLabel.Text = "No installer input is pending.";
                    logButton.Enabled = File.Exists(logPath);

                    if (exitCode == 0)
                    {
                        progressBar.Value = 100;
                        activityLabel.Text = "Setup finished";
                        activityLabel.ForeColor = SetupTheme.Success;
                        progressStatusLabel.Text = "The deployment operation completed successfully.";
                        AppendOutput("Setup finished successfully.");
                    }
                    else
                    {
                        Environment.ExitCode = exitCode;
                        activityLabel.Text = "Setup needs attention";
                        activityLabel.ForeColor = SetupTheme.Error;
                        progressStatusLabel.Text = "The deployment engine exited with code " + exitCode + ".";
                        AppendOutput("Setup exited with code " + exitCode + ". Open the full log for details.");
                        MessageBox.Show(
                            "The installer exited before completing.\r\n\r\n"
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
            catch (InvalidOperationException) { }
        }

        private void AppendOutput(string line)
        {
            if (String.IsNullOrEmpty(line))
            {
                outputBox.AppendText(Environment.NewLine);
            }
            else
            {
                outputBox.AppendText(line + Environment.NewLine);
            }
            outputBox.SelectionStart = outputBox.TextLength;
            outputBox.ScrollToCaret();
        }

        private void SetupFormClosing(object sender, FormClosingEventArgs eventArgs)
        {
            if (installerProcess != null)
            {
                try
                {
                    if (!installerProcess.HasExited)
                    {
                        eventArgs.Cancel = true;
                        MessageBox.Show(
                            "Setup is still running and may require input in this window.\r\n\r\n"
                            + "Wait for the operation to finish before closing it.",
                            Text,
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Information);
                    }
                }
                catch { }
            }
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

        private void LicencesButtonClick(object sender, EventArgs eventArgs)
        {
            try
            {
                string notices = SetupLauncher.ReadEmbeddedText(SetupLauncher.LicenseResourceName)
                    + "\r\n\r\n"
                    + SetupLauncher.ReadEmbeddedText(SetupLauncher.ThirdPartyNoticesResourceName);

                using (Form noticeForm = new Form())
                {
                    noticeForm.Text = "Licences and third-party notices";
                    noticeForm.StartPosition = FormStartPosition.CenterParent;
                    noticeForm.Size = new Size(720, 560);
                    noticeForm.MinimizeBox = false;
                    noticeForm.MaximizeBox = true;
                    noticeForm.ShowIcon = false;
                    noticeForm.BackColor = SetupTheme.Surface;

                    TextBox noticeText = new TextBox();
                    noticeText.Multiline = true;
                    noticeText.ReadOnly = true;
                    noticeText.ScrollBars = ScrollBars.Both;
                    noticeText.WordWrap = true;
                    noticeText.Dock = DockStyle.Fill;
                    noticeText.Font = new Font("Segoe UI", 9F);
                    noticeText.Text = notices;
                    noticeText.SelectionStart = 0;
                    noticeText.SelectionLength = 0;

                    noticeForm.Controls.Add(noticeText);
                    noticeForm.ShowDialog(this);
                }
            }
            catch (Exception exception)
            {
                MessageBox.Show("Could not display the legal notices.\r\n\r\n" + exception.Message, Text);
            }
        }
    }
}
