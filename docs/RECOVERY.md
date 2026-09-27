# KiloLink data backup and recovery

The configuration application and its MSI own application files only. Removing
the Windows installer does not remove WSL, vendor tools, services or server data.
Use the configuration application's server removal action to remove that role.

## Normal backup

Select **Back up KiloLink data**, or run the installed provisioner as the original
server owner in elevated Windows PowerShell:

```powershell
& 'C:\Program Files\Kiloview\Environment Setup\Install-KiloLinkSuite.ps1' -Action Backup
```

KiloLink stops during the archive and returns to its prior running state. Backups
are stored in `C:\ProgramData\KiloLink\Backups\<id>`. A successful backup contains
`data.tar`, `data.tar.sha256`, `container.json`, `deployment.json`, and `status`.
Copy completed backups to a separate disk. Backups may contain credentials and
private application data; restrict access and protect off-machine copies.
They contain KiloLink application data, not an entire Ubuntu/Windows system image.
Old backups and stopped previous containers are retained; monitor available disk
space and remove them deliberately after testing the new deployment.

## Replacement and automatic recovery

Application replacement first acquires the exact image, then stops KiloLink,
archives its data, records the original container, and renames that container.
The replacement must pass a running-state and HTTP readiness check. If it fails,
the provisioner removes the replacement, verifies and restores the archive, and
returns the previous container to its original running state. A backup failure
prevents replacement. The old container's restart policy is disabled while it is
retained so a reboot cannot start both versions against the same data.

The watchdog and replacement use the same Linux maintenance lock. An interruption
leaves a recovery marker and prevents subsequent managed startup/replacement.
The Windows watchdog task is also disabled during replacement to cover upgrades
from older watchdog versions. `watchdog.json` records its prior state; a failed
recovery leaves it disabled until an operator completes recovery.
This does not provide a transaction across NDI, Windows networking, and Linux
package upgrades. `MaintainRuntime` can update system packages irreversibly; take
a full WSL export/system backup before runtime maintenance if that recovery level
is required.

## Interrupted operation

1. Do not delete `recovery-required`, rename a backup, or run repeated repairs to
   bypass the guard. Read `last-operation.json`, `Operations`, and installer logs
   under `C:\ProgramData\KiloLink`. Identify the backup whose `status` is `pending`
   or `recovery-required`. Preserve a separate copy before manual recovery.
2. Open an elevated terminal as the original Windows server owner. Stop the
   **KiloLink WSL Startup** scheduled task. Enter the dedicated distribution with
   `wsl.exe -d KiloLink-Ubuntu -u root`.
3. Read `/var/lib/kilolink/recovery-required`. It identifies the Windows backup
   directory mounted through `/mnt/c/...`. Inspect `deployment.json` and
   `container.json`; confirm the data path, previous container identity and image.
   Do not restore an archive over a running container.
4. Acquire the same lock with `exec 9>/var/lib/kilolink/maintenance.lock` then
   `flock -x 9`. Verify Docker responds (`docker info`). Set `backup` to the exact
   recorded Linux backup path and run `sha256sum -c "$backup/data.tar.sha256"`.
   Stop if it fails. The checksum records the original archive path; if recovering
   a relocated copy, compare its SHA-256 to the recorded hash explicitly.
5. Inspect `docker ps -a`. If a replacement occupies `KLNKSVR-pro`, stop and remove
   it only after confirming the retained `KLNKSVR-pro-previous-<id>` container is
   the original. If no renamed container exists, inspect the original carefully:
   the failure may have occurred before replacement. A missing archive requires
   manual assessment, not an empty-data restore.
6. Restore `data.tar` into the original data directory, preserving Linux ownership,
   ACLs and extended attributes (`tar --numeric-owner --acls --xattrs`). Remove
   replacement data only after validating the archive and confirming every writer
   is stopped; keep a copy for diagnosis. Rename the retained original container
   to `KLNKSVR-pro`. Restore its recorded restart policy and start it if appropriate.
7. Verify KiloLink's web UI, existing devices and data. Only after recovery succeeds,
   write `rolled-back` to that backup's `status`, remove the Linux recovery marker,
   and release the lock (`flock -u 9`). Restart the scheduled task and run the
   provisioner's `-Action Verify`. Use Repair if the saved desired configuration
   differs from the recovered container.

A Windows reboot or loss of power can occur between filesystem writes and Docker
commands. The marker deliberately requires this inspection rather than guessing
which data version should be started. A generic HTTP check cannot validate every
KiloLink feature; inspect production devices after every change.
