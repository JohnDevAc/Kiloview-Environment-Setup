function Repair-Suite {
    param(
        [switch]$UseSavedConfiguration,
        [switch]$LicenseAccepted,
        [switch]$BringCurrent,
        $RequestedConfiguration
    )
    Set-OperationOutcome 'Running' $(if ($BringCurrent) { 'Setting up and updating the server platform.' } else { 'Installing or repairing the suite.' })
    $old = Get-SavedConfig
    if ($null -ne $RequestedConfiguration) {
        $config = $RequestedConfiguration
    } elseif ($UseSavedConfiguration) {
        if (-not $old) {
            throw 'A saved configuration is required for unattended repair.'
        }
        $config = ($old | ConvertTo-Json -Depth 5) | ConvertFrom-Json
        Sync-PrimaryLanAddress $config
    } else {
        $config = Read-SuiteConfig -UseSaved
    }
    if (-not $LicenseAccepted -and -not (Confirm-LicenseAcceptance)) {
        Write-Host 'Operation cancelled.' -ForegroundColor Yellow
        Set-OperationOutcome 'Cancelled' 'Installation was cancelled before changes were applied.'
        return
    }
    Assert-ServerDownloads $config
    Start-DeploymentJournal $Action $config
    Save-ComponentReceipt 'server'
    Save-DiscoveryOwnership
    Save-Config $config
    Register-MaintenanceEntry
    $showProgress = $LauncherMode -or $Action -in @('Menu', 'Resume')
    $succeeded = $false
    if ($showProgress) { Start-SuiteProgress -Activity 'Installing KiloLink Server Pro and NDI' -Status 'Preparing the saved configuration' }
    try {
        Set-SuiteProgress -Percent 5 -Status 'Checking Windows and WSL prerequisites'
        if (-not (Invoke-DeploymentStep 'Windows prerequisites' { Ensure-WslFeatures })) { return }
        Set-SuiteProgress -Percent 15 -Status 'Configuring mirrored multi-adapter networking'
        Invoke-DeploymentStep 'WSL networking' { Ensure-MirroredNetworking }
        Set-SuiteProgress -Percent 22 -Status 'Preparing the dedicated Ubuntu environment'
        $distro = Invoke-DeploymentStep 'Dedicated Ubuntu distribution' { Ensure-Ubuntu $config }
        if (-not $distro) { return }
        Set-SuiteProgress -Percent 30 -Status 'Preparing systemd, Docker Engine, and Avahi'
        Assert-LinuxDownloads $distro
        Invoke-DeploymentStep 'Docker and Avahi' { Ensure-Docker $distro }
        if ($BringCurrent) {
            if (Test-KiloContainer $distro) {
                Invoke-DeploymentStep 'Back up existing KiloLink before runtime updates' { Invoke-KiloReplacement $config -BackupOnly }
            }
            Invoke-DeploymentStep 'Update Ubuntu and Docker packages' { Update-SuiteRuntimePackages $distro }
        }
        Set-SuiteProgress -Percent 48 -Status 'Installing or validating KiloLink Server Pro'
        Invoke-DeploymentStep 'Reconcile KiloLink configuration' { Sync-KiloConfig $config -Latest:$BringCurrent }
        Set-SuiteProgress -Percent 60 -Status 'Installing or validating NDI Tools'
        Invoke-DeploymentStep 'NDI Tools' { Install-NdiTools -EnsureLatest:$BringCurrent }
        if ($script:NdiRestartRequired) { Request-RestartAndResume 'NDI Tools needs a Windows restart before server setup can continue.'; return }
        Set-SuiteProgress -Percent 70 -Status 'Configuring NDI Discovery Server'
        Invoke-DeploymentStep 'NDI Discovery service' { Configure-NdiServer $config }
        Set-SuiteProgress -Percent 77 -Status 'Opening Windows and WSL firewall ports'
        Invoke-DeploymentStep 'Firewall' { Install-FirewallRules $config }
        Set-SuiteProgress -Percent 84 -Status 'Creating browser shortcuts'
        Install-Shortcuts $config
        Set-SuiteProgress -Percent 89 -Status 'Installing the persistent WSL watchdog'
        Invoke-DeploymentStep 'WSL watchdog' { Install-StartupTask $config }
        Set-SuiteProgress -Percent 94 -Status 'Saving the suite configuration'
        Save-Config $config
        Set-SuiteProgress -Percent 96 -Status 'Verifying services and web access'
        Invoke-DeploymentStep 'Service health' { Test-SuiteHealth $config }
        Save-InstalledPackageSet $config
        Set-SuiteProgress -Percent 100 -Status 'Installation complete'
        $succeeded = $true
    } finally {
        if ($showProgress) { Stop-SuiteProgress }
    }
    if ($succeeded) {
        Clear-ResumeContinuation
        Show-SuiteSummary $config
        Set-OperationOutcome 'Completed' $(if ($BringCurrent) { 'Server setup and updates completed. Service readiness checks passed.' } else { 'Installation completed and service readiness checks passed.' })
    }
}

