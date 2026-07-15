# KiloLink Server Pro and NDI installer

Install-KiloLinkSuite.ps1 is a menu-driven Windows 11 installer for:

- Kiloview KiloLink Server Pro
- NDI Tools
- NDI Discovery Server, configured to start automatically
- KiloLink browser shortcuts on the public desktop and common Start Menu
- A persistent watchdog task that keeps the dedicated WSL service environment running

## Run

Open PowerShell and run:

    Set-ExecutionPolicy -Scope Process Bypass -Force
    Unblock-File .\Install-KiloLinkSuite.ps1
    .\Install-KiloLinkSuite.ps1

The script requests Administrator elevation if needed.

On a clean PC, choose Install. If Windows needs a restart after enabling WSL,
restart the PC, run the script again, and choose Repair / reconfigure. The
selected settings are saved under C:\ProgramData\KiloLink.

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
For a non-interactive update check, use `-Action Update` with an optional
`-LogPath`. Uninstall remains interactive-only to protect application data.

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
