// Copyright (c) 2026 John Lightfoot
// SPDX-License-Identifier: MIT
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

namespace KiloLink.Setup
{
    internal sealed partial class SetupForm
    {
        private Panel settingsPanel;
        private Panel reviewPanel;
        private RadioButton installChoice;
        private RadioButton repairChoice;
        private RadioButton updateChoice;
        private RadioButton uninstallChoice;
        private NumericUpDown webPortBox;
        private NumericUpDown linkPortBox;
        private NumericUpDown ndiPortBox;
        private Label settingsNetworkLabel;
        private Label settingsErrorLabel;
        private Label reviewTitle;
        private TextBox reviewText;
        private CheckBox acceptanceBox;
        private Button executeButton;
        private Button returnButton;
        private Button restartButton;
        private Button finishButton;
        private LinkLabel webLink;
        private Label endpointLabel;
        private Dictionary<string, object> savedSettings;
        private string selectedAction = "Install";
        private string requestPath;
        private string resultWebUrl;

        private Panel CreatePage(string heading, string introduction)
        {
            Panel panel = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = SetupTheme.Surface, Visible = false };
            Label title = new Label { Text = heading, Font = new Font("Segoe UI Semibold", 17F), ForeColor = SetupTheme.Text,
                AutoSize = true, Location = new Point(30, 20) };
            Label intro = new Label { Text = introduction, ForeColor = SetupTheme.Muted, Location = new Point(32, 62), Size = new Size(728, 45) };
            panel.Controls.Add(title);
            panel.Controls.Add(intro);
            return panel;
        }

        private Button PageButton(Panel page, string text, int x, int y, int width, bool primary, EventHandler handler)
        {
            Button button = CreateButton(text, primary);
            button.SetBounds(x, y, width, 40);
            button.Click += handler;
            page.Controls.Add(button);
            return button;
        }

        private RadioButton ActionChoice(string title, string description, int y)
        {
            RadioButton choice = new RadioButton { Text = title, Font = new Font("Segoe UI Semibold", 11F),
                ForeColor = SetupTheme.Text, Location = new Point(34, y), Size = new Size(700, 28), AutoCheck = true };
            Label detail = new Label { Text = description, ForeColor = SetupTheme.Muted,
                Location = new Point(54, y + 30), Size = new Size(695, 24) };
            welcomePanel.Controls.Add(choice);
            welcomePanel.Controls.Add(detail);
            return choice;
        }

        private NumericUpDown PortField(Panel page, string label, string help, int y, int value, int maximum)
        {
            page.Controls.Add(CreateFieldLabel(label, 34, y));
            NumericUpDown port = new NumericUpDown { Minimum = 1, Maximum = maximum, Value = value,
                Location = new Point(34, y + 23), Size = new Size(138, 30), Font = new Font("Segoe UI", 11F), AccessibleName = label };
            page.Controls.Add(port);
            page.Controls.Add(new Label { Text = help, ForeColor = SetupTheme.Muted, Location = new Point(194, y + 26), Size = new Size(553, 35) });
            return port;
        }

