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
[assembly: AssemblyDescription("Windows installer and maintenance for KiloLink Server Pro and NDI")]
[assembly: AssemblyCompany("John Lightfoot")]
[assembly: AssemblyProduct("Kiloview Environment Setup")]
[assembly: AssemblyCopyright("Copyright \u00A9 2026 John Lightfoot")]

namespace KiloLink.Setup
{
    internal static class SetupLauncher
    {
        internal const string InstallerResourceName = "KiloLink.Setup.Install-KiloLinkSuite.ps1";
        internal const string LicenseResourceName = "KiloLink.Setup.LICENSE";
        internal const string ThirdPartyNoticesResourceName = "KiloLink.Setup.THIRD_PARTY_NOTICES.md";
        internal const string ArtworkResourceName = "KiloLink.Setup.setup-icon.png";
        internal const string IconResourceName = "KiloLink.Setup.setup.ico";
        internal const string EventPrefix = "@@KILOVIEW_EVENT@@";
        internal static string InitialAction = String.Empty;

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
                    if (String.Equals(argument, "--repair", StringComparison.OrdinalIgnoreCase)) { InitialAction = "Repair"; }
                    if (String.Equals(argument, "--uninstall", StringComparison.OrdinalIgnoreCase)) { InitialAction = "Uninstall"; }
                }

