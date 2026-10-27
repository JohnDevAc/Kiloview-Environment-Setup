Ensure-Administrator
$transcriptStarted = $false
$backgroundExitCode = 0
$operationMutex = $null
$ownsOperationMutex = $false
try {
    if ($Action -notin @('Plan','Inspect')) {
        $operationMutex = New-Object Threading.Mutex($false, 'Global\KiloviewProvisioner')
        try { $ownsOperationMutex = $operationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsOperationMutex = $true }
        if (-not $ownsOperationMutex) { $script:LifecycleErrorCode='operation-conflict'; throw 'Another provisioning operation is running. Wait for it to finish before retrying.' }
        Assert-NoPendingNativeProcess
        $pendingWatchdog=Get-PendingWatchdogRecovery
        if($Action -notin @('Verify','Menu') -and $pendingWatchdog){
            $script:LifecycleRecoveryRequired=$true
            $script:LifecycleErrorCode='watchdog-quiescence-failed'
            $script:LifecycleNextAction='Run Verify to confirm the interrupted watchdog shutdown before retrying.'
            throw $script:LifecycleNextAction
        }
        if ($Action -ne 'Menu') { Start-DeploymentJournal $Action $null }
        if($pendingWatchdog -and $script:ActiveJournal){$script:ActiveJournal['pendingWatchdog']=$pendingWatchdog;Save-DeploymentJournal}
    }
    if ($LogPath) {
        $logDirectory = Split-Path -Parent $LogPath
        if ($logDirectory) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Start-Transcript -LiteralPath $LogPath -Append | Out-Null
        $transcriptStarted = $true
    }
    if ($PackageRestartContinuation) {
        if(-not $script:Lifecycle -or -not $AcceptLicenses){throw 'Package continuation requires the original reviewed lifecycle request.'}
        Register-ResumeContinuation 'Windows Installer requires a restart before provisioning.'
        Set-OperationOutcome 'RestartRequired' 'The configuration application is installed. Restart Windows and sign in to continue the reviewed operation.'
    } else { switch ($Action) {
        'Plan' { Get-DeploymentPlan (Get-SavedConfig) | ConvertTo-Json -Depth 10 }
        'Inspect' {
            $inspection=Get-LifecycleInspection
            $inspection|ConvertTo-Json -Depth 12
            $script:OperationOutcome='Completed'
            Write-LifecycleResult 'succeeded' 'Read-only inspection completed.' -Stage 'inspect' -Components $inspection.components -Evidence @{
                activeOperationId=$inspection.activeOperationId; safeToRetry=$inspection.safeToRetry; recoveryRequired=$inspection.recoveryRequired; nextAction=$inspection.nextAction}
        }
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
            Assert-NoPendingKiloRecovery
            Assert-NoPendingNativeProcess
            $config = Get-SavedConfig
            if (Test-PendingWatchdogRecovery) { }
            elseif ($config) {Test-SuiteHealth $config}
            else {Test-NonServerRecovery}
            Remove-VerifiedPendingProcess
            $script:LifecycleRecoveryRequired=$false
            Set-OperationOutcome 'Completed' 'Owned component state verified. The interrupted attempt remains recorded; a new operation may now be requested.'
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
            if (-not $ConfirmRemoval) { throw 'Uninstall requires review and confirmation of the selected role removal.' }
            if ($Role -eq 'client') { Remove-ClientRole }
            else { Uninstall-Suite -Confirmed }
        }
        'RemoveApp' { if (-not $ConfirmRemoval) { throw 'Review and confirm configuration app removal.' }; Remove-ConfigurationApp }
        'Resume' {
            if (-not $AcceptLicenses) {
                throw 'A restart continuation requires the license acceptance recorded by the initial setup run.'
            }
            Resume-Suite
        }
    } }
} catch {
    if($Action -eq 'Verify'){$script:LifecycleRecoveryRequired=$true}
    if($script:LifecycleErrorCode -eq 'lifecycle-result-write-failed') {
        # The journal retains the actual operation outcome and the separate
        # persistence error. Do not turn an Agent cancellation into an Agent
        # installation failure, or claim the unsaved terminal result succeeded.
        $script:OperationFailed=$true
        $backgroundExitCode=1
        Write-LauncherEvent -Type 'outcome' -Data @{outcome='Failed';message=$_.Exception.Message}
    } else {
        Set-OperationOutcome $(if($script:LifecycleErrorCode -eq 'operation-conflict'){'Blocked'}else{'Failed'}) $_.Exception.Message
    }
    Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "State and logs are under $script:StateRoot" -ForegroundColor Yellow
} finally {
    if ($ownsOperationMutex) {
        try { Complete-FailedResumeContinuation }
        catch { $backgroundExitCode=1; Write-InstallerLog ('Could not persist restart-continuation recovery status: '+$_.Exception.Message) }
    }
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