function Wait-ResumeNetwork {
    param([int]$TimeoutSeconds = 120)
    Write-Detail 'Waiting for Windows networking and DHCP to become ready...' Yellow
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-LanCandidates).Count -gt 0) {
            Write-Detail 'Windows networking is ready.' Green
            return
        }
        Wait-SuiteProgressInterval
    } while ((Get-Date) -lt $deadline)
    throw "No usable physical IPv4 adapter became ready within $TimeoutSeconds seconds after sign-in."
}

function Resume-Suite {
    Assert-ServerOwner
    $continuation = Get-ResumeState
    Remove-ResumeTask
    if (-not (Get-SavedConfig)) {
        throw 'Setup cannot resume because its saved configuration is missing.'
    }
    Write-Heading 'Resuming Kiloview Environment Setup after Windows restart'
    Start-SuiteProgress -Activity 'Resuming Kiloview Environment Setup' -Status 'Waiting for Windows networking and DHCP'
    try {
        Wait-ResumeNetwork
    } finally {
        Stop-SuiteProgress
    }
    if ((Get-PropertyValue $continuation 'Action' 'Repair') -eq 'Setup') {
        $previousAction = $Action
        try { $Action = 'Setup'; Repair-Suite -UseSavedConfiguration -LicenseAccepted -BringCurrent } finally { $Action = $previousAction }
    } elseif ((Get-PropertyValue $continuation 'Action' 'Repair') -eq 'MaintainRuntime') {
        $previousAction = $Action
        try { $Action = 'MaintainRuntime'; Maintain-SuiteRuntime } finally { $Action = $previousAction }
    } elseif ((Get-PropertyValue $continuation 'Action' 'Repair') -eq 'Update') {
        Update-Suite
        if ($script:OperationOutcome -eq 'Completed') { Clear-ResumeContinuation }
    } else {
        Repair-Suite -UseSavedConfiguration -LicenseAccepted
    }
}

function Update-KiloLink {
    param($Config)
    if (-not (Test-KiloContainer $Config.DistroName)) {
        throw 'KiloLink is missing. Choose Repair / Reconfigure.'
    }
    Write-Step 'Checking the current KiloLink image'
    $template = @'
set -euo pipefail
old_id=$(docker inspect -f '{{.Image}}' "__CONTAINER__")
docker pull "__IMAGE__"
new_id=$(docker image inspect -f '{{.Id}}' "__IMAGE__")
if [ "$old_id" = "$new_id" ]; then
    echo KILOLINK_CURRENT
else
    echo KILOLINK_UPDATE
fi
'@
    $target = ($Config | ConvertTo-Json -Depth 5) | ConvertFrom-Json
    $target.KiloLinkImage = $script:KiloImage
    $content = $template.Replace('__CONTAINER__', $script:ContainerName).Replace('__IMAGE__', [string]$target.KiloLinkImage)
    $output = Invoke-WslScript $Config.DistroName $content -Capture
    if ($output -contains 'KILOLINK_UPDATE') {
        Write-Detail 'A newer image was found. Recreating the container while retaining its data.' Yellow
        Recreate-KiloContainer $target -UpdateImage
        $Config.KiloLinkImage = $target.KiloLinkImage
        Write-Detail 'KiloLink updated.' Green
    } else {
        $Config.KiloLinkImage = $target.KiloLinkImage
        Write-Detail 'KiloLink is current.' Green
    }
}

