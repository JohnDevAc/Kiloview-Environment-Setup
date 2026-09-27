# Version 3: Windows installer with WSL provisioning

## Decisions

The accepted implementation keeps Windows, a dedicated `KiloLink-Ubuntu` WSL 2
distribution, Docker Engine and full NDI Tools. Applications follow the latest
stable vendor releases at each install/update, as requested. They are not frozen
to a tested manifest. `packages/applications.json` records that policy and the
sources; it is not a lockfile. Repair preserves the running KiloLink image.

## Installation and ownership

1. The release executable opens the native Server/Client wizard immediately.
   Its review page includes the John Lightfoot EULA and vendor licence acceptance.
   An embedded WiX Burn package runs quietly after review, installing or upgrading
   the configuration application through MSI. MSI owns only files under Program Files
   and its Start-menu shortcut. It can repair, upgrade or remove those files using
   normal Windows Installer behavior.
2. In the same window, successful package installation starts the provisioner
   with the reviewed role/settings. There is no second wizard or Launch button.
   The installed **Kiloview Configuration** app remains available for future use.
   Server setup automatically installs, repairs and updates supported components.
   Adapter selection is read-only; IP/DNS configuration belongs to the user.
3. WSL remains registered to that account. Boot/logon watchdog tasks keep the
   distro running. Installing the MSI as SYSTEM does not create a SYSTEM-owned
   distro. Provisioning still requires the intended administrator account.

There are no long-running WSL, apt, Docker or NDI custom actions inside the MSI
transaction. A successful MSI installation means the configuration application
was installed; server readiness is reported only by a successful provisioner run.
The UI reports completion only after provisioning and health checks finish.
Package failure stops provisioning. If package installation requires a restart,
the user is instructed to restart and reopen setup; service-stage restarts retain
the existing automatic continuation. Cached Windows packages retain normal
repair/uninstall support without launching a second configuration window.

The installer is free under MIT, copyright (c) 2026 John Lightfoot. The embedded
EULA explains separate vendor licences and PC Agent's non-commercial restriction.
The bundle includes WiX's MS-RL licence and corresponding 5.0.2 source archive.
WiX is a pinned build dependency; that does not pin installed vendor applications.

## Maintained code

- `launcher/`: native C# configuration UI, progress, networking and vendor process isolation.
- `src/Provisioner/`: parameter/core, WSL, configuration, Linux, package, ownership,
  Discovery, startup/health and operation modules.
- `Build-Provisioner.ps1`: assembles and parses the distributable PowerShell engine.
- `installer/Application` and `installer/Bundle`: MSI and Burn packaging.
- `version.json`: application/MSI/bundle version; `global.json`: build SDK.
- `tests/`: isolated engine/native process/UI, shell recovery and MSI/licence checks.
- `.github/workflows/installer.yml`: build and regression workflow; uploads unsigned installers.

`Install-KiloLinkSuite.ps1` remains a generated standalone deployment interface for
existing automation. The root EXE remains a portable development build. Release
the bundle under `artifacts/installer`, not the portable EXE under the same name.

## Downloads and change records

NDI's current Tools link is resolved from its official page. The downloaded EXE
must pass Authenticode and vendor publisher checks. If the advertised version is
ambiguous, the signed package supplies the version; an unidentified download link
fails closed. NDI does not provide a separately verified checksum in this flow;
the locally recorded SHA-256 is an audit identity, not an independent vendor
attestation. PC Agent uses a stable production release with its published hash,
archive validation and binary identity checks. These packages are staged before
installation and checked again when consumed. No vendor binaries are bundled.

KiloLink uses the vendor's `latest` image on fresh install/update. Docker resolves
the image content identity before replacement; the full resulting container
inspection is retained in the backup directory. The main `Setup` action also
updates WSL and Ubuntu/Docker packages, with a KiloLink backup before apt upgrades.
The advanced script `Update` action remains limited to applications and `Repair`
retains the running image. Recovery, unverifiable ownership or unsupported settings
still require attention; the unified flow does not discard state to force success.
Latest releases are not a compatibility guarantee; qualify the deployed versions
on the intended network and retain backups.

State under `C:\ProgramData\KiloLink` includes:

| Path | Purpose |
| --- | --- |
| `installer-config.json` | Desired configuration, written atomically |
| `installation-components.json` | Existing role/owner receipt |
| `Operations/<id>.json`, `last-operation.json` | Durable steps, failures and restart checkpoints |
| `Packages/*.json` | Verified downloaded version, source, size and SHA-256 |
| `installed-package-set.json` | Last healthy server application's observed NDI version and KiloLink source reference |
| `Backups/<id>` | Consistent KiloLink data archive, checksum, before/after container inspection and recovery status |

The journal supports diagnosis and safe reruns; it is not a transaction across
Windows, NDI and apt. Restart continuation rechecks actual state. A system crash
during container replacement requires recovery inspection before another attempt.
Old watchdog tasks are disabled during backup/replacement so they cannot restart
a container while its data is being archived. New watchdogs also use a Linux lock.

Read-only `-Action Plan` and `-Action Inspect` report policy/configuration without
elevation, downloads or probing live Linux. They are descriptive, not a network
or dependency compatibility dry run. Elevated `Verify` performs service readiness;
`Backup` creates a consistent data archive. See [RECOVERY.md](RECOVERY.md).

From 3.0.1, readiness probes the local web address (`127.0.0.1`) and reports the
LAN address separately for verification from another device. Server provisioning
rejects a Public or unreadable profile on the selected adapter before downloads
or configuration changes, matching the Domain/Private Windows firewall rules.
It does not change network trust automatically. A working local service with a
Public profile is reported as a network access problem rather than a web timeout.

## Migration from 2.1.x

Run the new release executable as the existing server owner. It reads the
existing ProgramData configuration, receipts and tasks in the same wizard. Use
`-Action Backup` before migration if a separate backup is wanted, then the main
**Set up / update server** action to refresh the platform. Existing
data paths and ports are retained. The provisioning engine points future
maintenance/reboot continuation to the MSI-installed app when running from it.
Keep the original account; changing WSL ownership is a separate migration.

Removing the configuration MSI retains server services/data. Server-role removal
through the Windows server-role entry remains explicitly destructive to the dedicated distro
and live data, with a separate confirmation; previously created Windows backups
are retained. Shared NDI Tools, PC Agent and unrelated WSL distributions remain.

## Qualification before production release

Local automated checks do not install vendor software, run WSL or restart Windows.
The installer is unsigned. Consult the release's GitHub Actions run for CI status.
Complete these tests on a disposable Windows 11 machine with virtualization:

- Fresh single-window setup/EULA, silent package installation, server deployment and reboot continuation.
- Boot with and without owner sign-in; confirm supported startup behavior.
- Upgrade a 2.1.x server and a previous MSI version; repair/remove the app without changing server data.
- NDI Tools update, existing NDI file locks, vendor restart requirement and shared Discovery restoration.
- KiloLink healthy/unhealthy replacement, insufficient Windows backup space,
  interrupted WSL/Windows operation, and manual recovery of actual database data.
- Linux flock/Windows-task exclusion with actual watchdogs and Docker restart policy.
- Runtime maintenance, partial apt failure, firewall/streaming across physical NICs,
  real Kiloview devices and real NDI discovery clients.
- Windows paths with spaces, restrictive ACLs, 100/150/200% DPI and a small screen.

Sign the application, MSI and final Burn bundle with the project's trusted signing
certificate before a signed release. No certificate or signing credentials were
available for this build.