                if (!IsAdministrator())
                {
                    ProcessStartInfo elevation = new ProcessStartInfo();
                    elevation.FileName = Assembly.GetExecutingAssembly().Location;
                    elevation.Arguments = autoResume ? "--resume" : (InitialAction == "Repair" ? "--repair" : InitialAction == "Uninstall" ? "--uninstall" : String.Empty);
                    elevation.Verb = "runas";
                    elevation.UseShellExecute = true;
                    Process.Start(elevation);
                    return 0;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                bool ownsMutex;
                using (System.Threading.Mutex instance = new System.Threading.Mutex(true, @"Global\KiloviewEnvironmentSetup", out ownsMutex))
                {
                    if (!ownsMutex)
                    {
                        MessageBox.Show("Kiloview Environment Setup is already open. Use the existing setup window.", "Setup already running");
                        return 1;
                    }
                    try { Application.Run(new SetupForm(autoResume)); }
                    finally { instance.ReleaseMutex(); }
                }
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
            File.WriteAllText(Path.Combine(Path.GetDirectoryName(destination), "QuietInstaller.cs"), ReadEmbeddedText("KiloLink.Setup.QuietInstaller.cs"));
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

        internal static Icon LoadIcon()
        {
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(IconResourceName))
            {
                if (resource == null) { throw new InvalidOperationException("The embedded application icon is missing."); }
                using (Icon source = new Icon(resource, new Size(32, 32)))
                {
                    return (Icon)source.Clone();
                }
            }
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
        internal static readonly Color Header = Color.FromArgb(87, 26, 28);
        internal static readonly Color Papaya = Color.FromArgb(255, 148, 63);
        internal static readonly Color Accent = Color.FromArgb(185, 54, 39);
        internal static readonly Color AccentHover = Color.FromArgb(158, 39, 29);
        internal static readonly Color Surface = Color.FromArgb(255, 248, 242);
        internal static readonly Color Paper = Color.FromArgb(255, 252, 248);
        internal static readonly Color Track = Color.FromArgb(237, 211, 192);
        internal static readonly Color Border = Color.FromArgb(216, 186, 169);
        internal static readonly Color Text = Color.FromArgb(51, 31, 27);
        internal static readonly Color Muted = Color.FromArgb(121, 93, 84);
        internal static readonly Color InverseText = Color.FromArgb(255, 240, 227);
        internal static readonly Color Success = Color.FromArgb(47, 107, 71);
        internal static readonly Color Error = Color.FromArgb(159, 29, 43);
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
                        SetupTheme.Accent,
                        SetupTheme.Papaya,
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
            Size textSize = TextRenderer.MeasureText(percentage, Font);
            float dpiScale = Math.Max(1F, Font.SizeInPoints / 9F);
            int badgeWidth = Math.Min(Width, textSize.Width + (int)Math.Ceiling(12F * dpiScale));
            int badgeHeight = Math.Min(Height - 2, textSize.Height + (int)Math.Ceiling(4F * dpiScale));
            Rectangle percentageBounds = new Rectangle((Width - badgeWidth) / 2, (Height - badgeHeight) / 2, badgeWidth, badgeHeight);
            using (GraphicsPath badge = RoundedRectangle(percentageBounds, Math.Min(7F * dpiScale, badgeHeight / 2F)))
            using (SolidBrush badgeBrush = new SolidBrush(SetupTheme.Paper))
            {
                graphics.FillPath(badgeBrush, badge);
            }
                TextRenderer.DrawText(
                    graphics,
                    percentage,
                    Font,
                    percentageBounds,
                    SetupTheme.Text,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
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

    internal sealed partial class SetupForm : Form
    {
        private enum LauncherView
        {
            Role,
            Network,
            Welcome,
            Settings,
            Review,
            Progress
        }

        private const int WmDpiChanged = 0x02E0;

        private readonly Panel networkPanel;
        private readonly Label singleFileBadge;
        private readonly ComboBox networkAdapterBox;
        private readonly Button refreshNetworkButton;
        private readonly Button continueNetworkButton;
        private readonly Button networkCloseButton;
        private readonly Label networkAdapterDetailsLabel;
        private readonly Label networkStatusLabel;
        private Panel welcomePanel;
        private readonly Panel progressPanel;
        private readonly InstallerProgressBar progressBar;
        private readonly Label activityLabel;
        private readonly Label progressStatusLabel;
        private readonly StringBuilder diagnosticOutput = new StringBuilder();
        private readonly Timer pulseTimer;
        private readonly JavaScriptSerializer eventSerializer;
        private Process installerProcess;
        private readonly string launcherDirectory;
        private string persistentLauncherPath;
        private readonly string legacyPersistentLauncherPath;
        private string installerPath;
        private readonly string logPath;
        private bool managedInstallation;
        private bool configurationPackageInProgress;
        private bool configurationPackageReady;
        private bool packageRestartRequired;
        private string pendingOperationArguments;
        private string configurationPackagePath;
        private bool autoResume;
        private LauncherView currentView;
        private bool installerOperationInProgress;
        private bool IsOperationInProgress { get { return installerOperationInProgress; } }
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
            string assemblyLocation = Assembly.GetExecutingAssembly().Location;
            string applicationDirectory = String.IsNullOrEmpty(assemblyLocation) ? null : Path.GetDirectoryName(assemblyLocation);
            managedInstallation = !String.IsNullOrEmpty(applicationDirectory) && File.Exists(Path.Combine(applicationDirectory, "managed-installation.json"));
            if (managedInstallation)
            {
                persistentLauncherPath = Assembly.GetExecutingAssembly().Location;
                installerPath = Path.Combine(applicationDirectory, "Install-KiloLinkSuite.ps1");
            }
            logPath = Path.Combine(programData, "KiloLink", "setup-launcher.log");
            currentView = LauncherView.Role;

            Text = "Kiloview Environment Setup";
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            ClientSize = new Size(680, 390);
            Font = new Font("Segoe UI", 9F);
            BackColor = SetupTheme.Surface;
            // The measured layout scales both typography and geometry in one pass.
            AutoScaleMode = AutoScaleMode.None;
            Icon = SetupLauncher.LoadIcon();
            FormClosing += SetupFormClosing;

            Panel headerPanel = new Panel();
            headerPanel.Dock = DockStyle.Top;
            headerPanel.Size = new Size(680, 96);
            headerPanel.Height = 118;
            headerPanel.BackColor = SetupTheme.Header;

            PictureBox artwork = new PictureBox();
            artwork.Location = new Point(20, 15);
            artwork.Size = new Size(88, 88);
            artwork.SizeMode = PictureBoxSizeMode.Zoom;
            artwork.BackColor = Color.Transparent;
            artwork.Image = SetupLauncher.LoadArtwork();

            Label title = new Label();
            title.Text = "Kiloview Environment Setup";
            title.Font = new Font("Segoe UI Semibold", 17F);
            title.ForeColor = SetupTheme.InverseText;
            title.AutoSize = true;
            title.Location = new Point(122, 27);

            Label subtitle = new Label();
            subtitle.Text = "Server and client setup for KiloLink + NDI";
            subtitle.Font = new Font("Segoe UI", 9F);
            subtitle.ForeColor = SetupTheme.Papaya;
            subtitle.AutoSize = true;
            subtitle.Location = new Point(125, 68);

            singleFileBadge = new Label();
            singleFileBadge.Text = "SINGLE-FILE SETUP";
            singleFileBadge.Font = new Font("Segoe UI Semibold", 8F);
            singleFileBadge.ForeColor = SetupTheme.Header;
            singleFileBadge.BackColor = SetupTheme.Papaya;
            singleFileBadge.AutoSize = true;
            singleFileBadge.Padding = new Padding(9, 5, 9, 5);
            singleFileBadge.Location = new Point(526, 39);
            singleFileBadge.Anchor = AnchorStyles.Top | AnchorStyles.Right;

            headerPanel.Controls.Add(artwork);
            headerPanel.Controls.Add(title);
            headerPanel.Controls.Add(subtitle);
            headerPanel.Controls.Add(singleFileBadge);
            headerPanel.Controls.Add(new Panel { Dock = DockStyle.Bottom, Height = 4, BackColor = SetupTheme.Papaya });

            networkPanel = new Panel();
            networkPanel.Dock = DockStyle.Fill;
            networkPanel.BackColor = SetupTheme.Surface;
            networkPanel.AutoScroll = true;
            networkPanel.Visible = false;

            Label networkTitle = new Label();
            networkTitle.Text = "Choose the server network";
            networkTitle.Font = new Font("Segoe UI Semibold", 15F);
            networkTitle.ForeColor = SetupTheme.Text;
            networkTitle.AutoSize = true;
            networkTitle.Location = new Point(30, 17);

            Label networkIntro = new Label();
            networkIntro.Text = "Choose the existing network adapter and address to use for this server.\r\nYou are responsible for configuring its IP address, gateway and DNS outside setup.";
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

            continueNetworkButton = CreateButton("Continue", true);
            continueNetworkButton.Location = new Point(344, 365);
            continueNetworkButton.Size = new Size(200, 44);
            continueNetworkButton.Click += ContinueNetworkButtonClick;

            networkCloseButton = CreateButton("Back", false);
            networkCloseButton.Location = new Point(556, 365);
            networkCloseButton.Size = new Size(172, 44);
            networkCloseButton.Click += delegate { ShowHome(); };

            networkStatusLabel = new Label();
            networkStatusLabel.Text = "Select the adapter that will carry KiloLink and NDI traffic.";
            networkStatusLabel.Font = new Font("Segoe UI Semibold", 9F);
            networkStatusLabel.ForeColor = SetupTheme.Accent;
            networkStatusLabel.AutoEllipsis = true;
            networkStatusLabel.Location = new Point(34, 426);
            networkStatusLabel.Size = new Size(694, 22);

            networkPanel.Controls.Add(networkTitle);
            networkPanel.Controls.Add(networkIntro);
            networkPanel.Controls.Add(adapterLabel);
            networkPanel.Controls.Add(networkAdapterBox);
            networkPanel.Controls.Add(refreshNetworkButton);
            networkPanel.Controls.Add(networkAdapterDetailsLabel);
            networkPanel.Controls.Add(continueNetworkButton);
            networkPanel.Controls.Add(networkCloseButton);
            networkPanel.Controls.Add(networkStatusLabel);

            InitializeWizard();

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
            progressStatusLabel.Text = "Preparing the selected components...";
            progressStatusLabel.ForeColor = SetupTheme.Muted;
            progressStatusLabel.AutoEllipsis = true;
            progressStatusLabel.Location = new Point(32, 99);
            progressStatusLabel.Size = new Size(796, 22);

            InitializeResultControls();

            progressPanel.Controls.Add(activityLabel);
            progressPanel.Controls.Add(progressBar);
            progressPanel.Controls.Add(progressStatusLabel);

            Controls.Add(networkPanel);
            Controls.Add(welcomePanel);
            Controls.Add(progressPanel);
            Controls.Add(headerPanel);
            InitializeAdaptiveLayout(headerPanel, artwork, title, subtitle);
            AcceptButton = roleNextButton;

            pulseTimer = new Timer();
            pulseTimer.Interval = 90;
            pulseTimer.Tick += delegate { progressBar.AdvancePulse(); };

            Shown += SetupFormShown;

            if (!autoResume && SetupLauncher.InitialAction == "Uninstall")
            {
                Shown += delegate { selectedAction = "Uninstall"; ReviewSelectedAction(); };
            }
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
            button.BackColor = primary ? SetupTheme.Accent : SetupTheme.Paper;
            button.ForeColor = primary ? Color.White : SetupTheme.Text;
            button.FlatAppearance.BorderColor = primary ? SetupTheme.Accent : SetupTheme.Border;
            button.FlatAppearance.BorderSize = 1;
            button.FlatAppearance.MouseOverBackColor = primary ? SetupTheme.AccentHover : SetupTheme.Track;
            button.FlatAppearance.MouseDownBackColor = primary ? SetupTheme.Header : SetupTheme.Border;
            button.EnabledChanged += delegate
            {
                button.BackColor = button.Enabled ? (primary ? SetupTheme.Accent : SetupTheme.Paper) : SetupTheme.Track;
                button.FlatAppearance.BorderColor = button.Enabled && primary ? SetupTheme.Accent : SetupTheme.Border;
            };
            button.UseVisualStyleBackColor = false;
            return button;
        }

        private static Label CreateFieldLabel(string text, int x, int y)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = new Font("Segoe UI Semibold", 8F);
            label.ForeColor = SetupTheme.Accent;
            label.AutoSize = true;
            label.Location = new Point(x, y);
            return label;
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
            if (IsOperationInProgress)
            {
                return;
            }

            NetworkAdapterChoice previous = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            string previousAlias = previous == null ? preferredInterfaceAlias : previous.Alias;
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
                continueNetworkButton.Enabled = false;
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
            networkStatusLabel.Text = "Select the existing address this server will advertise to devices.";
            networkStatusLabel.ForeColor = SetupTheme.Accent;
        }

        private void NetworkAdapterSelectionChanged(object sender, EventArgs eventArgs)
        {
            NetworkAdapterChoice choice = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            if (choice == null)
            {
                continueNetworkButton.Enabled = false;
                return;
            }

            networkAdapterDetailsLabel.Text = choice.Description
                + " — "
                + (choice.Dhcp ? "currently using DHCP" : "currently static/manual")
                + (choice.Connected ? String.Empty : " — adapter is disconnected");
            string address;
            continueNetworkButton.Enabled = !IsOperationInProgress && choice.Connected
                && TryParseIpv4(choice.Address, true, out address) && IsUsableServerAddress(address, choice.PrefixLength);
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

        private void ContinueNetworkButtonClick(object sender, EventArgs eventArgs)
        {
            if (IsOperationInProgress) { return; }
            NetworkAdapterChoice choice = networkAdapterBox.SelectedItem as NetworkAdapterChoice;
            string usableAddress;
            if (choice == null || !choice.Connected || !TryParseIpv4(choice.Address, true, out usableAddress) || !IsUsableServerAddress(usableAddress, choice.PrefixLength))
            {
                networkStatusLabel.Text = "Select a connected physical adapter with a usable IPv4 address, then continue.";
                networkStatusLabel.ForeColor = SetupTheme.Error;
                return;
            }
            preferredInterfaceAlias = choice.Alias;
            preferredIpAddress = usableAddress;
            ReviewSelectedAction();
        }

        private static void AddButtonToTable(TableLayoutPanel table, Button button, int column, int left, int right)
        {
            button.Dock = DockStyle.Fill;
            button.Margin = new Padding(left, 4, right, 4);
            table.Controls.Add(button, column, 0);
        }

        private void SetupFormShown(object sender, EventArgs eventArgs)
        {
            ApplyDisplayScale(CurrentDpiScale());
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
            FitCurrentPage(centerOnCurrentScreen);
        }

        protected override void WndProc(ref Message message)
        {
            bool dpiChanged = message.Msg == WmDpiChanged;
            float requestedScale = dpiChanged ? (message.WParam.ToInt64() & 0xffff) / 96F : displayScale;
            base.WndProc(ref message);

            if (dpiChanged && IsHandleCreated && !IsDisposed)
            {
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        if (!IsDisposed)
                        {
                            ApplyDisplayScale(requestedScale);
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
            if (IsOperationInProgress) { return; }
            if (progressViewVisible)
            {
                return;
            }

            progressViewVisible = true;
            currentView = LauncherView.Progress;
            rolePanel.Visible = false;
            networkPanel.Visible = false;
            welcomePanel.Visible = false;
            settingsPanel.Visible = false;
            reviewPanel.Visible = false;
            progressPanel.Visible = true;
            ApplyViewClientSize(true);
            AcceptButton = null;
            pulseTimer.Start();
            AppendOutput("Kiloview Environment Setup started.");
            AppendOutput("The deployment engine is running without a separate console window.");
        }

        private void StartButtonClick(object sender, EventArgs eventArgs)
        {
            BeginSelectedAction();
        }

        private void StartInstaller()
        {
            if (IsOperationInProgress) { return; }
            installerOperationInProgress = true;
            try
            {
                Directory.CreateDirectory(launcherDirectory);
                if (pendingOperationArguments == null) { pendingOperationArguments = BuildOperationArguments(); }
                if (SetupPackage.IsEmbedded && !configurationPackageReady)
                {
                    if (!acceptanceBox.Checked) { throw new InvalidOperationException("Accept the installer licence and review the operation before continuing."); }
                    string packageLog = Path.Combine(Path.GetDirectoryName(logPath), "configuration-package.log");
                    installerProcess = new Process { StartInfo = SetupPackage.CreateStartInfo(launcherDirectory, packageLog) };
                    configurationPackagePath = installerProcess.StartInfo.FileName;
                    configurationPackageInProgress = true;
                    installerProcess.Exited += InstallerProcessExited;
                    if (!installerProcess.Start()) { throw new InvalidOperationException("Windows did not start the configuration package."); }
                    activityLabel.Text = "Preparing setup";
                    progressStatusLabel.Text = "Installing or updating the setup application. Your selected components will follow automatically.";
                    installerProcess.EnableRaisingEvents = true;
                    return;
                }
                string currentLauncher = Assembly.GetExecutingAssembly().Location;
                if (!managedInstallation && !String.Equals(
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

                EnsureProvisionerFiles();

                string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string powershellPath = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershellPath))
                {
                    powershellPath = "powershell.exe";
                }

                ProcessStartInfo startInfo = new ProcessStartInfo();
                startInfo.FileName = powershellPath;
                startInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "
                    + SetupLauncher.Quote(installerPath)
                    + pendingOperationArguments
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
                installerProcess.OutputDataReceived += InstallerOutputReceived;
                installerProcess.ErrorDataReceived += InstallerErrorReceived;
                installerProcess.Exited += InstallerProcessExited;
                if (!installerProcess.Start())
                {
                    throw new InvalidOperationException("Windows did not start the deployment engine.");
                }

                installerProcess.StandardInput.Close();
                installerProcess.BeginOutputReadLine();
                installerProcess.BeginErrorReadLine();
                activityLabel.Text = autoResume ? "Resuming setup" : selectedAction == "InstallClient" ? "Installing client tools" : selectedAction + " in progress";
                progressStatusLabel.Text = autoResume
                    ? "Windows and WSL state are being verified."
                    : selectedAction == "InstallClient" ? "Checking the latest NDI Tools download." : "Applying the settings you reviewed.";
                // Subscribe to process completion only after both output readers
                // are active, so the final outcome can be drained before rendering.
                installerProcess.EnableRaisingEvents = true;
            }
            catch (Exception exception)
            {
                // Keep ownership if Windows started the worker before a reader
                // setup failed. A retry must not overlap that worker.
                installerOperationInProgress = false;
                if (installerProcess != null)
                {
                    try { installerOperationInProgress = !installerProcess.HasExited; }
                    catch (InvalidOperationException) { }
                    if (installerOperationInProgress) { installerProcess.EnableRaisingEvents = true; }
                    else { installerProcess.Dispose(); installerProcess = null; }
                }
                if (!installerOperationInProgress) { configurationPackageInProgress = false; pendingOperationArguments = null; }
                Environment.ExitCode = 1;
                FinishWizardOperation(1);
                pulseTimer.Stop();
                activityLabel.Text = "Setup could not start";
                activityLabel.ForeColor = SetupTheme.Error;
                progressStatusLabel.Text = exception.Message;
                AppendOutput("ERROR: " + exception.Message);
                MessageBox.Show(
                    "Setup could not start.\r\n\r\n" + exception.Message,
                    "Kiloview Environment Setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private void EnsureProvisionerFiles()
        {
            if (managedInstallation)
            {
                if (!File.Exists(installerPath)) { throw new FileNotFoundException("Provisioner is missing. Repair Kiloview Environment Setup in Windows Apps.", installerPath); }
            }
            else { SetupLauncher.ExtractInstaller(installerPath); }
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

                    if (String.Equals(type, "summary", StringComparison.OrdinalIgnoreCase))
                    {
                        ShowResultSummary(payload);
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
                activityLabel.ForeColor = SetupTheme.Accent;
                progressStatusLabel.Text = selectedAction == "InstallClient" || packageRestartRequired
                    ? operationMessage
                    : "Restart Windows and sign back in to continue setup.";
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
                    if (!Object.ReferenceEquals(installerProcess, completedProcess)) { completedProcess.Dispose(); return; }
                    if (configurationPackageInProgress)
                    {
                        CompleteConfigurationPackage(completedProcess, exitCode);
                        return;
                    }
                    pendingOperationArguments = null;
                    installerOperationInProgress = false;
                    pulseTimer.Stop();
                    FinishWizardOperation(exitCode);

                    ApplyInstallerOutcome(exitCode);
                    AppendOutput(activityLabel.Text + ": " + progressStatusLabel.Text);
                    if (Environment.ExitCode != 0 && Environment.ExitCode != 3010)
                    {
                        MessageBox.Show(
                            "Setup needs attention.\r\n\r\n"
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
            // Raw process output is diagnostic data, never part of the Windows UI.
            diagnosticOutput.AppendLine(line ?? String.Empty);
            if (diagnosticOutput.Length > 1024 * 1024) { diagnosticOutput.Remove(0, diagnosticOutput.Length - 1024 * 1024); }
        }

        private void CompleteConfigurationPackage(Process completedProcess, int exitCode)
        {
            completedProcess.Dispose();
            installerProcess = null;
            configurationPackageInProgress = false;
            installerOperationInProgress = false;
            try { if (configurationPackagePath != null) { File.Delete(configurationPackagePath); } } catch (IOException) { } catch (UnauthorizedAccessException) { }
            if (exitCode == 0)
            {
                try
                {
                    SetupPackage.ValidateInstallation(SetupPackage.InstalledDirectory);
                    managedInstallation = true;
                    persistentLauncherPath = Path.Combine(SetupPackage.InstalledDirectory, "Kiloview-Environment-Setup.exe");
                    installerPath = Path.Combine(SetupPackage.InstalledDirectory, "Install-KiloLinkSuite.ps1");
                    configurationPackageReady = true;
                    StartInstaller();
                    return;
                }
                catch (Exception exception) { operationMessage = exception.Message; exitCode = 1; }
            }
            else
            {
                operationMessage = exitCode == 3010
                    ? "Restart Windows, then reopen this installer to finish setting up your selected components."
                    : "The setup application could not be installed or updated (code " + exitCode + "). See " + Path.Combine(Path.GetDirectoryName(logPath), "configuration-package.log");
            }
            pendingOperationArguments = null;
            packageRestartRequired = exitCode == 3010;
            operationOutcome = packageRestartRequired ? "RestartRequired" : "Failed";
            pulseTimer.Stop();
            FinishWizardOperation(exitCode);
            ApplyInstallerOutcome(exitCode);
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
                            "Setup is still applying changes to this computer.\r\n\r\n"
                            + "Wait for the operation to finish before closing it.",
                            Text,
                            MessageBoxButtons.OK,
                            MessageBoxIcon.Information);
                    }
                }
                catch { }
            }
        }

    }
}
