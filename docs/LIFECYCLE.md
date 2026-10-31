# Toolbox lifecycle: 3.1.1

The 3.1.1 Server readiness and storage changes passed isolated regressions and
coordinated Windows 11 VM acceptance for fresh Server roles and reboot recovery.
The existing lifecycle implementation retains its earlier validation for updates,
recovery and role removal. See [release notes](releases/v3.1.1.md) for the exact
scope and remaining limits. A local build does not publish or install a release.

## Entry points and packages

`toolbox-lifecycle.json` accompanies the native executable in the verified ZIP,
MSI installation and retained maintenance directory. It advertises schema 1,
product `environment`, native `--lifecycle-request <absolute request.json>` and
inspect/install/update/repair/uninstall/remove-role/remove-app/backup/maintain-runtime.
The standalone engine accepts `-LifecycleRequestPath` with the same JSON.
For script mutations also supply the reviewed action, role, licence acceptance
and configuration/removal flags. A JSON request alone accepts no agreement.

Build with Windows PowerShell 5.1:

```powershell
.\Build-Setup.ps1
.\tests\Installer.Regression.ps1
.\tests\Progress.Regression.ps1
.\tests\LifecyclePersistence.Regression.ps1
.\tests\LifecycleConcurrency.Regression.ps1
.\tests\LifecycleRoles.Regression.ps1
.\tests\ReleaseMetadata.Regression.ps1
.\tests\NdiMetadata.Regression.ps1
.\tests\WslBootstrap.Regression.ps1
.\tests\WslConsole.Regression.ps1
.\tests\NativeResolution.Regression.ps1
.\tests\WslReadiness.Regression.ps1
.\tests\LinuxSources.Regression.ps1
.\tests\Storage.Regression.ps1
.\tests\WslLocation.Regression.ps1
.\tests\InstallerLogging.Regression.ps1
.\tests\WatchdogLifecycle.Regression.ps1
.\tests\ResumeContinuation.Regression.ps1
.\Build-Installer.ps1
.\tests\Packaging.Regression.ps1
.\tests\Test-QuietInstaller.ps1
```

Fresh-install distribution is `artifacts\Kiloview-Environment-Setup-Lifecycle.zip`
with its adjacent `.sha256`. It contains exactly the native installer, its checksum
and the descriptor. The native EXE under `artifacts\installer` includes Burn/MSI;
the root EXE is a portable development build. No package is published by building.
The repository NuGet.Config supplies the official source for pinned WiX 5.0.2;
it does not edit the account's NuGet configuration.

## Request and result

Use a new GUID operation ID/directory for each operation, owned by the original
Windows user. Protect its DACL so only that user, SYSTEM and Administrators can
write. Put UTF-8 `request.json` and a separate `result.json` in the same directory:

```json
{
  "schemaVersion": 1,
  "operationId": "ccfe2790-2bb1-46fd-8819-4d3b4ce426a3",
  "productId": "environment",
  "action": "inspect",
  "resultPath": "C:\\owned-operation-directory\\result.json"
}
```

Optional fields are `role` (client/server), `preserveData` (true by default),
and `requestedVersion`. Omit role to choose it once in the native owner UI.
The request is checked before elevated writes; its hash crosses UAC and is
retained with reviewed intent for reboot. Redirecting links, hard-linked files,
unknown reparse tags, foreign writers, ambiguous Windows paths, mismatched
results and unsupported schemas are rejected. Known non-redirecting OneDrive
cloud tags are allowed. A rejected untrusted output path may have no result;
that is never success.

Results are atomic and echo schema, ID, product and action. Outcomes are running,
succeeded, no-change, cancelled, partial, failed, blocked and restart-required.
Exit codes are 0 for success/no-change, 1602 for cancellation, 3010 for restart,
1618 for contention and nonzero for failure/partial/other blocks. A parent waits
for elevation and the actual worker. Cancellation after known changes is partial.

The worker owns the result until it exits, including after emitting a terminal
stdout event. Only then may the native host supply a missing-result fallback.
Result and journal writes use a per-destination cross-process mutex with a
five-second acquisition limit. Each write flushes a sibling temporary file,
preserves the destination access ACL, and uses a single handle-based rename
over the destination. Cooperative readers keep a complete old snapshot while
new opens see the replacement. This avoids the partially renamed files possible
with `File.Replace`; there is no delete, truncate or copy fallback. Verified
sharing conflicts retry for at most five seconds; permanent access failures do
not retry. A persistent failure retains the prior file and exits unsuccessfully;
the journal records the intended outcome and separate persistence error when
writable. Agent cancellation leaves its step incomplete and retains observed
NDI effects. Native progress reaches 100% only after success and worker exit.

