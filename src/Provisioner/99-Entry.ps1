Ensure-Administrator
$transcriptStarted = $false
$backgroundExitCode = 0
$operationMutex = $null
$ownsOperationMutex = $false
try {
    if ($Action -notin @('Plan','Inspect')) {
        $operationMutex = New-Object Threading.Mutex($false, 'Global\KiloviewProvisioner')
        try { $ownsOperationMutex = $operationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsOperationMutex = $true }
        if (-not $ownsOperationMutex) { throw 'Another provisioning operation is running. Wait for it to finish before retrying.' }
    }
    if ($LogPath) {
        $logDirectory = Split-Path -Parent $LogPath
        if ($logDirectory) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Start-Transcript -LiteralPath $LogPath -Append | Out-Null
        $transcriptStarted = $true
    }
    switch ($Action) {
        'Plan' { Get-DeploymentPlan (Get-SavedConfig) | ConvertTo-Json -Depth 10 }
        'Inspect' { [pscustomobject]@{schemaVersion=1; configuration=(Get-SavedConfig); plan=(Get-DeploymentPlan (Get-SavedConfig)); ownerSid=(Get-ServerOwnerSid)} | ConvertTo-Json -Depth 10 }
        'CheckDownloads' {
            $config = Get-SavedConfig
            if (-not $config) { $config = [pscustomobject]@{WebPort=80;NdiDiscoveryPort=5959;DistroName=$script:ManagedDistroName} }
            Assert-ServerDownloads $config -SourcesOnly
            Set-OperationOutcome 'Completed' 'Required Windows package sources are reachable. Setup rechecks and verifies packages before installation.'
        }
        'Menu' {
            if ($LauncherMode) { throw 'The Windows installer requires an explicit action. Reopen Setup.' }
            Show-Menu
        }
        'Setup' {
            if (-not $AcceptLicenses -or -not $ConfigurationPath) { throw 'Setup requires reviewed configuration and vendor licence acceptance.' }
            Repair-Suite -RequestedConfiguration (Get-RequestedSuiteConfig $ConfigurationPath) -LicenseAccepted -BringCurrent
        }
        'Install' {
            if (-not $AcceptLicenses -or -not $ConfigurationPath) {
                throw 'Installation requires reviewed configuration and vendor licence acceptance.'
            }
            Repair-Suite -RequestedConfiguration (Get-RequestedSuiteConfig $ConfigurationPath) -LicenseAccepted
        }
        'InstallClient' { Install-ClientTools }
        'MaintainRuntime' { Maintain-SuiteRuntime }
        'Backup' { Backup-SuiteData }
        'Verify' {
            Assert-ServerOwner
            $config = Get-SavedConfig
            if (-not $config) { throw 'A configured server is required for verification.' }
            Test-SuiteHealth $config
            Set-OperationOutcome 'Completed' 'Server health verified.'
        }
        'Repair' {
            if (-not $AcceptLicenses) {
                throw 'Unattended repair requires -AcceptLicenses after the vendor agreements have been reviewed and accepted.'
            }
            if ($ConfigurationPath) {
                Repair-Suite -RequestedConfiguration (Get-RequestedSuiteConfig $ConfigurationPath) -LicenseAccepted
            } else {
                Repair-Suite -UseSavedConfiguration -LicenseAccepted
            }
        }
        'Update' {
            if ($LauncherMode -and -not $AcceptLicenses) { throw 'Review and accept vendor licences before updating.' }
            Update-Suite
        }
        'Uninstall' {
            if (-not $ConfirmRemoval) { throw 'Uninstall requires confirmation that KiloLink application data will be deleted.' }
            Uninstall-Suite -Confirmed
        }
        'Resume' {
            if (-not $AcceptLicenses) {
                throw 'A restart continuation requires the license acceptance recorded by the initial setup run.'
            }
            Resume-Suite
        }
    }
} catch {
    $backgroundExitCode = 1
    Set-OperationOutcome 'Failed' $_.Exception.Message
    Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "State and logs are under $script:StateRoot" -ForegroundColor Yellow
} finally {
    if ($ownsOperationMutex) { $operationMutex.ReleaseMutex() }
    if ($operationMutex) { $operationMutex.Dispose() }
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
if ($backgroundExitCode -ne 0) {
    exit $backgroundExitCode
}
exit (Get-InstallerExitCode)