function Update-Suite {
    Set-OperationOutcome 'Running' 'Updating the suite.'
    $config = Get-SavedConfig
    if (-not $config) {
        throw 'No saved configuration exists. Choose Repair / Reconfigure.'
    }
    if ($ConfigurationPath) { $config = Get-RequestedSuiteConfig $ConfigurationPath }
    Assert-ServerDownloads $config
    Start-DeploymentJournal $Action $config
    Install-NdiTools -UpdateOnly -PrepareOnly
    Save-ComponentReceipt 'server'
    Save-DiscoveryOwnership
    Save-Config $config
    Register-MaintenanceEntry
    $showProgress = $LauncherMode -or $Action -eq 'Menu'
    $succeeded = $false
    if ($showProgress) { Start-SuiteProgress -Activity 'Updating KiloLink Server Pro and NDI' -Status 'Preparing the saved configuration' }
    try {
        Set-SuiteProgress -Percent 6 -Status 'Checking Windows and WSL prerequisites'
        if (-not (Invoke-DeploymentStep 'Windows prerequisites' { Ensure-WslFeatures })) { return }
        Set-SuiteProgress -Percent 16 -Status 'Starting the dedicated Ubuntu services'
        $distro = Get-UbuntuDistro ([string]$config.DistroName)
        if (-not $distro) {
            throw 'Ubuntu is missing. Choose Repair / Reconfigure.'
        }
        $config.DistroName = $distro
        Invoke-Wsl $distro 'systemctl start docker && systemctl start avahi-daemon'
        Set-SuiteProgress -Percent 23 -Status 'Checking the selected server address and container settings'
        Sync-PrimaryLanAddress $config
        if (-not (Test-KiloContainer $distro)) { throw 'KiloLink is missing. Choose Repair / Reconfigure.' }
        Invoke-DeploymentStep 'Reconcile KiloLink configuration' { Sync-KiloConfig $config }
        Set-SuiteProgress -Percent 52 -Status 'Checking the KiloLink container image'
        Update-KiloLink $config
        Set-SuiteProgress -Percent 64 -Status 'Checking the NDI Tools package'
        Invoke-DeploymentStep 'NDI Tools' { Install-NdiTools -UpdateOnly }
        if ($script:NdiRestartRequired) { Request-RestartAndResume 'NDI Tools needs a Windows restart before the server update can continue.'; return }
        Set-SuiteProgress -Percent 76 -Status 'Refreshing NDI Discovery Server'
        Invoke-DeploymentStep 'NDI Discovery service' { Configure-NdiServer $config }
        Set-SuiteProgress -Percent 82 -Status 'Refreshing firewall rules and shortcuts'
        Invoke-DeploymentStep 'Firewall' { Install-FirewallRules $config }
        Install-Shortcuts $config
        Set-SuiteProgress -Percent 89 -Status 'Refreshing the persistent WSL watchdog'
        Invoke-DeploymentStep 'WSL watchdog' { Install-StartupTask $config }
        Set-SuiteProgress -Percent 94 -Status 'Saving the updated configuration'
        Save-Config $config
        Set-SuiteProgress -Percent 96 -Status 'Verifying services and web access'
        Invoke-DeploymentStep 'Service health' { Test-SuiteHealth $config }
        Save-InstalledPackageSet $config
        Set-SuiteProgress -Percent 100 -Status 'Update complete'
        $succeeded = $true
    } finally {
        if ($showProgress) { Stop-SuiteProgress }
    }
    if ($succeeded) {
        Show-SuiteSummary $config 'Suite update is complete'
        Set-OperationOutcome 'Completed' 'Update completed and service readiness checks passed.'
    }
}

function Invoke-UninstallCommand {
    param([string]$CommandLine)
    $exe = $null
    $arguments = ''
    if ($CommandLine -match '^\s*"([^"]+\.exe)"\s*(.*)$') {
        $exe = $matches[1]
        $arguments = $matches[2]
    } elseif ($CommandLine -match '^\s*([^\s]+\.exe)\s*(.*)$') {
        $exe = $matches[1]
        $arguments = $matches[2]
    }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        throw "Could not locate the NDI uninstaller from: $CommandLine"
    }
    if ($exe -match '(?i)msiexec\.exe$') {
        $arguments = $arguments -replace '(?i)(^|\s)/I(?=\s|\{)', '$1/X'
        $arguments += ' /qn /norestart'
    } else {
        $arguments += ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    while (-not $process.HasExited) {
        Update-SuiteProgressPulse
        Start-Sleep -Milliseconds 300
        $process.Refresh()
    }
    if ($process.ExitCode -notin @(0, 1605, 3010)) {
        throw "NDI uninstaller failed with exit code $($process.ExitCode)."
    }
}

