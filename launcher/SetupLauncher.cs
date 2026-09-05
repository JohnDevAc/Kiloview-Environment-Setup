// Copyright (c) 2026 John Lightfoot
// SPDX-License-Identifier: MIT

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Kiloview Environment Setup")]
[assembly: AssemblyDescription("Launcher for KiloLink Server Pro and NDI Environment Setup")]
[assembly: AssemblyCompany("John Lightfoot")]
[assembly: AssemblyProduct("Kiloview Environment Setup")]
[assembly: AssemblyCopyright("Copyright \u00A9 2026 John Lightfoot")]
[assembly: AssemblyVersion("1.3.2.0")]
[assembly: AssemblyFileVersion("1.3.2.0")]

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

    internal sealed class NetworkAdapterChoice
    {
        internal string Alias;
        internal string Description;
        internal string Address;
        internal int PrefixLength;
        internal string Gateway;
        internal string PrimaryDns;
        internal string SecondaryDns;
        internal bool Dhcp;
        internal bool Wired;
        internal bool Connected;

        public override string ToString()
        {
            string connection = Connected ? "connected" : "disconnected";
            string medium = Wired ? "Ethernet" : "Wi-Fi";
            string address = String.IsNullOrWhiteSpace(Address) ? "no IPv4 address" : Address;
            string assignment = Dhcp ? "DHCP" : "static/manual";
            return String.Format(
                "{0} — {1} ({2}, {3}, {4})",
                Alias,
                address,
                medium,
                assignment,
                connection);
        }
    }

    internal sealed class SetupForm : Form
    {
        private enum LauncherView
        {
            Network,
            Welcome,
            Progress
        }

        private const int WmDpiChanged = 0x02E0;
        private const int NetworkConfigurationTimeoutMilliseconds = 120000;
        private static readonly Size NetworkLogicalClientSize = new Size(760, 620);
        private static readonly Size WelcomeLogicalClientSize = new Size(680, 370);
        private static readonly Size ProgressLogicalClientSize = new Size(860, 680);
        private static readonly Size NetworkLogicalContentSize = new Size(740, 500);
        private static readonly Size ProgressLogicalContentSize = new Size(850, 550);

        private readonly Panel networkPanel;
        private readonly ComboBox networkAdapterBox;
        private readonly TextBox ipAddressBox;
        private readonly TextBox prefixLengthBox;
        private readonly TextBox gatewayBox;
        private readonly TextBox primaryDnsBox;
        private readonly TextBox secondaryDnsBox;
        private readonly Button applyNetworkButton;
        private readonly Button refreshNetworkButton;
        private readonly Button skipNetworkButton;
        private readonly Label networkAdapterDetailsLabel;
        private readonly Label networkStatusLabel;
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
        private LauncherView currentView;
        private bool networkConfigurationInProgress;
        private string preferredInterfaceAlias;
        private string preferredIpAddress;
        private bool progressViewVisible;
        private string operationOutcome = "Idle";
        private string operationMessage = "No deployment operation was performed.";

        [DllImport("user32.dll")]
        private static extern uint GetDpiForWindow(IntPtr windowHandle);

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
            currentView = autoResume ? LauncherView.Welcome : LauncherView.Network;

            Text = "Kiloview Environment Setup";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = autoResume ? WelcomeLogicalClientSize : NetworkLogicalClientSize;
            Font = new Font("Segoe UI", 9F);
            BackColor = SetupTheme.Surface;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
            FormClosing += SetupFormClosing;

            Panel headerPanel = new Panel();
            headerPanel.Dock = DockStyle.Top;
            headerPanel.Size = new Size(WelcomeLogicalClientSize.Width, 118);
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

            networkPanel = new Panel();
            networkPanel.Dock = DockStyle.Fill;
            networkPanel.BackColor = SetupTheme.Surface;
            networkPanel.AutoScroll = true;
            networkPanel.Visible = !autoResume;

            Label networkTitle = new Label();
            networkTitle.Text = "Set a static IP address";
            networkTitle.Font = new Font("Segoe UI Semibold", 15F);
            networkTitle.ForeColor = SetupTheme.Text;
            networkTitle.AutoSize = true;
            networkTitle.Location = new Point(30, 17);

            Label networkIntro = new Label();
            networkIntro.Text = "Choose the physical network adapter this server will use. Current values are prefilled\r\nso its existing address can be made static without guessing.";
            networkIntro.Font = new Font("Segoe UI", 9.5F);
            networkIntro.ForeColor = SetupTheme.Muted;
            networkIntro.AutoSize = true;
            networkIntro.Location = new Point(32, 51);

            Label adapterLabel = CreateFieldLabel("NETWORK ADAPTER", 32, 105);

            networkAdapterBox = new ComboBox();
            networkAdapterBox.DropDownStyle = ComboBoxStyle.DropDownList;
            networkAdapterBox.Location = new Point(32, 126);
            networkAdapterBox.Size = new Size(592, 28);
            networkAdapterBox.Font = new Font("Segoe UI", 9F);
            networkAdapterBox.SelectedIndexChanged += NetworkAdapterSelectionChanged;

            refreshNetworkButton = CreateButton("Refresh", false);
            refreshNetworkButton.Location = new Point(636, 123);
            refreshNetworkButton.Size = new Size(92, 32);
            refreshNetworkButton.Click += delegate { LoadNetworkAdapters(); };

            networkAdapterDetailsLabel = new Label();
            networkAdapterDetailsLabel.Text = "Detecting physical Ethernet and Wi-Fi adapters...";
            networkAdapterDetailsLabel.ForeColor = SetupTheme.Muted;
            networkAdapterDetailsLabel.AutoEllipsis = true;
            networkAdapterDetailsLabel.Location = new Point(34, 161);
            networkAdapterDetailsLabel.Size = new Size(694, 20);

            Label ipAddressLabel = CreateFieldLabel("STATIC IPV4 ADDRESS", 32, 193);
            Label prefixLabel = CreateFieldLabel("PREFIX LENGTH", 270, 193);
            Label gatewayLabel = CreateFieldLabel("DEFAULT GATEWAY", 398, 193);

            ipAddressBox = CreateNetworkTextBox(32, 214, 220);
            prefixLengthBox = CreateNetworkTextBox(270, 214, 110);
            gatewayBox = CreateNetworkTextBox(398, 214, 330);

            Label primaryDnsLabel = CreateFieldLabel("PRIMARY DNS (OPTIONAL)", 32, 263);
            Label secondaryDnsLabel = CreateFieldLabel("SECONDARY DNS (OPTIONAL)", 398, 263);

            primaryDnsBox = CreateNetworkTextBox(32, 284, 348);
            secondaryDnsBox = CreateNetworkTextBox(398, 284, 330);

            Label networkGuidance = new Label();
            networkGuidance.Text = "Reserve or exclude this address in DHCP first. Applying it may briefly interrupt this PC's network connection.";
            networkGuidance.ForeColor = SetupTheme.Muted;
            networkGuidance.AutoSize = true;
            networkGuidance.Location = new Point(34, 327);

            applyNetworkButton = CreateButton("Apply static IP and continue", true);
            applyNetworkButton.Location = new Point(32, 365);
            applyNetworkButton.Size = new Size(300, 44);
            applyNetworkButton.Enabled = false;
            applyNetworkButton.Click += ApplyNetworkButtonClick;

            skipNetworkButton = CreateButton("Skip for now", false);
            skipNetworkButton.Location = new Point(344, 365);
            skipNetworkButton.Size = new Size(200, 44);
            skipNetworkButton.Click += SkipNetworkButtonClick;

            Button networkCloseButton = CreateButton("Close", false);
            networkCloseButton.Location = new Point(556, 365);
            networkCloseButton.Size = new Size(172, 44);
            networkCloseButton.Click += delegate { Close(); };

            networkStatusLabel = new Label();
            networkStatusLabel.Text = "Select the adapter that will carry KiloLink and NDI traffic.";
            networkStatusLabel.Font = new Font("Segoe UI Semibold", 9F);
            networkStatusLabel.ForeColor = SetupTheme.Blue;
            networkStatusLabel.AutoEllipsis = true;
            networkStatusLabel.Location = new Point(34, 426);
            networkStatusLabel.Size = new Size(694, 22);

            Label serverWarningLabel = new Label();
            serverWarningLabel.Text = "This computer will operate as a server. A changing DHCP address can make its services unreachable.";
            serverWarningLabel.ForeColor = SetupTheme.Error;
            serverWarningLabel.AutoSize = true;
            serverWarningLabel.Location = new Point(34, 458);

            networkPanel.Controls.Add(networkTitle);
            networkPanel.Controls.Add(networkIntro);
            networkPanel.Controls.Add(adapterLabel);
            networkPanel.Controls.Add(networkAdapterBox);
            networkPanel.Controls.Add(refreshNetworkButton);
            networkPanel.Controls.Add(networkAdapterDetailsLabel);
            networkPanel.Controls.Add(ipAddressLabel);
            networkPanel.Controls.Add(prefixLabel);
            networkPanel.Controls.Add(gatewayLabel);
            networkPanel.Controls.Add(ipAddressBox);
            networkPanel.Controls.Add(prefixLengthBox);
            networkPanel.Controls.Add(gatewayBox);
            networkPanel.Controls.Add(primaryDnsLabel);
            networkPanel.Controls.Add(secondaryDnsLabel);
            networkPanel.Controls.Add(primaryDnsBox);
            networkPanel.Controls.Add(secondaryDnsBox);
            networkPanel.Controls.Add(networkGuidance);
            networkPanel.Controls.Add(applyNetworkButton);
            networkPanel.Controls.Add(skipNetworkButton);
            networkPanel.Controls.Add(networkCloseButton);
            networkPanel.Controls.Add(networkStatusLabel);
            networkPanel.Controls.Add(serverWarningLabel);

            welcomePanel = new Panel();
            welcomePanel.Dock = DockStyle.Fill;
            welcomePanel.BackColor = SetupTheme.Surface;
            welcomePanel.AutoScroll = true;
            welcomePanel.Visible = autoResume;

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
            progressPanel.AutoScroll = true;
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

            Controls.Add(networkPanel);
            Controls.Add(welcomePanel);
            Controls.Add(progressPanel);
            Controls.Add(headerPanel);
            AcceptButton = autoResume ? startButton : applyNetworkButton;

            pulseTimer = new Timer();
            pulseTimer.Interval = 90;
            pulseTimer.Tick += delegate { progressBar.AdvancePulse(); };

            Shown += SetupFormShown;

            if (autoResume)
            {
                Shown += delegate
                {
                    ShowProgressView();
                    BeginInvoke((MethodInvoker)StartInstaller);
                };
            }
            else
            {
                Shown += delegate
                {
                    BeginInvoke((MethodInvoker)LoadNetworkAdapters);
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

        private static Label CreateFieldLabel(string text, int x, int y)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = new Font("Segoe UI Semibold", 8F);
            label.ForeColor = SetupTheme.Blue;
            label.AutoSize = true;
            label.Location = new Point(x, y);
            return label;
        }

        private static TextBox CreateNetworkTextBox(int x, int y, int width)
        {
            TextBox textBox = new TextBox();
            textBox.Location = new Point(x, y);
            textBox.Size = new Size(width, 25);
            textBox.Font = new Font("Segoe UI", 9.5F);
            return textBox;
        }

        private static bool IsPhysicalNetworkType(NetworkInterfaceType type)
        {
            return type == NetworkInterfaceType.Ethernet
                || type == NetworkInterfaceType.GigabitEthernet
                || type == NetworkInterfaceType.FastEthernetFx
                || type == NetworkInterfaceType.FastEthernetT
                || type == NetworkInterfaceType.Wireless80211;
        }

        private static bool IsExcludedNetworkAdapter(NetworkInterface adapter)
        {
            string identity = (adapter.Name + " " + adapter.Description).ToLowerInvariant();
            string[] excludedTerms =
            {
                "virtual", "hyper-v", "vethernet", "wsl", "docker", "loopback",
                "vpn", "tap", "tunnel", "wireguard", "default switch"
            };
            foreach (string term in excludedTerms)
            {
                if (identity.Contains(term))
                {
                    return true;
                }
            }
            return false;
        }

        private static int PrefixLengthFromMask(IPAddress mask)
        {
            if (mask == null)
            {
                return 24;
            }

            int prefix = 0;
            bool zeroSeen = false;
            foreach (byte value in mask.GetAddressBytes())
            {
                for (int bit = 7; bit >= 0; bit--)
                {
                    bool set = (value & (1 << bit)) != 0;
                    if (set && zeroSeen)
                    {
                        return 24;
                    }
                    if (set)
                    {
                        prefix++;
                    }
                    else
                    {
                        zeroSeen = true;
                    }
                }
            }
            return prefix;
        }

        private static List<NetworkAdapterChoice> GetNetworkAdapterChoices()
        {
            List<NetworkAdapterChoice> choices = new List<NetworkAdapterChoice>();
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (!IsPhysicalNetworkType(adapter.NetworkInterfaceType)
                    || IsExcludedNetworkAdapter(adapter))
                {
                    continue;
                }

                try
                {
                    IPInterfaceProperties properties = adapter.GetIPProperties();
                    UnicastIPAddressInformation selectedAddress = null;
                    foreach (UnicastIPAddressInformation address in properties.UnicastAddresses)
                    {
                        if (address.Address.AddressFamily != AddressFamily.InterNetwork
                            || IPAddress.IsLoopback(address.Address))
                        {
                            continue;
                        }
                        byte[] addressBytes = address.Address.GetAddressBytes();
                        if (addressBytes[0] == 169 && addressBytes[1] == 254)
                        {
                            continue;
                        }
                        selectedAddress = address;
                        break;
                    }

                    string gateway = String.Empty;
                    foreach (GatewayIPAddressInformation gatewayAddress in properties.GatewayAddresses)
                    {
                        if (gatewayAddress.Address.AddressFamily == AddressFamily.InterNetwork)
                        {
                            gateway = gatewayAddress.Address.ToString();
                            break;
                        }
                    }

                    List<string> dns = new List<string>();
                    foreach (IPAddress dnsAddress in properties.DnsAddresses)
                    {
                        if (dnsAddress.AddressFamily == AddressFamily.InterNetwork
                            && !IPAddress.IsLoopback(dnsAddress))
                        {
                            dns.Add(dnsAddress.ToString());
                        }
                    }

                    bool dhcp = false;
                    try
                    {
                        IPv4InterfaceProperties ipv4 = properties.GetIPv4Properties();
                        dhcp = ipv4 != null && ipv4.IsDhcpEnabled;
                    }
                    catch (NetworkInformationException) { }

                    choices.Add(new NetworkAdapterChoice
                    {
                        Alias = adapter.Name,
                        Description = adapter.Description,
                        Address = selectedAddress == null ? String.Empty : selectedAddress.Address.ToString(),
                        PrefixLength = selectedAddress == null
                            ? 24
                            : PrefixLengthFromMask(selectedAddress.IPv4Mask),
                        Gateway = gateway,
                        PrimaryDns = dns.Count > 0 ? dns[0] : String.Empty,
                        SecondaryDns = dns.Count > 1 ? dns[1] : String.Empty,
                        Dhcp = dhcp,
                        Wired = adapter.NetworkInterfaceType != NetworkInterfaceType.Wireless80211,
                        Connected = adapter.OperationalStatus == OperationalStatus.Up
                    });
                }
                catch (NetworkInformationException) { }
            }

            choices.Sort(delegate(NetworkAdapterChoice left, NetworkAdapterChoice right)
            {
                int result = right.Connected.CompareTo(left.Connected);
                if (result != 0) { return result; }
                result = right.Wired.CompareTo(left.Wired);
                if (result != 0) { return result; }
                return StringComparer.OrdinalIgnoreCase.Compare(left.Alias, right.Alias);
            });
            return choices;
        }

        private void LoadNetworkAdapters()
        {
            if (networkConfigurationInProgress)
            {
                return;
            }

            NetworkAdapterChoice previous = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            string previousAlias = previous == null ? String.Empty : previous.Alias;
            List<NetworkAdapterChoice> choices = GetNetworkAdapterChoices();

            networkAdapterBox.BeginUpdate();
            try
            {
                networkAdapterBox.Items.Clear();
                foreach (NetworkAdapterChoice choice in choices)
                {
                    networkAdapterBox.Items.Add(choice);
                }
            }
            finally
            {
                networkAdapterBox.EndUpdate();
            }

            if (choices.Count == 0)
            {
                applyNetworkButton.Enabled = false;
                networkAdapterDetailsLabel.Text = "No physical Ethernet or Wi-Fi adapter was detected.";
                networkStatusLabel.Text = "Connect or enable a network adapter, then choose Refresh.";
                networkStatusLabel.ForeColor = SetupTheme.Error;
                return;
            }

            int selectedIndex = 0;
            for (int index = 0; index < choices.Count; index++)
            {
                if (!String.IsNullOrWhiteSpace(previousAlias)
                    && String.Equals(choices[index].Alias, previousAlias, StringComparison.OrdinalIgnoreCase))
                {
                    selectedIndex = index;
                    break;
                }
            }
            networkAdapterBox.SelectedIndex = selectedIndex;
            networkStatusLabel.Text = "Review the values, then apply a static address to the selected adapter.";
            networkStatusLabel.ForeColor = SetupTheme.Blue;
        }

        private void NetworkAdapterSelectionChanged(object sender, EventArgs eventArgs)
        {
            NetworkAdapterChoice choice = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            if (choice == null)
            {
                applyNetworkButton.Enabled = false;
                return;
            }

            ipAddressBox.Text = choice.Address;
            prefixLengthBox.Text = choice.PrefixLength.ToString();
            gatewayBox.Text = choice.Gateway;
            primaryDnsBox.Text = choice.PrimaryDns;
            secondaryDnsBox.Text = choice.SecondaryDns;
            networkAdapterDetailsLabel.Text = choice.Description
                + " — "
                + (choice.Dhcp ? "currently using DHCP" : "currently static/manual")
                + (choice.Connected ? String.Empty : " — adapter is disconnected");
            applyNetworkButton.Text = choice.Dhcp
                ? "Make this address static and continue"
                : "Confirm static address and continue";
            applyNetworkButton.Enabled = !networkConfigurationInProgress;
        }

        private static bool TryParseIpv4(string text, bool required, out string normalized)
        {
            normalized = String.Empty;
            if (String.IsNullOrWhiteSpace(text))
            {
                return !required;
            }

            IPAddress address;
            if (!IPAddress.TryParse(text.Trim(), out address)
                || address.AddressFamily != AddressFamily.InterNetwork)
            {
                return false;
            }
            normalized = address.ToString();
            return true;
        }

        private static uint Ipv4Number(string address)
        {
            byte[] bytes = IPAddress.Parse(address).GetAddressBytes();
            return ((uint)bytes[0] << 24)
                | ((uint)bytes[1] << 16)
                | ((uint)bytes[2] << 8)
                | bytes[3];
        }

        private static bool IsSameSubnet(string first, string second, int prefixLength)
        {
            if (prefixLength >= 31)
            {
                return true;
            }
            uint mask = prefixLength == 0
                ? 0
                : UInt32.MaxValue << (32 - prefixLength);
            return (Ipv4Number(first) & mask) == (Ipv4Number(second) & mask);
        }

        private static bool IsUsableServerAddress(string address, int prefixLength)
        {
            byte[] bytes = IPAddress.Parse(address).GetAddressBytes();
            if (bytes[0] == 0
                || bytes[0] == 127
                || bytes[0] >= 224
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 255 && bytes[1] == 255 && bytes[2] == 255 && bytes[3] == 255))
            {
                return false;
            }

            if (prefixLength <= 30)
            {
                uint value = Ipv4Number(address);
                uint mask = UInt32.MaxValue << (32 - prefixLength);
                uint host = value & ~mask;
                if (host == 0 || host == ~mask)
                {
                    return false;
                }
            }
            return true;
        }

        private bool TryReadNetworkSettings(
            out string address,
            out int prefixLength,
            out string gateway,
            out string primaryDns,
            out string secondaryDns,
            out string error)
        {
            address = String.Empty;
            gateway = String.Empty;
            primaryDns = String.Empty;
            secondaryDns = String.Empty;
            prefixLength = 0;
            error = String.Empty;

            if (!TryParseIpv4(ipAddressBox.Text, true, out address))
            {
                error = "Enter a valid IPv4 address, for example 192.168.1.50.";
                return false;
            }
            if (!Int32.TryParse(prefixLengthBox.Text.Trim(), out prefixLength)
                || prefixLength < 1
                || prefixLength > 32)
            {
                error = "Enter a prefix length between 1 and 32. Most local networks use 24.";
                return false;
            }
            if (!IsUsableServerAddress(address, prefixLength))
            {
                error = "The IPv4 address is not a usable host address for the selected prefix.";
                return false;
            }
            if (!TryParseIpv4(gatewayBox.Text, false, out gateway))
            {
                error = "Enter a valid default gateway or leave it blank for an isolated network.";
                return false;
            }
            if (!String.IsNullOrWhiteSpace(gateway)
                && (!IsSameSubnet(address, gateway, prefixLength)
                    || String.Equals(address, gateway, StringComparison.Ordinal)))
            {
                error = "The default gateway must be a different address in the same subnet.";
                return false;
            }
            if (!TryParseIpv4(primaryDnsBox.Text, false, out primaryDns))
            {
                error = "Enter a valid primary DNS server or leave it blank.";
                return false;
            }
            if (!TryParseIpv4(secondaryDnsBox.Text, false, out secondaryDns))
            {
                error = "Enter a valid secondary DNS server or leave it blank.";
                return false;
            }
            if (!String.IsNullOrWhiteSpace(secondaryDns)
                && String.IsNullOrWhiteSpace(primaryDns))
            {
                error = "Enter a primary DNS server before adding a secondary DNS server.";
                return false;
            }
            return true;
        }

        private static string PowerShellLiteral(string value)
        {
            return "'" + (value ?? String.Empty).Replace("'", "''") + "'";
        }

        private static string BuildStaticNetworkScript(
            string adapterAlias,
            string address,
            int prefixLength,
            string gateway,
            string primaryDns,
            string secondaryDns)
        {
            List<string> dns = new List<string>();
            if (!String.IsNullOrWhiteSpace(primaryDns)) { dns.Add(PowerShellLiteral(primaryDns)); }
            if (!String.IsNullOrWhiteSpace(secondaryDns)) { dns.Add(PowerShellLiteral(secondaryDns)); }

            StringBuilder script = new StringBuilder();
            script.AppendLine("$ErrorActionPreference = 'Stop'");
            script.AppendLine("$ProgressPreference = 'SilentlyContinue'");
            script.AppendLine("$adapter = Get-NetAdapter -Name " + PowerShellLiteral(adapterAlias) + " -ErrorAction Stop");
            script.AppendLine("$index = [uint32]$adapter.ifIndex");
            script.AppendLine("$previousInterface = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop");
            script.AppendLine("$previousDhcp = [string]$previousInterface.Dhcp");
            script.AppendLine("$previousAddresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object IPAddress, PrefixLength)");
            script.AppendLine("$previousRoutes = @(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object NextHop, RouteMetric)");
            script.AppendLine("$previousDns = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)");
            script.AppendLine("function Clear-CurrentIpv4 {");
            script.AppendLine("  Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue");
            script.AppendLine("  Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue");
            script.AppendLine("}");
            script.AppendLine("try {");
            script.AppendLine("  Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop");
            script.AppendLine("  Clear-CurrentIpv4");
            script.Append("  $parameters = @{ InterfaceIndex = $index; AddressFamily = 'IPv4'; IPAddress = ");
            script.Append(PowerShellLiteral(address));
            script.Append("; PrefixLength = ");
            script.Append(prefixLength);
            script.AppendLine("; ErrorAction = 'Stop' }");
            if (!String.IsNullOrWhiteSpace(gateway))
            {
                script.AppendLine("  $parameters.DefaultGateway = " + PowerShellLiteral(gateway));
            }
            script.AppendLine("  New-NetIPAddress @parameters | Out-Null");
            if (dns.Count > 0)
            {
                script.AppendLine("  $dns = @(" + String.Join(", ", dns.ToArray()) + ")");
                script.AppendLine("  Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $dns -ErrorAction Stop");
            }
            else
            {
                script.AppendLine("  Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop");
            }
            script.AppendLine("  $addressDeadline = (Get-Date).AddSeconds(30)");
            script.AppendLine("  do {");
            script.AppendLine("    $configured = Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress " + PowerShellLiteral(address) + " -ErrorAction SilentlyContinue");
            script.AppendLine("    if ($configured -and $configured.AddressState -eq 'Duplicate') { throw 'The requested IPv4 address is already in use on this network. Choose a unique address.' }");
            script.AppendLine("    if ($configured -and $configured.AddressState -eq 'Preferred') { break }");
            script.AppendLine("    Start-Sleep -Milliseconds 250");
            script.AppendLine("  } while ((Get-Date) -lt $addressDeadline)");
            script.AppendLine("  if (-not $configured -or $configured.AddressState -ne 'Preferred') { throw 'The static IPv4 address did not become usable within 30 seconds. Check the adapter connection and address.' }");
            script.AppendLine("  Write-Output ('Configured {0} on {1}' -f $configured.IPAddress, $adapter.Name)");
            script.AppendLine("} catch {");
            script.AppendLine("  $configurationFailure = $_");
            script.AppendLine("  try {");
            script.AppendLine("    Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue");
            script.AppendLine("    Clear-CurrentIpv4");
            script.AppendLine("    if ($previousDhcp -eq 'Enabled') {");
            script.AppendLine("      Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop");
            script.AppendLine("      Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue");
            script.AppendLine("    } else {");
            script.AppendLine("      foreach ($oldAddress in $previousAddresses) {");
            script.AppendLine("        New-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -IPAddress $oldAddress.IPAddress -PrefixLength $oldAddress.PrefixLength -ErrorAction Stop | Out-Null");
            script.AppendLine("      }");
            script.AppendLine("      foreach ($oldRoute in $previousRoutes) {");
            script.AppendLine("        if ($oldRoute.NextHop -and $oldRoute.NextHop -ne '0.0.0.0') {");
            script.AppendLine("          New-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop $oldRoute.NextHop -RouteMetric $oldRoute.RouteMetric -ErrorAction SilentlyContinue | Out-Null");
            script.AppendLine("        }");
            script.AppendLine("      }");
            script.AppendLine("      if ($previousDns.Count -gt 0) {");
            script.AppendLine("        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $previousDns -ErrorAction SilentlyContinue");
            script.AppendLine("      } else {");
            script.AppendLine("        Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction SilentlyContinue");
            script.AppendLine("      }");
            script.AppendLine("    }");
            script.AppendLine("  } catch { }");
            script.AppendLine("  throw $configurationFailure");
            script.AppendLine("}");
            return script.ToString();
        }

        private static string RunHiddenPowerShell(string script)
        {
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
            startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "
                + Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            startInfo.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;

            using (Process process = new Process())
            {
                process.StartInfo = startInfo;
                StringBuilder output = new StringBuilder();
                StringBuilder error = new StringBuilder();
                object outputLock = new object();
                object errorLock = new object();
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        lock (outputLock)
                        {
                            output.AppendLine(eventArgs.Data);
                        }
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                {
                    if (eventArgs.Data != null)
                    {
                        lock (errorLock)
                        {
                            error.AppendLine(eventArgs.Data);
                        }
                    }
                };
                if (!process.Start())
                {
                    throw new InvalidOperationException("Windows did not start the network configuration task.");
                }

                // Both redirected pipes must be drained concurrently. Reading
                // one stream to completion before the other can deadlock when
                // PowerShell or a network cmdlet fills the unattended pipe.
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();

                if (!process.WaitForExit(NetworkConfigurationTimeoutMilliseconds))
                {
                    try
                    {
                        process.Kill();
                        process.WaitForExit(5000);
                    }
                    catch { }
                    throw new InvalidOperationException(
                        "Windows did not finish applying the static network settings within two minutes. "
                        + "The worker was stopped. Choose Refresh and review the adapter before trying again.");
                }

                // The parameterless wait lets the asynchronous stream readers
                // deliver any final lines after the process handle is signaled.
                process.WaitForExit();
                string outputText;
                string errorText;
                lock (outputLock) { outputText = output.ToString().Trim(); }
                lock (errorLock) { errorText = error.ToString().Trim(); }
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        String.IsNullOrWhiteSpace(errorText)
                            ? "Windows rejected the static network configuration."
                            : errorText);
                }
                return outputText;
            }
        }

        private void SetNetworkControlsEnabled(bool enabled)
        {
            networkAdapterBox.Enabled = enabled;
            ipAddressBox.Enabled = enabled;
            prefixLengthBox.Enabled = enabled;
            gatewayBox.Enabled = enabled;
            primaryDnsBox.Enabled = enabled;
            secondaryDnsBox.Enabled = enabled;
            refreshNetworkButton.Enabled = enabled;
            skipNetworkButton.Enabled = enabled;
            applyNetworkButton.Enabled = enabled && networkAdapterBox.SelectedItem != null;
        }

        private void ApplyNetworkButtonClick(object sender, EventArgs eventArgs)
        {
            NetworkAdapterChoice choice = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            if (choice == null)
            {
                MessageBox.Show("Choose a physical network adapter first.", Text);
                return;
            }

            string address;
            int prefixLength;
            string gateway;
            string primaryDns;
            string secondaryDns;
            string validationError;
            if (!TryReadNetworkSettings(
                out address,
                out prefixLength,
                out gateway,
                out primaryDns,
                out secondaryDns,
                out validationError))
            {
                networkStatusLabel.Text = validationError;
                networkStatusLabel.ForeColor = SetupTheme.Error;
                MessageBox.Show(
                    validationError,
                    "Check the static IP settings",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Warning);
                return;
            }

            string summary = String.Format(
                "Adapter: {0}\r\nStatic IPv4: {1}/{2}\r\nGateway: {3}\r\nDNS: {4}\r\n\r\n"
                + "This disables DHCP on the selected adapter and may briefly interrupt the network. Continue?",
                choice.Alias,
                address,
                prefixLength,
                String.IsNullOrWhiteSpace(gateway) ? "(none)" : gateway,
                String.IsNullOrWhiteSpace(primaryDns)
                    ? "(default)"
                    : primaryDns + (String.IsNullOrWhiteSpace(secondaryDns) ? String.Empty : ", " + secondaryDns));
            if (MessageBox.Show(
                summary,
                "Apply static server address",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2) != DialogResult.Yes)
            {
                return;
            }

            networkConfigurationInProgress = true;
            SetNetworkControlsEnabled(false);
            networkStatusLabel.Text = "Applying the static IPv4 configuration...";
            networkStatusLabel.ForeColor = SetupTheme.Blue;

            string adapterAlias = choice.Alias;
            string script = BuildStaticNetworkScript(
                adapterAlias,
                address,
                prefixLength,
                gateway,
                primaryDns,
                secondaryDns);
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                string result = String.Empty;
                Exception failure = null;
                try
                {
                    result = RunHiddenPowerShell(script);
                }
                catch (Exception exception)
                {
                    failure = exception;
                }

                if (IsDisposed || !IsHandleCreated)
                {
                    return;
                }
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        networkConfigurationInProgress = false;
                        SetNetworkControlsEnabled(true);
                        if (failure != null)
                        {
                            networkStatusLabel.Text = "Static IP configuration failed. Review the settings and try again.";
                            networkStatusLabel.ForeColor = SetupTheme.Error;
                            MessageBox.Show(
                                "The static IP address could not be applied.\r\n\r\n" + failure.Message,
                                "Network configuration failed",
                                MessageBoxButtons.OK,
                                MessageBoxIcon.Error);
                            return;
                        }

                        preferredInterfaceAlias = adapterAlias;
                        preferredIpAddress = address;
                        ShowWelcomeView(
                            String.IsNullOrWhiteSpace(result)
                                ? "Static IPv4 configured. Ready to begin setup."
                                : result + ". Ready to begin setup.");
                    });
                }
                catch (InvalidOperationException) { }
            });
        }

        private void SkipNetworkButtonClick(object sender, EventArgs eventArgs)
        {
            NetworkAdapterChoice choice = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            string selected = choice == null
                ? "No adapter is currently selected."
                : "Selected adapter: " + choice.Alias
                    + (String.IsNullOrWhiteSpace(choice.Address)
                        ? String.Empty
                        : " (" + choice.Address + ")");
            string warning = "This computer will run KiloLink and NDI services as a server.\r\n\r\n"
                + "If DHCP later changes its address, devices, shortcuts, and Discovery Server endpoints may stop working.\r\n\r\n"
                + selected
                + "\r\n\r\nOnly skip if the adapter already has a stable static address or a DHCP reservation. Skip anyway?";
            if (MessageBox.Show(
                warning,
                "Static IP strongly recommended",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2) != DialogResult.Yes)
            {
                return;
            }

            if (choice != null)
            {
                preferredInterfaceAlias = choice.Alias;
                preferredIpAddress = choice.Address;
            }
            ShowWelcomeView("Static IP setup was skipped. Confirm this server has a stable address before deployment.");
        }

        private void ShowWelcomeView(string status)
        {
            currentView = LauncherView.Welcome;
            networkPanel.Visible = false;
            progressPanel.Visible = false;
            welcomePanel.Visible = true;
            welcomeStatusLabel.Text = status;
            welcomeStatusLabel.ForeColor = SetupTheme.Blue;
            AcceptButton = startButton;
            ApplyViewClientSize(true);
        }

        private static void AddButtonToTable(TableLayoutPanel table, Button button, int column, int left, int right)
        {
            button.Dock = DockStyle.Fill;
            button.Margin = new Padding(left, 4, right, 4);
            table.Controls.Add(button, column, 0);
        }

        private void SetupFormShown(object sender, EventArgs eventArgs)
        {
            ApplyViewClientSize(false);
        }

        private float CurrentDpiScale()
        {
            float dpi = 96F;
            if (IsHandleCreated)
            {
                try
                {
                    uint windowDpi = GetDpiForWindow(Handle);
                    if (windowDpi > 0)
                    {
                        dpi = windowDpi;
                    }
                }
                catch (EntryPointNotFoundException)
                {
                    using (Graphics graphics = CreateGraphics())
                    {
                        dpi = graphics.DpiX;
                    }
                }
            }

            return Math.Max(1F, dpi / 96F);
        }

        private Size ScaleLogicalSize(Size logicalSize)
        {
            float scale = CurrentDpiScale();
            return new Size(
                Math.Max(1, (int)Math.Ceiling(logicalSize.Width * scale)),
                Math.Max(1, (int)Math.Ceiling(logicalSize.Height * scale)));
        }

        private void ApplyViewClientSize(bool centerOnCurrentScreen)
        {
            Size logicalSize;
            if (currentView == LauncherView.Network)
            {
                logicalSize = NetworkLogicalClientSize;
            }
            else if (currentView == LauncherView.Progress)
            {
                logicalSize = ProgressLogicalClientSize;
            }
            else
            {
                logicalSize = WelcomeLogicalClientSize;
            }
            Size requestedClientSize = ScaleLogicalSize(logicalSize);

            Screen screen = Screen.FromControl(this);
            Rectangle workingArea = screen.WorkingArea;
            Size nonClientSize = new Size(
                Math.Max(0, Width - ClientSize.Width),
                Math.Max(0, Height - ClientSize.Height));
            int margin = Math.Max(8, (int)Math.Ceiling(16F * CurrentDpiScale()));
            int maximumClientWidth = Math.Max(
                1,
                workingArea.Width - nonClientSize.Width - (margin * 2));
            int maximumClientHeight = Math.Max(
                1,
                workingArea.Height - nonClientSize.Height - (margin * 2));

            ClientSize = new Size(
                Math.Min(requestedClientSize.Width, maximumClientWidth),
                Math.Min(requestedClientSize.Height, maximumClientHeight));

            networkPanel.AutoScrollMinSize = ScaleLogicalSize(NetworkLogicalContentSize);
            progressPanel.AutoScrollMinSize = ScaleLogicalSize(ProgressLogicalContentSize);

            if (centerOnCurrentScreen)
            {
                Location = new Point(
                    workingArea.Left + Math.Max(0, (workingArea.Width - Width) / 2),
                    workingArea.Top + Math.Max(0, (workingArea.Height - Height) / 2));
            }
        }

        protected override void WndProc(ref Message message)
        {
            bool dpiChanged = message.Msg == WmDpiChanged;
            base.WndProc(ref message);

            if (dpiChanged && IsHandleCreated && !IsDisposed)
            {
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        if (!IsDisposed)
                        {
                            ApplyViewClientSize(false);
                        }
                    });
                }
                catch (InvalidOperationException)
                {
                    // The window is already closing.
                }
            }
        }

        private void ShowProgressView()
        {
            if (progressViewVisible)
            {
                return;
            }

            progressViewVisible = true;
            currentView = LauncherView.Progress;
            networkPanel.Visible = false;
            welcomePanel.Visible = false;
            progressPanel.Visible = true;
            ApplyViewClientSize(true);
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
                if (!autoResume && !String.IsNullOrWhiteSpace(preferredInterfaceAlias))
                {
                    startInfo.Arguments += " -PreferredInterfaceAlias "
                        + SetupLauncher.Quote(preferredInterfaceAlias);
                }
                if (!autoResume && !String.IsNullOrWhiteSpace(preferredIpAddress))
                {
                    startInfo.Arguments += " -PreferredIpAddress "
                        + SetupLauncher.Quote(preferredIpAddress);
                }
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
                // Subscribe to process completion only after both output readers
                // are active, so the final outcome can be drained before rendering.
                installerProcess.EnableRaisingEvents = true;
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
                    if (String.Equals(type, "outcome", StringComparison.OrdinalIgnoreCase))
                    {
                        operationOutcome = GetEventText(payload, "outcome");
                        operationMessage = GetEventText(payload, "message");
                        if (String.Equals(operationOutcome, "Running", StringComparison.OrdinalIgnoreCase))
                        {
                            activityLabel.Text = "Setup working";
                            activityLabel.ForeColor = SetupTheme.Text;
                            progressStatusLabel.Text = operationMessage;
                            pulseTimer.Start();
                        }
                        else
                        {
                            pulseTimer.Stop();
                            ApplyInstallerOutcome(0);
                        }
                        return;
                    }
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

        private void ApplyInstallerOutcome(int exitCode)
        {
            bool failed = (exitCode != 0 && exitCode != 3010)
                || String.Equals(operationOutcome, "Failed", StringComparison.OrdinalIgnoreCase)
                || String.Equals(operationOutcome, "Running", StringComparison.OrdinalIgnoreCase);
            if (failed)
            {
                Environment.ExitCode = exitCode == 0 ? 1 : exitCode;
                activityLabel.Text = "Setup needs attention";
                activityLabel.ForeColor = SetupTheme.Error;
                progressStatusLabel.Text = String.Equals(operationOutcome, "Failed", StringComparison.OrdinalIgnoreCase)
                    ? operationMessage
                    : "Setup exited before completing. Open the full log for details.";
            }
            else if (exitCode == 3010 || String.Equals(operationOutcome, "RestartRequired", StringComparison.OrdinalIgnoreCase))
            {
                Environment.ExitCode = 3010;
                activityLabel.Text = "Restart required";
                activityLabel.ForeColor = SetupTheme.Blue;
                progressStatusLabel.Text = "Restart Windows and sign back in to continue setup.";
            }
            else if (String.Equals(operationOutcome, "Completed", StringComparison.OrdinalIgnoreCase))
            {
                Environment.ExitCode = 0;
                progressBar.Value = 100;
                activityLabel.Text = "Setup finished";
                activityLabel.ForeColor = SetupTheme.Success;
                progressStatusLabel.Text = operationMessage;
            }
            else
            {
                Environment.ExitCode = 0;
                activityLabel.Text = String.Equals(operationOutcome, "Cancelled", StringComparison.OrdinalIgnoreCase)
                    ? "Operation cancelled"
                    : "Setup closed";
                activityLabel.ForeColor = SetupTheme.Muted;
                progressStatusLabel.Text = operationMessage;
            }
        }

        private void InstallerProcessExited(object sender, EventArgs eventArgs)
        {
            Process completedProcess = (Process)sender;
            int exitCode;
            try
            {
                // Wait for asynchronous readers to enqueue the last outcome event
                // before the completion callback is queued on the UI thread.
                completedProcess.WaitForExit();
                exitCode = completedProcess.ExitCode;
            }
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

                    ApplyInstallerOutcome(exitCode);
                    AppendOutput(activityLabel.Text + ": " + progressStatusLabel.Text);
                    if (Environment.ExitCode != 0 && Environment.ExitCode != 3010)
                    {
                        MessageBox.Show(
                            "The installer exited before completing.\r\n\r\n"
                            + progressStatusLabel.Text + "\r\n"
                            + "Diagnostic log: " + logPath,
                            "Kiloview Environment Setup",
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Warning);
                    }

                    completedProcess.Dispose();
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
            if (networkConfigurationInProgress)
            {
                eventArgs.Cancel = true;
                MessageBox.Show(
                    "Windows is applying the static network settings.\r\n\r\n"
                    + "Wait for this operation to finish before closing the application.",
                    Text,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

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
                    noticeForm.AutoScaleDimensions = new SizeF(96F, 96F);
                    noticeForm.AutoScaleMode = AutoScaleMode.Dpi;
                    noticeForm.Size = new Size(720, 560);
                    noticeForm.Shown += delegate
                    {
                        Size noticeSize = ScaleLogicalSize(new Size(720, 560));
                        Rectangle workingArea = Screen.FromControl(this).WorkingArea;
                        noticeForm.Size = new Size(
                            Math.Min(noticeSize.Width, Math.Max(320, workingArea.Width - 40)),
                            Math.Min(noticeSize.Height, Math.Max(240, workingArea.Height - 40)));
                    };
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
