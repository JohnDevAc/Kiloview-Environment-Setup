// Copyright (c) 2026 John Lightfoot
// SPDX-License-Identifier: MIT
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;

namespace KiloLink.Setup
{
    internal static class SetupPackage
    {
        private const string ResourceName = "KiloLink.Setup.ConfigurationPackage.exe";
        internal static bool IsEmbedded { get { using (Stream payload = typeof(SetupPackage).Assembly.GetManifestResourceStream(ResourceName)) { return payload != null; } } }

        internal static string InstalledDirectory
        {
            get { return Path.Combine(Environment.GetEnvironmentVariable("ProgramW6432") ?? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Kiloview", "Environment Setup"); }
        }

        internal static ProcessStartInfo CreateStartInfo(string stagingDirectory, string logPath)
        {
            Directory.CreateDirectory(stagingDirectory);
            string path = Path.Combine(stagingDirectory, "configuration-" + Guid.NewGuid().ToString("N") + ".exe");
            using (Stream payload = typeof(SetupPackage).Assembly.GetManifestResourceStream(ResourceName))
            {
                if (payload == null) { throw new InvalidOperationException("The configuration package is missing from this installer."); }
                using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { payload.CopyTo(output); }
            }
            // Burn repairs an existing MSI, installs an absent one, and manages
            // related older bundles. It never presents a second setup window.
            return new ProcessStartInfo(path, "/repair /quiet /norestart /log " + SetupLauncher.Quote(logPath))
            { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        }

        internal static void ValidateInstallation(string directory)
        {
            string application = Path.Combine(directory, "Kiloview-Environment-Setup.exe");
            if (!File.Exists(Path.Combine(directory, "managed-installation.json")) || !File.Exists(application)
                || !String.Equals(FileVersionInfo.GetVersionInfo(application).FileVersion,
                    typeof(SetupPackage).Assembly.GetName().Version.ToString(), StringComparison.Ordinal))
            { throw new InvalidOperationException("The installed configuration app does not match this setup version. Close any other setup window and retry."); }
            foreach (string name in new string[] { "Install-KiloLinkSuite.ps1", "QuietInstaller.cs" })
            {
                using (Stream expected = typeof(SetupPackage).Assembly.GetManifestResourceStream("KiloLink.Setup." + name))
                using (Stream actual = File.OpenRead(Path.Combine(directory, name)))
                using (SHA256 hash = SHA256.Create())
                {
                    string expectedHash = Convert.ToBase64String(hash.ComputeHash(expected));
                    if (expectedHash != Convert.ToBase64String(hash.ComputeHash(actual))) { throw new InvalidDataException("The installed " + name + " is incomplete. Close other setup windows and retry."); }
                }
            }
        }
    }
}