function Remove-LegacyPortProxies {
    param($Config)
    if (-not $Config) { return }
    $address = [string](Get-PropertyValue $Config 'PublicIp' '')
    $web = [int](Get-PropertyValue $Config 'WebPort' 0)
    $link = [int](Get-PropertyValue $Config 'LinkPort' 0)
    if (-not $address) { return }
    $ports = New-Object Collections.Generic.List[int]
    if ($web -gt 0) { $ports.Add($web) }
    if ($link -gt 0) {
        $ports.Add($link)
        $ports.Add($link + 1)
    }
    foreach ($port in $ports) {
        & netsh.exe interface portproxy delete v4tov4 "listenaddress=$address" "listenport=$port" 2>$null | Out-Null
    }
}

function Uninstall-Suite {
    param([switch]$Confirmed)
    Assert-ServerOwner
    if (-not (Test-ServerOwnershipEvidence)) {
        Set-OperationOutcome 'Completed' 'No Environment Server installation was found. Client components and shared NDI settings were retained.'
        return
    }
    Set-OperationOutcome 'Running' 'Uninstalling the suite.'
    Start-DeploymentJournal 'Uninstall' (Get-SavedConfig)
    Write-Heading 'Uninstall KiloLink Suite'
    Write-Host 'This removes KiloLink and its persisted data and managed Discovery Server settings,' -ForegroundColor Yellow
    Write-Host 'scheduled tasks, installer firewall rules, and browser shortcuts.' -ForegroundColor Yellow
    Write-Host "The dedicated $($script:ManagedDistroName) distribution will be deleted." -ForegroundColor Yellow
    Write-Host 'NDI Tools, PC Agent, WSL, unrelated distributions, and the shared .wslconfig file will be retained.' -ForegroundColor Yellow
    if (-not $Confirmed -and (Read-InstallerInput 'Type UNINSTALL to continue') -cne 'UNINSTALL') {
        Write-Host 'Uninstall cancelled.' -ForegroundColor Yellow
        Set-OperationOutcome 'Cancelled' 'Uninstall was cancelled. No components were removed.'
        return
    }

    # Persist a verified legacy owner before removing its startup task. Keep the
    # owner until every removal step succeeds so a partial uninstall is retryable.
    Save-ComponentReceipt 'server'

    $showProgress = $LauncherMode -or $Action -eq 'Menu'
    if ($showProgress) { Start-SuiteProgress -Activity 'Uninstalling the KiloLink and NDI suite' -Status 'Preparing removal' }
    try {
    Set-SuiteProgress -Percent 8 -Status 'Stopping startup tasks and NDI services'
    $config = Get-SavedConfig
    $preferred = if ($config) { [string](Get-PropertyValue $config 'DistroName' '') } else { '' }
    $distro = Get-UbuntuDistro $preferred
    Stop-ManagedTask $script:StartupTaskName
    Remove-ResumeTask
    Unregister-ScheduledTask -TaskName $script:StartupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Restore-DiscoveryOwnership

    if ($distro -and (Test-KiloContainer $distro)) {
        Set-SuiteProgress -Percent 24 -Status 'Removing the KiloLink container and application data'
        Write-Step 'Removing KiloLink container and data'
        $inspectLines = Invoke-Wsl $distro "docker inspect '$script:ContainerName'" -Capture
        $inspection = ($inspectLines -join [Environment]::NewLine) | ConvertFrom-Json
        $container = @($inspection)[0]
        $mount = @($container.Mounts | Where-Object { $_.Destination -eq '/data' } | Select-Object -First 1)[0]
        $dataPath = if ($mount) { [string]$mount.Source } else { '' }
        Invoke-Wsl $distro "docker rm -f '$script:ContainerName' >/dev/null"
        if ($dataPath -match '^/(?:opt|root|home/[^/]+)/kilolink-server/?$') {
            Invoke-Wsl $distro "rm -rf -- '$dataPath'"
        } elseif ($dataPath) {
            Write-Warning "Data was retained because its path was outside the expected safe locations: $dataPath"
        }
    }

    # NDI Tools is shared by independently deployed clients and Arena. Removing
    # server ownership stops Discovery above; runtime removal remains in Windows Apps.
    Write-Detail 'Shared NDI Tools and PC Agent were retained. Remove them separately in Windows Apps if no longer required.'

    Set-SuiteProgress -Percent 70 -Status 'Removing firewall rules and shortcuts'
    Write-Step 'Removing firewall rules and shortcuts'
    Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$($script:HyperVPrefix)*" } | Remove-NetFirewallHyperVRule
    }
    Remove-LegacyPortProxies $config
    $desktop = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'KiloLink Server Pro.url'
    $programs = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Kiloview'
    Remove-Item -LiteralPath $desktop -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $programs 'KiloLink Server Pro.url') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $programs) {
        if (@(Get-ChildItem -LiteralPath $programs -Force).Count -eq 0) {
            Remove-Item -LiteralPath $programs -Force
        }
    }
    if ($distro -eq $script:ManagedDistroName -and (Get-WslDistroNames) -contains $script:ManagedDistroName) {
        Set-SuiteProgress -Percent 90 -Status "Removing the dedicated $($script:ManagedDistroName) distribution"
        Write-Step "Removing dedicated WSL distribution '$($script:ManagedDistroName)'"
        Invoke-Native wsl.exe @('--unregister', $script:ManagedDistroName)
    }
    Set-SuiteProgress -Percent 100 -Status 'Uninstall complete'
    Remove-MaintenanceEntry
    # Retain the reusable installer and logs, including the active transcript.
    foreach ($file in @($script:ConfigPath, $script:StartupScriptPath, $script:ResumeStatePath)) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    Save-ComponentReceipt 'server' -Remove
    Remove-Item -LiteralPath (Join-Path $script:StateRoot 'discovery-ownership.json') -Force -ErrorAction SilentlyContinue
    } finally {
        if ($showProgress) { Stop-SuiteProgress }
    }
    Write-Host 'Uninstall complete. WSL and unrelated distributions were retained.' -ForegroundColor Green
    Set-OperationOutcome 'Completed' 'Uninstall completed.'
}

