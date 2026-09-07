# Kiloview Environment Setup

See [current suite deployment behavior](INTEROPERABILITY.md) for role receipts, download gates, offline Client packages, port restrictions and shared-runtime removal.

Kiloview Environment Setup is a single-file Windows installer with a native
Windows Forms interface. Its first screen lets you choose **Server** or **Client**.

**Client** installs the latest official NDI Tools and
[NDI Configurator PC Agent](https://github.com/JohnDevAc/Kiloview-PC-Onboarding).
**Server** provides the full Windows 11 environment:

- Kiloview KiloLink Server Pro
- NDI Tools
- NDI Discovery Server, configured to start automatically
- KiloLink browser shortcuts on the public desktop and common Start Menu
- A persistent watchdog task that keeps the dedicated WSL service environment running

## Run

Download `Kiloview-Environment-Setup.exe`, double-click it and approve the
Windows Administrator prompt. All setup choices use native Windows controls;
there are no embedded PowerShell menus or text responses to type.

1. Choose **Server** or **Client**, then **Next**, before any networking decisions.
   **Client** goes directly to the client review described below.
2. For **Server**, choose **Install**, **Repair / reconfigure**, **Check for and install
   updates**, or **Uninstall**. Existing and partial installations are detected
   from saved configuration, the dedicated WSL registration and NDI Tools.
3. For server install, repair or update, select a physical Ethernet or Wi-Fi adapter.
   Review the prefilled IPv4 address, prefix length, gateway and DNS servers.
   Apply a static address, or use **Skip for now** for an existing stable address
   or DHCP reservation. Applying the address can briefly interrupt networking.
4. Set the KiloLink web port, even device-link port pair and NDI Discovery port.
   Repair and update prefill saved values. When saved settings are missing,
   review the displayed port defaults; repair preserves any detected existing
   KiloLink data mount and vendor image.
5. Review the settings and vendor licence links, tick the acceptance checkbox,
   then choose **Install**, **Apply repair** or **Install updates**.
6. Follow the native progress bar and status messages. At completion,
   open KiloLink, return to setup, or finish. When Windows needs a restart,
   choose **Restart Windows** or **Restart later**.

Server uninstall goes straight to a removal review, without requiring a working
network adapter. Its confirmation checkbox explicitly acknowledges deletion
of KiloLink application data before **Uninstall** is enabled.

### Client setup

Client review lists NDI Tools and PC Agent, with their licence links. Accept the
NDI Tools licence and choose **Install client tools**. Setup obtains the current
Windows package from [NDI's official download page](https://ndi.video/tools/),
checks its Windows signature and installs it. Re-running Client updates older
NDI Tools or reinstalls the current package to restore missing files. A newer
installed version is retained. The vendor installer runs on a private background
desktop, so its console helpers and completion launcher do not appear. Only that
installation's remaining child processes are closed when it finishes; existing
NDI applications are not targeted.

Setup then obtains the latest stable PC Agent release from
`JohnDevAc/Kiloview-PC-Onboarding`. It uses the complete Windows x64 package,
including its .NET runtime, verifies the release SHA-256 digest, size, archive paths
and binary product/version, then opens the agent's own native Windows setup.
Review its licence and select the production adapter there. Close that window
when it reports the agent is ready to return to this installer's completion view.
A configured PC Agent at the current or a newer version is retained.

If the GitHub API is unavailable or returns a rate-limit error such as HTTP 403,
setup uses the repository's public latest-release redirect and published `.sha256`
asset. The exact repository, stable version, checksum filename and package size
are validated before the normal archive and binary checks.

The agent keeps its own blue identity, tray UI, licence and update feed. Its setup
configures its per-user startup and subnet-scoped discovery/monitoring firewall
rules. Job onboarding is initiated from NDI Job Configurator. Cancelling agent
setup is reported as incomplete client setup; NDI Tools remains installed and
Client can be run again to finish.

Client skips this installer's static-IP page and server port settings. It does
not deploy KiloLink, WSL, Docker, the dedicated Discovery Server startup task,
server firewall rules, server maintenance registration or server configuration.
It can also be selected on a PC with an existing server configuration without
changing that configuration. If NDI Tools needs a restart, the Windows UI offers
**Restart Windows** or **Restart later**; no server continuation is scheduled.
An internet connection and 64-bit Windows are required for the client packages.

Server static-address setup waits for Windows to confirm that the address is usable.
A duplicate address or a 30-second readiness timeout triggers an attempt to
restore the previous network settings and prevents proceeding with that address.
Only one copy of the installer can be open at a time.

The executable contains the deployment script, application artwork, licence,
and third-party notices, so no other downloaded project files are required.

The red and papaya interface and hexagonal server icon give this installer
its own visual identity. The same artwork is used in the EXE, window title
bar, taskbar, installer header and Windows maintenance entry. Palette and
icon build details are documented in [assets/README.md](assets/README.md).

The launcher is per-monitor DPI aware. Each page measures its text and controls
and sizes the window to its content, including mixed-DPI monitor changes. The
first page is approximately 680 by 351 client pixels at 100% scaling. Pages that
cannot fit on the current desktop scroll vertically to keep every control reachable.
The progress page uses native status messages; raw engine output is kept in
diagnostic files.

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
source (`SetupLauncher.cs`, `SetupWizard.cs`, `SetupLayout.cs` and the embedded
`QuietInstaller.cs` helper) and its Administrator manifest are under `launcher`. The Windows icon
source and multi-resolution `.ico` file are under `assets` and are embedded by
the same build. The MIT licence and third-party notices are also embedded;
their source files are `LICENSE` and `THIRD_PARTY_NOTICES.md`.

Run the regression checks after building:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Installer.Regression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-QuietInstaller.ps1
```

The checks use isolated configuration files, fake Windows services and network
adapters, and the compiled launcher. Git for Windows Bash is required to test
the generated Linux watchdog; use `-BashPath` if it is installed elsewhere.
These checks do not install software, change network settings, or register
scheduled tasks. A complete installation and reboot should also be tested on
a disposable Windows 11 machine before release.

The application uses a hidden PowerShell deployment engine for system operations.
It runs one explicit action with a validated JSON configuration and closed
standard input; the Windows UI never starts the legacy script menu. Native
operations use the application's granular progress view. Detailed
WSL, APT, Docker, and installer output is written to diagnostic files, including
`C:\ProgramData\KiloLink\installer.log`, and is not displayed inside the app.

For a clean server PC, choose **Server**, then **Install**. Missing or disabled WSL is treated as the normal
clean-install state. Setup enables and verifies WSL and Virtual Machine
Platform, installs and updates the WSL runtime without an unrelated default
distribution, and waits for each prerequisite to become healthy before moving
on.

When server setup requires a restart, Setup saves its configuration, registers a maximum
of three elevated continuation attempts, and offers to restart Windows with a
20-second warning. About 20 seconds after the same user signs back in, the
persisted launcher resumes automatically, waits for physical networking, and
re-verifies Windows features and WSL before continuing with Ubuntu, Docker,
KiloLink, and NDI. The continuation task and state are removed after success.

Repair compares the requested settings with the actual Docker container, so an
interrupted attempt does not prevent a later repair from applying them. Cancelling
the review screen preserves the previous saved configuration. Repair also
reinstalls NDI Tools when its Discovery Service executable is missing.

The watchdog checks Docker, Avahi, and the container every 30 seconds. Failures
exit with an error so Task Scheduler can retry after one minute, up to three
times; the regular five-minute trigger remains available afterward.

Server installation and update finish successfully only after the watchdog and
container are running, NDI owns a listening socket on the configured port, and
the KiloLink web interface responds. Readiness checks retry for up to two minutes.
The launcher distinguishes successful completion, cancellation, failure, and a
pending restart. A failed operation remains visible with its diagnostic log; returning to setup allows a retry.

KiloLink and Docker are installed in a dedicated WSL distribution named
`KiloLink-Ubuntu`. Existing Ubuntu distributions, packages, and APT sources are
not reused or modified.

The script deploys Kiloview's official `kiloview/klnk-pro` container image with
the host-network, Avahi/DBus mounts, persistent data, privileges, and restart
policy used by Kiloview's installer. This avoids depending on its changing
interactive prompt sequence.

## Repair, updates and removal

Rerun the same EXE and choose **Server** to repair, reconfigure, update or uninstall
the server suite. Choose **Client** to check/install the client tools again.
Once an installation, repair or update begins, setup also creates a **Kiloview
Environment Setup** Start menu shortcut and registers an uninstall entry in
Windows **Installed apps**. Maintenance is registered for the installing
Windows account because WSL distributions belong to that account. Use that
same account for subsequent maintenance and reboot continuation.

Repair restores missing components and reconciles the actual container with
the requested settings. Updates check NDI Tools, Ubuntu/Docker packages and
the official KiloLink container image. Both preserve existing KiloLink data.

Uninstall removes the suite and its maintenance entry. It retains the reusable
setup EXE and diagnostic logs in `C:\ProgramData\KiloLink`, WSL, unrelated
Linux distributions, the shared `.wslconfig` file and Windows IP settings.
The retained installer can be used for a fresh installation.

### Background repair and update

Client installation can run directly from an elevated PowerShell session with
`-Action InstallClient -AcceptLicenses`. Its PC Agent bootstrap still uses its
native licence and adapter-selection windows when required; this action is not
an unattended deployment interface.

After a server run has saved the configuration, repair can run without
menu prompts from an elevated PowerShell session:

    .\Install-KiloLinkSuite.ps1 -Action Repair -AcceptLicenses -LogPath C:\ProgramData\KiloLink\background-install.log

Use `-AcceptLicenses` only after reviewing and accepting the vendor agreements.
Unattended repair schedules its continuation but does not restart Windows unless
`-AutoRestart` is also supplied. The native installer asks before every restart, including additional restarts during continuation. The three-attempt safety limit is retained. A resumed update continues the update operation.
For a non-interactive update check, use `-Action Update` with an optional
`-LogPath`. The Windows UI requires explicit removal confirmation. Advanced script automation can use `-Action Uninstall -ConfirmRemoval`; this permanently deletes the suite's application data.

Process exit codes are `0` for normal completion or cancellation, `1` for a
failure, and `3010` when setup needs a Windows restart to continue. A zero exit
code alone does not mean an installation took place; the launcher displays the
operation outcome separately.

After a successful server install, repair, or update, the completion page
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
For NDI Tools, server updates first read the version advertised on the official
download page. A current or newer installation with Discovery Service present
skips the installer download. Older installations and missing Discovery files
still use the signed installer. If the advertised version is unavailable or
ambiguous, setup downloads and verifies the package to check its version.

Before replacing NDI Tools, setup checks for applications using its installed
files. If an application or background task has them open, setup identifies it
and stops before starting the NDI installer. Close the named application or stop
its background task, then retry. Setup does not automatically close other apps.
NDI installer diagnostics are saved under `C:\ProgramData\KiloLink\Logs`; a failed
installation reports its specific log path. A required Windows restart defers
the remaining server configuration until setup resumes after sign-in.

Uninstall removes KiloLink and its persisted application data, NDI Tools and
Discovery Server, the scheduled tasks, installer firewall rules, legacy port
proxies associated with the saved configuration, shortcuts, and the dedicated
`KiloLink-Ubuntu` distribution. It retains WSL, unrelated distributions, and
the shared `.wslconfig` file so unrelated Linux data is not destroyed.

## Multi-NIC behavior

After choosing an operation, the network screen lists physical Ethernet and Wi-Fi adapters. Docker,
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

Windows 11 22H2 or later and internet access are required. The Windows review screen requires explicit acceptance of the vendor licence terms before installation, repair or update. Downloads still require internet access; third-party installers are not bundled in the EXE.

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

## Native wizard verification

`tests/Installer.Regression.ps1` exercises configuration validation, cancellation,
native action routing, licence and removal gates, maintenance registration,
reboot continuation, service recovery and exact embedded-script agreement.
Tests use temporary state and mocked system changes; they do not deploy the
suite or modify the computer's adapters, services, registry or scheduled tasks.

To render the compiled controls for layout review without starting deployment:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Render-Wizard.ps1
```

The automated checks do not exercise a complete live install, repair, update,
uninstall or Windows reboot/resume cycle. Validate those operations on a
disposable Windows 11 machine before production use. The build is unsigned
and may show an unknown-publisher warning.
