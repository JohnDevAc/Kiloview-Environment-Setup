# Included by Installer.Regression.ps1. Real engine entry/result/journal handling,
# isolated storage policy input and intercepted network/component operations.
$storageEntryMocks=@'
$script:StateRoot=Join-Path $PSScriptRoot 'state'
$script:ConfigPath=Join-Path $script:StateRoot 'installer-config.json'
$script:InstallerLogPath=Join-Path $script:StateRoot 'installer.log'
function Ensure-Administrator {Initialize-Lifecycle}
function Get-SavedConfig {[pscustomobject]@{DistroName='KiloLink-Ubuntu';WebPort=80;LinkPort=50000;NdiDiscoveryPort=5959;PrimaryInterfaceAlias='Fixture';PublicIp='192.0.2.10'}}
function Get-RequestedSuiteConfig {Get-SavedConfig}
function Sync-PrimaryLanAddress {}
function Assert-ServerOwner {}
function Assert-NoPendingKiloRecovery {}
function Assert-SuitePorts {}
function Get-SuiteNetworkAccessIssue {''}
function Get-ObservedComponents {@()}
function Get-ServerOwnerSid {$null}
function Get-ServerStorageTargets {[pscustomobject]@{Path='C:\fixture';Purpose='WSL disk';Budget='distro';Bytes=16GB}}
function Get-WindowsStorageVolume {[pscustomobject]@{VolumeId='fixture';VolumePath='C:\';AvailableBytes=2GB}}
function Test-WslRuntime {throw 'Storage guard missed: WSL probe'}
function Invoke-Native {throw 'Unexpected native command'}
function Invoke-Wsl {throw 'Unexpected WSL command'}
function Invoke-WslScript {throw 'Unexpected Linux command'}
function Invoke-RestMethod {throw 'Unexpected network request'}
function Ensure-WslFeatures {throw 'Unexpected feature mutation'}
function Start-SuiteProgress {}
function Stop-SuiteProgress {}
function Set-SuiteProgress {}
function Save-Config {throw 'Unexpected configuration write'}
function Register-MaintenanceEntry {throw 'Unexpected maintenance change'}
function Install-NdiTools {throw 'Unexpected NDI download/install'}
function Install-PcAgent {throw 'Unexpected Agent download/install'}

'@
foreach($actionName in @('Setup','Repair','Update','MaintainRuntime')){
    Test-Case "Low-space $actionName fails before component work and persists a retryable owner result" {
        $requestAction=switch($actionName){Setup {'install'} Repair {'repair'} Update {'update'} MaintainRuntime {'maintain-runtime'}}
        $fixture=New-LifecycleFixture $requestAction
        $fixture.Data.role='server';[IO.File]::WriteAllText($fixture.Path,($fixture.Data|ConvertTo-Json))
        $fixturePath=Join-Path $fixture.Directory 'entry.ps1'
        $source=[IO.File]::ReadAllText($installerPath)
        [IO.File]::WriteAllText($fixturePath,$source.Insert($entryOffset,$storageEntryMocks),[Text.Encoding]::UTF8)
        $output=& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath -Action $actionName -Role server -AcceptLicenses -ConfigurationPath fixture -LifecycleRequestPath $fixture.Path
        Assert-True ($LASTEXITCODE -eq 1) 'Low capacity returned success.'
        $result=Get-Content -LiteralPath $fixture.Request.ResultPath -Raw|ConvertFrom-Json
        $journal=Get-Content -LiteralPath (Join-Path $fixture.Directory 'state\last-operation.json') -Raw|ConvertFrom-Json
        Assert-True ($result.errorCode -eq 'insufficient-disk-space' -and $result.outcome -eq 'failed' -and $result.message -match 'Free at least 14 GiB on C:\\') ('Wrong terminal result: '+($result|ConvertTo-Json -Compress))
        Assert-True (-not $result.recoveryRequired -and $result.partialEffects.Count -eq 0 -and -not $journal.mutationStarted -and $journal.steps.Count -eq 0 -and $journal.outcome -eq 'Failed') 'Preflight-only failure became a mutation/recovery problem.'
        # Inspect the exact failed journal through the real read-only inspection.
        $script:StateRoot=Join-Path $fixture.Directory 'state'
        function Get-ObservedComponents {@()}
        function Get-ServerOwnerSid {$null}
        $inspection=Get-LifecycleInspection
        Assert-True ($inspection.safeToRetry -and -not $inspection.recoveryRequired -and -not $inspection.activeOperationId) 'A low-space failure blocked future retry after space is freed.'
    }
}
foreach($actionName in @('InstallClient','Inspect','Verify','Uninstall')){
    Test-Case "Low disk does not impose Server installation reserves on $actionName" {
        $fixture=New-LifecycleFixture
        $fixturePath=Join-Path $fixture.Directory 'entry.ps1'
        $permittedMocks=@'
function Install-NdiTools {$script:NdiRestartRequired=$false}
function Install-PcAgent {$true}
function Test-ServerOwnershipEvidence {$false}
function Test-SuiteHealth {}
function Remove-VerifiedPendingProcess {}
function Get-ServerStorageTargets {throw 'Server storage reserve incorrectly applied to this action'}

'@
        $source=[IO.File]::ReadAllText($installerPath)
        [IO.File]::WriteAllText($fixturePath,$source.Insert($entryOffset,$storageEntryMocks+$permittedMocks),[Text.Encoding]::UTF8)
        $role=if($actionName -eq 'InstallClient'){'client'}else{'server'}
        $output=& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath -Action $actionName -Role $role -AcceptLicenses -ConfirmRemoval -LauncherMode
        Assert-True ($LASTEXITCODE -eq 0) ("$actionName was blocked: "+($output -join "`n"))
        Assert-True (($output -join "`n") -notmatch 'reserve incorrectly applied') 'Non-Server operation queried the Server reserve.'
    }
}
Test-Case 'Source-only diagnostics remain usable without installation headroom' {
    Invoke-Expression ($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ServerDownloads'},$true).Extent.Text)
    function Assert-ServerStorage {throw 'Storage reserve blocked source-only diagnostics'}
    function Test-WslRuntime {$true}
    function Get-NdiRegistration {@{DisplayVersion='fixture'}}
    function Get-NdiDiscoveryExe {'fixture.exe'}
    function Get-UbuntuDistro {'KiloLink-Ubuntu'}
    Assert-ServerDownloads (New-Config) -SourcesOnly
}
Test-Case 'Resumed Server installation rechecks capacity before component work' {
    Invoke-Expression ($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ServerDownloads'},$true).Extent.Text)
    function Get-ResumeState {@{Action='Setup'}}
    function Get-SavedConfig {New-Config}
    function Wait-ResumeNetwork {}
    function Sync-PrimaryLanAddress {}
    function Assert-ServerStorage {throw 'fixture low disk on resume'}
    function Save-Config {throw 'Resume changed config before checking space'}
    function Test-WslRuntime {throw 'Resume launched WSL before checking space'}
    Assert-Throws {Resume-Suite} 'fixture low disk on resume'
}
