# Kiloview Environment Setup

Kiloview Environment Setup is a menu-driven Windows 11 installer for:

- Kiloview KiloLink Server Pro
- NDI Tools
- NDI Discovery Server, configured to start automatically
- KiloLink browser shortcuts on the public desktop and common Start Menu
- A persistent watchdog task that keeps the dedicated WSL service environment running

## Run

For the simplest installation, download `Kiloview-Environment-Setup.exe`,
double-click it, approve the Windows Administrator prompt, select **Start
setup**, and follow the choices shown in the application. The deployment engine
runs without a separate PowerShell window. Granular progress, current activity,
interactive prompts, and installer output remain in the same Windows UI.

The executable contains the deployment script, application artwork, licence,
and third-party notices, so no other downloaded project files are required.

Launcher diagnostics are saved to
`C:\ProgramData\KiloLink\setup-launcher.log`.

Windows may show an unknown-publisher warning until the executable is signed
with a trusted code-signing certificate.

Alternatively, open PowerShell and run:

    Set-ExecutionPolicy -Scope Process Bypass -Force
    Unblock-File .\Install-KiloLinkSuite.ps1
    .\Install-KiloLinkSuite.ps1

The script requests Administrator elevation if needed.

## Building Kiloview-Environment-Setup.exe

`Kiloview-Environment-Setup.exe` is built with the .NET Framework compiler
included with Windows 11. After changing `Install-KiloLinkSuite.ps1` or the
launcher source, run:

```powershell
.\Build-Setup.ps1
```

The build embeds the current PowerShell script into the executable. Launcher
source and its Administrator manifest are under `launcher`. The Windows icon
source and multi-resolution `.ico` file are under `assets` and are embedded by
the same build. The MIT licence and third-party notices are also embedded and
can be viewed from the launcher's **Licences** button.

Interactive operations use the application's granular progress view. Detailed
WSL, APT, Docker, and installer output is shown in the activity panel and
written to `C:\ProgramData\KiloLink\installer.log`.

On a clean PC, choose Install. Missing or disabled WSL is treated as the normal
clean-install state. Setup enables and verifies WSL and Virtual Machine
Platform, installs and updates the WSL runtime without an unrelated default
distribution, and waits for each prerequisite to become healthy before moving
on.

When Windows must restart, Setup saves its configuration, registers a maximum
of three elevated continuation attempts, and offers to restart Windows with a
20-second warning. About 20 seconds after the same user signs back in, the
persisted launcher resumes automatically, waits for physical networking, and
re-verifies Windows features and WSL before continuing with Ubuntu, Docker,
KiloLink, and NDI. The continuation task and state are removed after success.

KiloLink and Docker are installed in a dedicated WSL distribution named
`KiloLink-Ubuntu`. Existing Ubuntu distributions, packages, and APT sources are
not reused or modified.

The script deploys Kiloview's official `kiloview/klnk-pro` container image with
the host-network, Avahi/DBus mounts, persistent data, privileges, and restart
policy used by Kiloview's installer. This avoids depending on its changing
interactive prompt sequence.

## Menu

Once a complete or partial installation is detected, the menu offers:

1. Check for and install updates
2. Repair / reconfigure
3. Uninstall
4. Exit

### Background repair and update

After an interactive run has saved the configuration, repair can run without
menu prompts from an elevated PowerShell session:

    .\Install-KiloLinkSuite.ps1 -Action Repair -AcceptLicenses -LogPath C:\ProgramData\KiloLink\background-install.log

Use `-AcceptLicenses` only after reviewing and accepting the vendor agreements.
Unattended repair schedules its continuation but does not restart Windows unless
`-AutoRestart` is also supplied. Interactive Setup asks before restarting, and
an already-resumed installation automatically performs any additional required
restart within its three-attempt safety limit.
For a non-interactive update check, use `-Action Update` with an optional
`-LogPath`. Uninstall remains interactive-only to protect application data.

After a successful install, repair, or update, the application activity view
shows the KiloLink web address, NDI Discovery Server endpoint, and login
details. Kiloview's
[installation and deployment manual](https://www.kiloview.com/downloads/downloads/Firmware/kilolink-server-pro/Kilolink_Server_Pro_Installation_and_Deployment_Manual.pdf)
documents these defaults for a new KiloLink Server Pro installation:

- Username: `admin`
- Password: `Kiloview001`

Change the default password immediately after the first login. Existing
installations retain their previously configured password. NDI Tools and NDI
Discovery Server do not provide a web login.

Update checks the official current NDI Tools package, Ubuntu and Docker
packages, and the Kiloview KiloLink container image.

Uninstall removes KiloLink and its persisted application data, NDI Tools and
Discovery Server, the scheduled tasks, installer firewall rules, legacy port
proxies associated with the saved configuration, shortcuts, and the dedicated
`KiloLink-Ubuntu` distribution. It retains WSL, unrelated distributions, and
the shared `.wslconfig` file so unrelated Linux data is not destroyed.

## Multi-NIC behavior

The installer lists active physical Ethernet and Wi-Fi IPv4 addresses. Docker,
WSL, Hyper-V, tunnel, VPN, and loopback adapters are excluded. A wired address
assigned by DHCP is preferred.

The selected address is the primary address advertised to KiloLink devices and
is used in the browser shortcuts. WSL mirrored networking and host networking
inside Docker allow KiloLink to listen through all active physical adapters.
NDI Discovery Server binds to 0.0.0.0 for the same reason.

Use a DHCP reservation for the chosen Ethernet address. If DHCP later assigns a
different address, rerun the script and choose Repair / reconfigure.

## Defaults

| Setting | Default |
|---|---:|
| KiloLink web | 80/TCP |
| KiloLink device link pair | 50000-50001/UDP |
| NDI Discovery Server | 5959/TCP |
| KiloLink persistent Linux data | /opt/kilolink-server |

Windows 11 22H2 or later and internet access are required. The script asks for
explicit acceptance of the vendor license terms before installation.

## Licence and third-party software

Copyright (c) 2026 John Lightfoot.

The original source code, documentation, executable launcher, and artwork in
this repository are available under the [MIT License](LICENSE). This permits
use, modification, redistribution, sublicensing, and commercial use while
requiring the copyright and licence notice to be retained.

Kiloview Environment Setup is an independent project and is not affiliated
with, sponsored, approved, or endorsed by Kiloview or Vizrt NDI AB. Software
downloaded by the installer—including Kiloview KiloLink Server Pro and NDI
Tools—is not covered by the project's MIT licence and remains subject to the
respective vendor terms. See [third-party notices](THIRD_PARTY_NOTICES.md).

NDI® is a registered trademark of Vizrt NDI AB. Kiloview, KiloLink, and other
third-party names and marks belong to their respective owners.

When Windows 11 is running inside another virtual machine, the VM host must
expose hardware virtualization extensions to the guest. Setup detects WSL
errors such as `WSL_E_VM_MODE_INVALID_STATE` and reports that nested
virtualization must be enabled on the host instead of repeatedly reinstalling
Ubuntu. For a Hyper-V VM, fully stop the VM and run this on the host before
starting it again:

    Set-VMProcessor -VMName '<VM name>' -ExposeVirtualizationExtensions $true