        private void InitializeWizard()
        {
            welcomePanel = CreatePage("Set up or maintain this server", "Install KiloLink Server Pro and NDI, or manage an existing installation.\r\nWindows 11 22H2 or later and internet access are required.");
            welcomePanel.Visible = true;
            installChoice = ActionChoice("Install", "Set up KiloLink, NDI Tools, Discovery Server, networking and automatic startup.", 113);
            repairChoice = ActionChoice("Repair / reconfigure", "Restore missing components and apply changes to the server address or ports.", 179);
            updateChoice = ActionChoice("Check for and install updates", "Update NDI Tools, Ubuntu, Docker and the KiloLink container image.", 245);
            uninstallChoice = ActionChoice("Uninstall", "Remove the suite, its dedicated Linux environment and KiloLink application data.", 311);
            installChoice.Checked = true;
            welcomeStatusLabel = new Label { Text = "Reading saved settings...", ForeColor = SetupTheme.Blue,
                Location = new Point(34, 377), Size = new Size(716, 42) };
            welcomePanel.Controls.Add(welcomeStatusLabel);
            startButton = PageButton(welcomePanel, "Next", 34, 436, 180, true, StartButtonClick);
            logButton = PageButton(welcomePanel, "Diagnostic log", 224, 436, 176, false, LogButtonClick);
            PageButton(welcomePanel, "Licences", 410, 436, 160, false, LicencesButtonClick);
            closeButton = PageButton(welcomePanel, "Close", 580, 436, 170, false, delegate { Close(); });

            settingsPanel = CreatePage("Configure services", "Choose the ports used by this server. The device link uses an even UDP port and the next port.\r\nWindows and WSL firewall rules are configured automatically.");
            settingsNetworkLabel = new Label { ForeColor = SetupTheme.Blue, Location = new Point(34, 114), Size = new Size(710, 38) };
            settingsPanel.Controls.Add(settingsNetworkLabel);
            webPortBox = PortField(settingsPanel, "KILOLINK WEB PORT (TCP)", "Browser access to KiloLink Server Pro. Default: 80.", 166, 80, 65535);
            linkPortBox = PortField(settingsPanel, "KILOLINK DEVICE LINK (UDP)", "Even port from 2 to 65534. Default pair: 50000–50001.", 246, 50000, 65534);
            linkPortBox.Minimum = 2;
            linkPortBox.Increment = 2;
            ndiPortBox = PortField(settingsPanel, "NDI DISCOVERY PORT (TCP)", "Set this endpoint in NDI Access Manager. Default: 5959.", 326, 5959, 65535);
            settingsErrorLabel = new Label { ForeColor = SetupTheme.Error, Location = new Point(34, 395), Size = new Size(710, 32) };
            settingsPanel.Controls.Add(settingsErrorLabel);
            PageButton(settingsPanel, "Back to network", 34, 446, 180, false, delegate { ShowNetworkPage(); });
            PageButton(settingsPanel, "Review changes", 560, 446, 190, true, delegate { ReviewSelectedAction(); });
            Controls.Add(settingsPanel);

            reviewPanel = CreatePage("Review changes", "Check these settings before applying changes to this computer.");
            reviewTitle = (Label)reviewPanel.Controls[0];
            reviewText = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.FixedSingle,
                BackColor = Color.White, ForeColor = SetupTheme.Text, Font = new Font("Segoe UI", 10F), Location = new Point(34, 108), Size = new Size(716, 219), TabStop = true };
            reviewPanel.Controls.Add(reviewText);
            LinkLabel ndiTerms = TermsLink("NDI Tools licence", "https://docs.ndi.video/all/using-ndi/ndi-tools/installing-ndi-tools/software-license-agreement", 34);
            LinkLabel kiloTerms = TermsLink("Kiloview licence in official installer", "https://www.kiloview.com/downloads/klnk-pro/install.sh", 230);
            reviewPanel.Controls.Add(ndiTerms);
            reviewPanel.Controls.Add(kiloTerms);
            acceptanceBox = new CheckBox { Location = new Point(34, 373), Size = new Size(716, 54), ForeColor = SetupTheme.Text };
            acceptanceBox.CheckedChanged += delegate { executeButton.Enabled = acceptanceBox.Checked; };
            reviewPanel.Controls.Add(acceptanceBox);
            PageButton(reviewPanel, "Back", 34, 446, 180, false, delegate {
                if (selectedAction == "Uninstall") { ShowHome(); } else { ShowSettings(String.Empty); }
            });
            executeButton = PageButton(reviewPanel, "Install", 550, 446, 200, true, delegate {
                if (!acceptanceBox.Checked) { return; }
                operationOutcome = "Idle";
                operationMessage = "No deployment operation was performed.";
                progressBar.Value = 0;
                activityLabel.ForeColor = SetupTheme.Text;
                resultWebUrl = null;
                webLink.Visible = false;
                endpointLabel.Text = String.Empty;
                returnButton.Enabled = false;
                finishButton.Enabled = false;
                restartButton.Visible = false;
                outputBox.Clear();
                ShowProgressView();
                StartInstaller();
            });
            executeButton.Enabled = false;
            Controls.Add(reviewPanel);
        }

        private LinkLabel TermsLink(string text, string url, int x)
        {
            LinkLabel link = new LinkLabel { Text = text, AutoSize = true, Location = new Point(x, 344), LinkColor = SetupTheme.Blue };
            link.LinkClicked += delegate { OpenWebAddress(url); };
            return link;
        }

        private void OpenWebAddress(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception exception) { MessageBox.Show(this, exception.Message, "Could not open browser"); }
        }

        private void LoadSavedSettings()
        {
            string configPath = Path.Combine(Path.GetDirectoryName(launcherDirectory), "installer-config.json");
            savedSettings = null;
            webPortBox.Value = 80;
            linkPortBox.Value = 50000;
            ndiPortBox.Value = 5959;
            preferredInterfaceAlias = String.Empty;
            preferredIpAddress = String.Empty;
            bool partial = File.Exists(configPath) || HasManagedDistribution() || HasNdiRegistration();
            string error = null;
            try
            {
                if (File.Exists(configPath))
                {
                    savedSettings = eventSerializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(configPath));
                    if (savedSettings == null) { throw new InvalidDataException("Configuration is empty."); }
                    SetSavedPort(webPortBox, "WebPort", 80);
                    SetSavedPort(linkPortBox, "LinkPort", 50000);
                    SetSavedPort(ndiPortBox, "NdiDiscoveryPort", 5959);
                    preferredInterfaceAlias = GetEventText(savedSettings, "PrimaryInterfaceAlias");
                    preferredIpAddress = GetEventText(savedSettings, "PublicIp");
                }
            }
            catch (Exception exception)
            {
                savedSettings = null;
                error = "Saved settings could not be read: " + exception.Message;
            }
            installChoice.Enabled = !partial;
            repairChoice.Enabled = partial;
            uninstallChoice.Enabled = partial;
            updateChoice.Enabled = savedSettings != null;
            if (partial) { repairChoice.Checked = true; } else { installChoice.Checked = true; }
            if (SetupLauncher.InitialAction == "Uninstall" && partial) { uninstallChoice.Checked = true; }
            if (SetupLauncher.InitialAction == "Repair" && partial) { repairChoice.Checked = true; }
            SetupLauncher.InitialAction = String.Empty;
            welcomeStatusLabel.Text = error ?? (partial
                ? "An existing or partial installation was found. Saved settings are prefilled; service readiness is checked during maintenance."
                : "Ready for a new installation. Choose Next to configure the server network.");
            welcomeStatusLabel.ForeColor = error == null ? SetupTheme.Blue : SetupTheme.Error;
            logButton.Enabled = File.Exists(logPath);
        }

        private static bool HasManagedDistribution()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss"))
            {
                if (key == null) { return false; }
                foreach (string name in key.GetSubKeyNames())
                {
                    using (RegistryKey child = key.OpenSubKey(name))
                    {
                        if (child != null && String.Equals(Convert.ToString(child.GetValue("DistributionName")), "KiloLink-Ubuntu", StringComparison.OrdinalIgnoreCase)) { return true; }
                    }
                }
            }
            return false;
        }

        private static bool HasNdiRegistration()
        {
            foreach (RegistryView view in new RegistryView[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                using (RegistryKey machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, view))
                using (RegistryKey key = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"))
                {
                    if (key == null) { continue; }
                    foreach (string name in key.GetSubKeyNames())
                    {
                        using (RegistryKey child = key.OpenSubKey(name))
                        {
                            string display = child == null ? "" : Convert.ToString(child.GetValue("DisplayName"));
                            if (display.IndexOf("NDI", StringComparison.OrdinalIgnoreCase) >= 0 && display.IndexOf("Tools", StringComparison.OrdinalIgnoreCase) >= 0) { return true; }
                        }
                    }
                }
            }
            return false;
        }

        private void SetSavedPort(NumericUpDown field, string key, int fallback)
        {
            int value;
            if (!Int32.TryParse(GetEventText(savedSettings, key), out value)) { value = fallback; }
            if (value < field.Minimum || value > field.Maximum) { throw new InvalidDataException("Invalid saved " + key + "."); }
            field.Value = value;
        }

        private void ShowPage(LauncherView view, Panel page, IButtonControl next)
        {
            currentView = view;
            progressViewVisible = false;
            networkPanel.Visible = page == networkPanel;
            welcomePanel.Visible = page == welcomePanel;
            settingsPanel.Visible = page == settingsPanel;
            reviewPanel.Visible = page == reviewPanel;
            progressPanel.Visible = false;
            page.BringToFront();
            AcceptButton = next;
            ApplyViewClientSize(true);
        }

        private void ShowHome()
        {
            autoResume = false;
            ShowPage(LauncherView.Welcome, welcomePanel, startButton);
            LoadSavedSettings();
        }

        private void BeginSelectedAction()
        {
            selectedAction = uninstallChoice.Checked ? "Uninstall" : updateChoice.Checked ? "Update" : repairChoice.Checked ? "Repair" : "Install";
            if (selectedAction == "Uninstall") { ReviewSelectedAction(); }
            else { ShowNetworkPage(); }
        }

        private void ShowNetworkPage()
        {
            ShowPage(LauncherView.Network, networkPanel, applyNetworkButton);
            LoadNetworkAdapters();
        }

        private void ShowSettings(string status)
        {
            settingsNetworkLabel.Text = "Server: " + preferredInterfaceAlias + " / " + preferredIpAddress
                + (String.IsNullOrWhiteSpace(status) ? String.Empty : "\r\n" + status);
            settingsErrorLabel.Text = String.Empty;
            ShowPage(LauncherView.Settings, settingsPanel, null);
        }

        private string ValidateServiceSettings()
        {
            string normalized;
            if (String.IsNullOrWhiteSpace(preferredInterfaceAlias) || !TryParseIpv4(preferredIpAddress, true, out normalized)
                || !IsUsableServerAddress(normalized, 32)) { return "Choose a connected physical adapter with a usable IPv4 address."; }
            if (linkPortBox.Value % 2 != 0) { return "The device link port must be even; it also uses the next UDP port."; }
            if (webPortBox.Value == ndiPortBox.Value) { return "The web and NDI Discovery services must use different TCP ports."; }
            return null;
        }

        private void ReviewSelectedAction()
        {
            bool removal = selectedAction == "Uninstall";
            if (!removal)
            {
                string error = ValidateServiceSettings();
                if (error != null) { settingsErrorLabel.Text = error; return; }
            }
            reviewTitle.Text = removal ? "Review removal" : "Review " + selectedAction.ToLowerInvariant();
            reviewText.Text = removal
                ? "Remove KiloLink Server Pro and all of its application data.\r\nRemove NDI Tools and NDI Discovery Server.\r\nDelete the dedicated KiloLink-Ubuntu distribution.\r\nRemove suite tasks, firewall rules, shortcuts and maintenance registration.\r\n\r\nWSL, unrelated distributions, shared .wslconfig and Windows IP settings are retained. The reusable installer and diagnostic logs are retained.\r\n\r\nBack up any KiloLink data you need before continuing."
                : selectedAction + " KiloLink Server Pro, NDI Tools and NDI Discovery Server\r\n\r\nPrimary adapter: " + preferredInterfaceAlias + "\r\nServer IPv4: " + preferredIpAddress
                    + "\r\nKiloLink web: http://" + preferredIpAddress + ":" + webPortBox.Value + "/"
                    + "\r\nDevice link: " + linkPortBox.Value + "–" + (linkPortBox.Value + 1) + " UDP"
                    + "\r\nNDI Discovery: " + preferredIpAddress + ":" + ndiPortBox.Value + " TCP"
                    + "\r\n\r\nConfigure automatic startup, firewall rules and browser shortcuts.\r\nPreserve existing KiloLink application data. Windows may need to restart.";
            reviewText.SelectionStart = 0;
            reviewText.SelectionLength = 0;
            acceptanceBox.Checked = false;
            acceptanceBox.Text = removal ? "I understand that uninstall permanently deletes KiloLink application data and the dedicated Linux environment."
                : "I have reviewed and accept the Kiloview and NDI vendor licence agreements. I authorise installation of these components.";
            foreach (Control control in reviewPanel.Controls) { if (control is LinkLabel) { control.Visible = !removal; } }
            executeButton.Text = selectedAction == "Repair" ? "Apply repair" : selectedAction == "Update" ? "Install updates" : selectedAction;
            executeButton.Enabled = false;
            ShowPage(LauncherView.Review, reviewPanel, executeButton);
        }

        private Dictionary<string, object> CreateConfigurationRequest()
        {
            return new Dictionary<string, object> {
                { "SchemaVersion", 1 }, { "PrimaryInterfaceAlias", preferredInterfaceAlias }, { "PublicIp", preferredIpAddress },
                { "WebPort", (int)webPortBox.Value }, { "LinkPort", (int)linkPortBox.Value }, { "NdiDiscoveryPort", (int)ndiPortBox.Value }
            };
        }

        private string BuildOperationArguments()
        {
            if (autoResume) { return " -Action Resume -AcceptLicenses"; }
            if (selectedAction == "Uninstall")
            {
                if (!acceptanceBox.Checked) { throw new InvalidOperationException("Confirm permanent data removal before uninstalling."); }
                return " -Action Uninstall -ConfirmRemoval";
            }
            string error = ValidateServiceSettings();
            if (error != null) { throw new InvalidOperationException(error); }
            if (!acceptanceBox.Checked) { throw new InvalidOperationException("Vendor licence acceptance is required."); }
            requestPath = Path.Combine(launcherDirectory, "request-" + Guid.NewGuid().ToString("N") + ".json");
            File.WriteAllText(requestPath, eventSerializer.Serialize(CreateConfigurationRequest()), new UTF8Encoding(false));
            return " -Action " + selectedAction + " -AcceptLicenses -ConfigurationPath " + SetupLauncher.Quote(requestPath);
        }

        private void InitializeResultControls()
        {
            webLink = new LinkLabel { Text = "Open KiloLink", AutoSize = true, Location = new Point(32, 397), Visible = false, LinkColor = SetupTheme.Blue };
            webLink.LinkClicked += delegate { if (resultWebUrl != null) { OpenWebAddress(resultWebUrl); } };
            endpointLabel = new Label { Location = new Point(198, 394), Size = new Size(630, 43), ForeColor = SetupTheme.Text };
            progressPanel.Controls.Add(webLink);
            progressPanel.Controls.Add(endpointLabel);
            returnButton = PageButton(progressPanel, "Back to setup", 30, 441, 180, false, delegate { ShowHome(); });
            returnButton.Enabled = false;
            restartButton = PageButton(progressPanel, "Restart Windows", 480, 441, 180, true, delegate { RestartWindows(); });
            restartButton.Visible = false;
            finishButton = PageButton(progressPanel, "Finish", 680, 441, 150, true, delegate { Close(); });
            finishButton.Enabled = false;
        }

        private void ShowResultSummary(Dictionary<string, object> payload)
        {
            Uri url;
            string candidate = GetEventText(payload, "webUrl");
            if (Uri.TryCreate(candidate, UriKind.Absolute, out url) && url.Scheme == "http")
            {
                resultWebUrl = url.AbsoluteUri;
                webLink.Visible = true;
            }
            endpointLabel.Text = "NDI Discovery: " + GetEventText(payload, "ndiEndpoint") + "\r\nNew KiloLink login: admin / Kiloview001 — change after first login.";
        }

        private void FinishWizardOperation(int exitCode)
        {
            if (requestPath != null)
            {
                try { File.Delete(requestPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                requestPath = null;
            }
            bool restart = exitCode == 3010 || operationOutcome == "RestartRequired";
            restartButton.Visible = restart;
            returnButton.Enabled = !restart;
            finishButton.Enabled = true;
            finishButton.Text = restart ? "Restart later" : "Finish";
            AcceptButton = finishButton;
        }

        private void RestartWindows()
        {
            if (MessageBox.Show(this, "Windows will restart in 20 seconds. Save your other work first.\r\n\r\nSetup will continue after you sign back in. Restart now?", "Restart Windows",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) { return; }
            try
            {
                using (Process restart = Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "shutdown.exe"),
                    "/r /t 20 /c \"Kiloview Environment Setup will continue after sign-in.\"") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
                {
                    if (restart == null || !restart.WaitForExit(5000) || restart.ExitCode != 0)
                    {
                        throw new InvalidOperationException("Windows did not confirm the restart request. Restart manually when ready; setup will continue after sign-in.");
                    }
                }
                restartButton.Enabled = false;
                progressStatusLabel.Text = "Windows will restart in 20 seconds. Setup continues after sign-in.";
            }
            catch (Exception exception) { MessageBox.Show(this, exception.Message, "Restart could not be scheduled"); }
        }
    }
}
