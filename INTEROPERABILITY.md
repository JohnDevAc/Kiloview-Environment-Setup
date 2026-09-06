# Suite deployment behavior

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