function Show-State {
    param($State)
    Write-Host ("KiloLink Server Pro:  " + $(if ($State.KiloLink) { 'Installed' } else { 'Not detected' }))
    Write-Host ("NDI Tools:            " + $(if ($State.NDITools) { 'Installed' } else { 'Not detected' }))
    Write-Host ("NDI Discovery Server: " + $(if ($State.NDIServer) { 'Configured' } else { 'Not detected' }))
    Write-Host ("KiloLink WSL distro:  " + $(if ($State.Distro) { $State.Distro } else { 'Not detected' }))
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Heading 'KiloLink Server Pro + NDI deployment for Windows 11'
        $state = Get-InstallState
        Show-State $state
        if ($state.Any) {
            Write-Host ''
            Write-Host 'A previous or partial installation was detected.' -ForegroundColor Green
            Write-Host '  1. Check for and install updates'
            Write-Host '  2. Repair / reconfigure'
            Write-Host '  3. Uninstall'
            Write-Host '  4. Exit'
            $choice = Read-InstallerInput 'Choose an option'
            try {
                switch ($choice) {
                    '1' { Update-Suite }
                    '2' { Repair-Suite }
                    '3' { Uninstall-Suite }
                    '4' { return }
                    default { Write-Host 'Invalid selection.' -ForegroundColor Red }
                }
            } catch {
                Set-OperationOutcome 'Failed' $_.Exception.Message
                Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "State and logs are under $script:StateRoot" -ForegroundColor Yellow
            }
        } else {
            Write-Host ''
            Write-Host '  1. Install KiloLink Server Pro, NDI Tools, and NDI Discovery Server'
            Write-Host '  2. Exit'
            $choice = Read-InstallerInput 'Choose an option'
            try {
                switch ($choice) {
                    '1' { Repair-Suite }
                    '2' { return }
                    default { Write-Host 'Invalid selection.' -ForegroundColor Red }
                }
            } catch {
                Set-OperationOutcome 'Failed' $_.Exception.Message
                Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host 'Rerun the script and choose Repair / Reconfigure after correcting the problem.' -ForegroundColor Yellow
            }
        }
        if ($script:RestartScheduled) {
            return
        }
        Write-Host ''
        Read-InstallerInput 'Press Enter to return to the menu' | Out-Null
    }
}
