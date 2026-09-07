# Suite deployment behavior

## Client update diagnostics and validation — 7 September 2026

Client setup records the staged PC Agent Setup path and process exit code. A failure after NDI Tools finishes now reports the surviving Agent/Setup versions and configured-state evidence, retaining the original error and any NDI restart requirement. Updated application files are not sufficient to suppress a genuine setup failure: configuration, startup or firewall work may fail after replacement.

`tests/ClientUpdate.Regression.ps1` adds eleven isolated native-process scenarios to the main regression harness. A harmless compiled fixture upgrades an older Agent/Setup pair through the real archive, version, process-wait and configuration-read paths. It covers normal/fast exits, restart, cancellation, missing configuration, mixed versions, failures before/after file replacement (including NDI restart requirements), a concurrently installed newer pair and staged archive corruption. Vendor installation remains mocked; no production agent, NDI configuration, registry, service or network settings are changed.

## Additional QA corrections — 6 September 2026

Client setup preserves unsupported component receipts and unknown roles by refusing to overwrite them. A completed Discovery-restoration marker alone no longer recreates server ownership during removal. Configured Client evidence now validates the endpoint/adapter GUIDs, IPv4 host address and prefix, including rejection of loopback, link-local, multicast, network and broadcast addresses. The corrected executable passes 95 isolated regression checks.

## QA follow-up — 6 September 2026

The schema-1 component receipt now records `serverOwnerSid`. Server setup/update/repair/resume/uninstall require that owner's signed-in administrator desktop, because WSL distributions belong to a Windows account. Client setup preserves an existing server owner. Legacy ownership may be migrated from the KiloLink startup task principal; ambiguous ownership fails before any removal. Use the original owner's desktop, or recover missing ownership evidence from the original installation's backup before retrying.

A `discovery-ownership.json` snapshot preserves the previous Discovery service identity, startup mode, delayed Automatic flag and running state, task XML/state, and exact configuration bytes. Repeated repair preserves the original snapshot. Removing server ownership restores it, or disables a newly managed Discovery service so reboot cannot restart it. Shared NDI Tools and independently installed Agent remain installed. Client-only removal makes no server, WSL or Discovery changes.

Interrupted removal retains verified ownership until completion and records completed Discovery restoration so retries cannot undo it. The setup executable was rebuilt from the corrected script; 92 isolated regression checks pass, including account boundaries, service restoration, client-only behavior and download gating. Windows restart/UAC and vendor runtime acceptance remain controlled-machine checks, not build steps.

Client installs NDI Tools and PC Agent; it does not require local WSL, KiloLink or Discovery. Server installs/manages the selected server components. A host may have both roles. The schema-1 receipt at `%ProgramData%\\KiloLink\\installation-components.json` records selected roles separately from server settings; Toolkit checks actual component state against it.

Server setup runs from the signed-in administrator account that will own WSL/startup. Alternate administrator credentials for a different desktop are rejected before server changes. Client completion checks the original desktop user's Agent profile, matching companion Setup's account ownership.

The backend checks required download sources before install, update, repair and resumed operations. Client stages and verifies both packages before starting either installer. GitHub metadata alone is insufficient: the selected asset must be accessible. NDI signatures and publishers, Agent package hashes/sizes/product versions, and archive safety remain mandatory. Reused loose files are extracted again from the verified archive before launch.

The static-address action performs a source-only prerequisite check before its separate, explicitly confirmed network change. After licence review, the install action acquires and verifies payloads and rechecks readiness. A successful source probe cannot guarantee that connectivity will persist through a later operation; network changes have their own rollback and failed setup can be retried.

Windows checks resolve WSL and Ubuntu download endpoints before enabling features. WSL uses its web-download path; healthy-runtime repair avoids an unnecessary update. Linux package/repository checks run inside the actual WSL distribution. First-time Linux checks necessarily follow WSL/distro installation; failure leaves those prerequisites available for a later retry. Container pulls still complete before replacing the running container. Existing services may need a restart for prerequisite changes; failure does not mean the entire installation was rolled back.

Sources-only diagnostics are available as `-Action CheckDownloads`. Blocked operations report the source and support returning to setup and retrying. HEAD-rejecting sources use a bounded header-only GET fallback. Transfers have connection/inactivity limits. Internet access may use a different adapter from the production LAN.

For an explicit offline Client package set, invoke the PowerShell entry point with `-Action InstallClient -AcceptLicenses -PackageDirectory <directory>` after reviewing vendor licences. Supply:

* `NDI-Tools.exe`: the official signed NDI installer.
* `PC-Agent.zip`: the complete stable companion release archive.
* `pc-agent-release.json`: saved production GitHub release metadata, including selected asset name, URL, size and SHA-256 digest.

Offline input is verified by the same package checks and does not fall back to downloading missing files. This option does not provide an offline WSL/Ubuntu/Linux package bundle for a fresh Server installation. Already installed applications and uninstall remain available offline.

Suite Discovery is fixed to TCP 5959. KiloLink web settings reject TCP 8080 (Arena), 8091 (Job Configurator) and 8094 (Agent). Windows firewall rules retain required media ports but are restricted to Domain/Private profiles and local-subnet peers; TCP is bound to the selected local IP. Combined effective policy still needs a second-NIC/Public-network deployment test.

Server removal stops managed Discovery startup and removes server ownership, its dedicated distro, tasks and rules. Shared NDI Tools and independently installed PC Agent remain available for clients/Arena. Remove those separately using Windows Apps only when no longer needed.

Rebuild the embedded executable with `Build-Setup.ps1`, then run `tests/Installer.Regression.ps1`. Tests use mocks/fixtures and do not install vendor software. Controlled-machine acceptance remains required for WSL feature installation, different-account elevation and reboot/resume.

WSL behavior is based on Microsoft's [command reference](https://learn.microsoft.com/en-us/windows/wsl/basic-commands) and [distribution catalog](https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json).
