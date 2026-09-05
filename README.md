# Kiloview Environment Setup

Kiloview Environment Setup is a menu-driven Windows 11 installer for:

- Kiloview KiloLink Server Pro
- NDI Tools
- NDI Discovery Server, configured to start automatically
- KiloLink browser shortcuts on the public desktop and common Start Menu
- A persistent watchdog task that keeps the dedicated WSL service environment running

## Run

For the simplest installation, download `Kiloview-Environment-Setup.exe`,
double-click it and approve the Windows Administrator prompt. The first screen
lists the PC's physical Ethernet and Wi-Fi adapters and pre-fills the current
IPv4, prefix, gateway, and DNS values. Select the adapter that will carry
KiloLink and NDI traffic, review the values, and choose **Apply static IP and
continue**. Applying the address can briefly interrupt that adapter's network
connection.

Setup waits for Windows to confirm that the address is usable. A duplicate
address or a 30-second readiness timeout triggers an attempt to restore the
previous network settings and prevents setup from proceeding with that address.

A **Skip for now** option is available for PCs that already have a stable
address or DHCP reservation. It displays a server-reliability warning before
continuing because a changing address can make KiloLink and NDI endpoints
unreachable.

After networking is confirmed, select **Start setup** and follow the choices
shown in the application. The deployment engine runs without a separate
PowerShell window. Granular progress, current activity, interactive prompts,
and installer output remain in the same Windows UI.

The executable contains the deployment script, application artwork, licence,
and third-party notices, so no other downloaded project files are required.

The launcher is per-monitor DPI aware. Its welcome and progress views scale for
the active display, including mixed-DPI monitor changes. When the effective
desktop area is smaller than the full progress layout, the activity view
remains accessible by scrolling instead of clipping controls.

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

Run the regression checks after building:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Installer.Regression.ps1
```

The checks use isolated configuration files, fake Windows services and network
adapters, and the compiled launcher. Git for Windows Bash is required to test
the generated Linux watchdog; use `-BashPath` if it is installed elsewhere.
These checks do not install software, change network settings, or register
scheduled tasks. A complete installation and reboot should also be tested on
a disposable Windows 11 machine before release.

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

Repair compares the requested settings with the actual Docker container, so an
interrupted attempt does not prevent a later repair from applying them. Cancelling
the license prompt preserves the previous saved configuration. Repair also
reinstalls NDI Tools when its Discovery Service executable is missing.

The watchdog checks Docker, Avahi, and the container every 30 seconds. Failures
exit with an error so Task Scheduler can retry after one minute, up to three
times; the regular five-minute trigger remains available afterward.

Installation and update finish successfully only after the watchdog and
container are running, NDI owns a listening socket on the configured port, and
the KiloLink web interface responds. Readiness checks retry for up to two minutes.
The launcher distinguishes successful completion, cancellation, failure, and a
pending restart. Exiting the menu after a failure retains an error result until
a subsequent operation completes successfully.

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

Process exit codes are `0` for normal completion or cancellation, `1` for a
failure, and `3010` when setup needs a Windows restart to continue. A zero exit
code alone does not mean an installation took place; the launcher displays the
operation outcome separately.

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

The launcher's first screen lists physical Ethernet and Wi-Fi adapters. Docker,
WSL, Hyper-V, tunnel, VPN, and loopback adapters are excluded. Connected wired
adapters are listed first. The selected adapter and address are passed into the
deployment engine so the same adapter does not need to be selected again.

The selected address is the primary address advertised to KiloLink devices.
Local browser shortcuts use `127.0.0.1` so their targets survive address changes.
WSL mirrored networking and host networking
inside Docker allow KiloLink to listen through all active physical adapters.
NDI Discovery Server binds to 0.0.0.0 for the same reason.

Use a static address that is excluded from the DHCP pool, or reserve it on the
DHCP server before choosing **Skip for now**. If an address later changes,
rerun the launcher, correct the static configuration, and choose Repair /
reconfigure.

Update also applies the adapter and address selected in the launcher, including
static addresses. Unattended repair and update refresh the saved adapter's
address when it has changed; if several addresses make the choice ambiguous,
setup asks you to use Repair / reconfigure.

## Defaults

| Setting | Default |
|---|---:|
| KiloLink web | 80/TCP |
| KiloLink device link pair | 50000-50001/UDP |
| NDI Discovery Server | 5959/TCP |
| NDI control and streaming firewall range | 5960-10000/TCP and UDP |
| KiloLink audio/video firewall range | 30000-30300/TCP and UDP |
| mDNS discovery | 5353/UDP |
| KiloLink persistent Linux data | /opt/kilolink-server |

The NDI firewall range includes Kiloview's documented TCP/UDP streaming ports
7960-10000 in both the Windows and WSL Hyper-V firewall rules. See
[Kiloview's port requirements](https://www.kiloview.com/en/support-doc/docs/home/?a=index&aid=846568314808303616&g=Doc&id=7&m=Article).

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