NDI package-page metadata runs in a separate read-only PowerShell worker with
a 60-second total deadline covering request, response decoding and parsing.
Responses are limited to 4 MiB; HTML parsing has explicit regex and elapsed-time
limits and does not use PowerShell 5.1's unbounded lazy link parser. The parent
emits progress and five-second lifecycle heartbeats during the probe. A timeout
stops only that read-only child and returns `ndi-metadata-timeout`; unavailable
or invalid metadata returns `ndi-metadata-unavailable`. Missing or ambiguous
version labels still require verification of the signed installer. Server
preflight reports progress before downloads and before role receipts or Windows
feature changes. This deadline is not an interactive Cancel feature; closing
the owner UI while its deployment worker is active remains blocked.

Server setup, repair, update, resume and runtime maintenance check available
Windows host storage before large package downloads or WSL/component changes.
The installer safety policy reserves 16 GiB for distro growth, 2 GiB for Windows
and NDI working space, and 2 GiB for download/state staging. Different purposes
on the same volume are added (normally 20 GiB); duplicate paths for one purpose
on that volume are counted once. This is a conservative headroom snapshot, not
a prediction or guarantee of final installation, backups or application-data
size. Existing data and workloads can need substantially more space.

The check uses `GetDiskFreeSpaceEx` available-to-caller bytes (including quotas)
and Windows volume identities, resolving mounted folders/junctions rather than
assuming drive C or counting unallocated disk space. Existing WSL distributions
retain their registered `BasePath`, including moved disks. New managed distros
use a unique per-attempt folder under the current user's LocalAppData
`Kiloview Environment Setup\WSL`, explicitly passed through WSL `--location`.
The runtime must advertise this option; unsupported WSL does not fall back to
an unchecked location. The bounded read-only help probe accepts exits zero and
minus one only when an option line advertises `--location`; WSL 3.0.3 returns
minus one with valid informational help ([upstream issue](https://github.com/microsoft/WSL/issues/6192)).
Unexpected help exits return `wsl-location-probe-failed`, missing capability
returns `wsl-location-unsupported`, and timeouts/persistence failures retain
their original cause. Normal native command failure handling is unchanged.
Existing/orphaned target folders are never adopted or
deleted. Storage lookup requires an absolute local drive path; unknown or
unreadable locations fail closed. See Microsoft's [WSL disk-space guidance](https://learn.microsoft.com/en-us/windows/wsl/disk-space)
for why Linux virtual disk capacity is not Windows host free space.

Low capacity returns `insufficient-disk-space` with the actual volume and GiB
to free; an unresolvable probe returns `storage-preflight-unavailable`. Detailed
paths, byte counts and per-purpose reserves go to diagnostics. Neither preflight
failure creates a recovery latch. Client setup, Inspect, Verify, source-only
diagnostics and removal do not require the Server installation reserve. They
still need enough space for their own logs and any work they perform.

Linux source readiness runs inside the selected distro and is recorded as its
own deployment step. Its diagnostics retain Docker endpoint stages and complete
APT output. A first package-index refresh has a four-minute Linux deadline with
a ten-second termination grace; source failures still fail the check through
`apt-get update --error-on=any`. This only refreshes metadata and never installs
or upgrades packages. A metadata timeout returns `linux-package-check-timeout`;
other source-check exits return `linux-package-check-failed`. Native command
observation and lifecycle persistence failures retain their existing recovery
instructions. Successful completion requires both exit zero and the probe's
completion marker. Detailed output stays in diagnostics; the UI identifies the
failed check without inferring that Windows or Linux internet access is down.

Missing WSL runtime installation uses [Microsoft's documented command](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#install),
`wsl.exe --install --no-distribution --web-download`. Native switches
remain unquoted so WSL's raw-token dispatcher recognizes them; argument data
containing whitespace, quotes or empty strings retains Windows escaping. The
runner selects the first application in PowerShell's command precedence and
validates one absolute executable path: `Get-Command -CommandType Application`
can return multiple PATH matches even without `-All`. Readiness exceptions and
nonzero exit codes are written to the diagnostic log, limited to one identical
message per probe every 30 seconds, without adding status messages to the UI. The
inbox bootstrap receives a real hidden console on a private desktop; closed
redirected input is not suitable for this installation path. Its independent
supervisor is compiled from embedded source into a protected operation directory.
It assigns the child to a job before execution and waits for the entire tracked
process tree. A durable pending record is written before the supervisor starts.
Timeout or a producer error leaves that supervisor and servicing running, records
recoveryRequired, and blocks retry. Verify requires the job and supervisor to
have exited and a matching durable completion receipt; absence of a process or
job alone is insufficient. No automatic servicing termination occurs.

Passive WslService or registered Appx evidence gates status and distribution
queries: the System32 executable alone can be an installation stub whose probes
spawn an interactive bootstrap. A zero bootstrap exit without an installed
runtime is a failure, not a reason for repeated automatic restarts. Exit 3010
retains the normal restart continuation contract. Bootstrap failure adds
`wsl-runtime-install-failed` with retry guidance. Supervisor timeout and result
persistence diagnostics keep their original recovery instructions. Optional
feature activation reports the actual feature before servicing and verification
after it returns, without advancing the percentage or adding background writers.

Distro launch checks use the bounded native runner with at most 30 seconds per
CLI invocation. Retries and pauses share the remaining readiness wait budget;
the final failure uses the last observed output/exit instead of starting another
diagnostic after the deadline. A probe timeout is distinct from a nonzero native
exit and does not leave a stale operation error after a successful retry.
Progress and lifecycle heartbeats continue during these waits. A heartbeat or
result persistence failure propagates after cleanup instead of becoming an
ordinary readiness failure. Cleanup targets only the owned probe CLI; it does
not terminate the distribution, WSL services or unrelated processes, and does
not claim generic descendant cleanup. Terminal wait expiry is reported as
`wsl-distro-readiness-timeout` with the retained launch diagnostic.

Diagnostic appends share the file with concurrent readers and briefly retry
sharing conflicts. A persistently unavailable diagnostic log falls back to the
setup host/transcript, with a throttled warning, without aborting maintenance or
replacing the actual native exit/error. This best-effort diagnostic behavior does
not apply to lifecycle results, journals or ownership records: their failures
still stop the owning workflow. If such a producer failure prevents observing a
mutating native command's exit, the owner retains its PID/start/path and records
recovery required before releasing the wrapper. The command is not terminated.
Verify refuses a still-running recorded CLI; package/recovery state must also be
inspected before retry. The operation journal also retains that command identity
and blocks retry if the separate pending file could not be written. Storage
failures retain the original error and explicit recovery guidance.

After a resumed worker durably reports failed/partial, the operation owner removes
its matching automatic logon task and verifies removal. Request, configuration,
logs and continuation state remain for explicit retry; a later required reboot
registers a fresh trigger. The task must match the operation, executable, arguments
and user SID. Running results, unconfirmed children, pending recovery and failed
result persistence retain their owner; restart-required and normal success keep
their existing continuation/cleanup behavior. If task inspection or removal
cannot be confirmed, the original failure is retained, recoveryRequired becomes
true, and the result instructs the user to inspect the exact task before another
sign-in or retry. The original restart counter remains distinct from result attempt.

Inspect is non-elevating and never starts WSL or the Agent's normal launch path.
It separates installed/configured/running/healthy evidence; unknown remains null.
The Agent's validated descriptor is used when present, including its own
onboarded/network evidence. Legacy Agent evidence cannot establish health.
Inspection considers both native and engine locks, the journal and recovery
records before reporting safeToRetry. Process absence alone never means success.

## Actions and recovery

- `update` uses application updates; Windows WSL/Linux/Docker updates require
  explicit `maintain-runtime`. Fresh Server setup still provisions the platform.
- A current Client does not download/reinstall NDI unnecessarily. Required Client
  applications and server Discovery are checked separately. Explicit repair can
  repair the matching package; it cannot downgrade a newer installed version.
- Completing a partial Client setup uses `install`, with Client selected in the
  owner UI. `repair` deliberately requests component repair and can reinstall
  a healthy matching NDI package. The parent must not label that action as simple
  completion while expecting healthy components to be retained.
- Generic `uninstall` means role removal. Client removal removes its role record
  and retains shared software. Server removal defaults to **Remove services,
  keep data/environment**. `retained-server.json` records inactive state, the
  original owner and configuration; the dedicated distro/disk footprint remain.
  A purge request still requires the separate native checkbox or explicit
  `-ConfirmRemoval -PurgeData` script flags.
- Stopping a Windows startup task is not proof that its Linux watchdog exited.
  Removal, container backup/replacement and task refresh disable its triggers,
  acquire the existing Linux maintenance lock and inhibit known watchdogs before
  waiting for their exact wrapper processes and holders of the legacy maintenance
  descriptor to exit naturally. Lock acquisition
  and process retirement are bounded; no distribution or process tree is killed.
  New watchdogs hold a lifetime singleton lock. The Git Bash regression runs real
  children and `/proc` identity checks with temporary fake Docker/service commands
  and an atomic-directory advisory-lock fixture; actual Linux `flock` and the
  installed legacy-loop migration still require VM acceptance.
  The compatibility `recovery-required` file is an exclusive hard link to the
  product's exact `watchdog-stop` token. Genuine, foreign or ambiguous recovery
  markers are never overwritten or cleared. Preserving role removal retains an
  inactive-role token; only explicitly reviewed Server setup/repair can clear it,
  after old loops are quiescent. Interrupted shutdown keeps `pending-watchdog.json`
  and the operation journal's pending watchdog identity,
  reports recovery required and offers Verify. This Verify path confirms shutdown
  for a retry while retaining inhibition; it does not restart services or mark
  the interrupted removal successful. The stopped/no-restart container guard
  remains mandatory.
- `remove-app` removes only this product's registered MSI. The protected,
  hash-verified maintenance executable/engine survive independently of MSI.
  Removal verifies remaining tasks, files, registrations and owned firewall state;
  failures retain retry/recovery evidence instead of suppressing it.
- Unattended commands have duration/stall limits. Safe timed-out probes are
  stopped. Uncertain mutating workers and Windows Installer transactions are
  retained and recorded in `pending-process.json`; retries are blocked. The
  private unattended NDI installer has a 30-minute limit and scoped cleanup.
  Agent licence/UAC waits are reported as user input and are not blindly killed.
- Open Environment and select **Verify after an interrupted operation** after
  resolving the reported cause. Advanced equivalent: retained engine `-Action
  Verify`. This checks the prior worker/recovery and component state before
  clearing the retry block. Server verification can start its Linux environment.
  Unresolved data replacement follows [RECOVERY.md](RECOVERY.md); verification
  does not silently restore data or label an interrupted attempt successful.

## Harmless external fixture

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\EnvironmentLifecycle.Fixture.ps1 -LifecycleRequestPath C:\owned-operation-directory\request.json -FixtureOutcome partial
```

Supported fixture outcomes: succeeded, no-change, cancelled, partial, blocked,
restart-required, crash. The actual parser, atomic writer, journal and exit
mapping are used. Only the owned operation directory/fixture-state is written.
No elevation, installer, WSL, network, task or registry mutation occurs. Crash
leaves a running result and exits 7; restart does not schedule/restart Windows.

## Disposable Windows 11 acceptance

Use verified package hashes and snapshots, an interactive original owner account,
working virtualization/WSL and a supported private production adapter. Keep these
tests separate from isolated fixtures:

1. Inspect before installation: no UAC, no WSL start, honest absent/unknown states.
2. Fresh Client and Server: select role once, review licences, accept UAC, complete
   the same operation; distinguish Agent installed/configured/onboarded readiness.
3. Repeat a healthy Client update: no NDI payload download or vendor installer.
   Remove a required application in a disposable snapshot and verify repair.
4. Update Server applications and separately maintain runtime. Check saved data,
   backups, health, and that ordinary Update does not perform runtime upgrades.
5. Decline UAC/licence, block downloads, corrupt a staged package and hold an NDI
   file. Confirm cancellation/partial/failed outcomes and no unverified execution.
6. Exercise actual package and feature reboot/resume: same operation ID, increased
   attempt, preserved reviewed settings, no repeated role/licence acceptance and
   no Ready result until verification. Reopen Toolkit during progress/restart.
7. Remove the configuration app, then use retained maintenance. Remove the role
   preserving data; confirm inactive state, stopped container/restart policy,
   restored Discovery, retained disk footprint and same owner. Repeat removal.
   Test explicit purge only in a disposable snapshot.
8. Interrupt replacement/removal at controlled boundaries and exercise recovery,
   failed verification and safe retry. Check actual device streaming, LAN access,
   Windows firewall, discovery clients and boot behavior independently.

Local automated success does not establish these hardware/system journeys.
