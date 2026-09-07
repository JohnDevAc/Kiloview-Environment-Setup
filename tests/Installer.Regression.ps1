#Requires -Version 5.1
<#
Run after Build-Setup.ps1. No elevation, WSL distribution, vendor installation,
live network changes, or scheduled tasks are required. Git Bash is used only
to exercise the generated watchdog against fake service commands.
#>
[CmdletBinding()]
param([string]$BashPath = "$env:ProgramFiles\Git\bin\bash.exe")

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('kilolink-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$originalTemp = $env:TEMP
$originalProgramData = $env:ProgramData
$liveReceiptPath = Join-Path $originalProgramData 'KiloLink\installation-components.json'
$liveReceiptHash = if (Test-Path -LiteralPath $liveReceiptPath) { (Get-FileHash -LiteralPath $liveReceiptPath -Algorithm SHA256).Hash } else { $null }
$env:TEMP = $testRoot
$env:ProgramData = Join-Path $testRoot 'program-data'
New-Item -ItemType Directory -Path $env:ProgramData | Out-Null
New-Item -ItemType Directory -Path (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') -Force | Out-Null
$results = New-Object Collections.Generic.List[object]

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $failure = $null
    try { & $Body | Out-Null } catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        $failure = $exception.Message
    }
    Assert-True ($failure -and $failure -match $Pattern) "Expected failure matching '$Pattern'; received '$failure'."
}
function New-Config {
    [pscustomobject]@{SchemaVersion=1;PrimaryInterfaceAlias='Ethernet';PublicIp='192.0.2.10';WebPort=80;LinkPort=50000;NdiDiscoveryPort=5959;DistroName='KiloLink-Ubuntu';LinuxDataPath='/opt/kilolink-server';KiloLinkImage='kiloview/klnk-pro:latest'}
}

$tokens = $null
$parseErrors = $null
$installerPath = Join-Path $root 'Install-KiloLinkSuite.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) ($parseErrors | Out-String)
# Import declarations only; never execute the installer entry point.
$declarations = @()
$foundEntry = $false
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement.Extent.Text -eq 'Ensure-Administrator') {
        $foundEntry = $true
        $entryOffset = $statement.Extent.StartOffset
        break
    }
    $declarations += $statement.Extent.Text
}
Assert-True $foundEntry 'Could not locate the installer entry point.'
$engine = [scriptblock]::Create($declarations -join "`n")
$baseMocks = {
    function Write-Heading { }
    function Write-Step { }
    function Write-Detail { }
    function Write-Host { }
    function Write-Warning { }
    function Write-InstallerLog { }
    function Start-SuiteProgress { }
    function Set-SuiteProgress { }
    function Stop-SuiteProgress { }
    function Write-LauncherEvent { }
    function Register-MaintenanceEntry { }
    function Remove-MaintenanceEntry { }
    function Invoke-Native { throw 'Unexpected native command in test' }
    function Invoke-Wsl { throw 'Unexpected WSL command in test' }
    function Invoke-WslScript { throw 'Unexpected WSL script in test' }
    function Start-Process { throw 'Unexpected process launch in test' }
    function Register-ScheduledTask { throw 'Unexpected task registration in test' }
    function Unregister-ScheduledTask { throw 'Unexpected task removal in test' }
    function Start-ScheduledTask { throw 'Unexpected task start in test' }
    function Stop-ScheduledTask { throw 'Unexpected task stop in test' }
    function Get-ScheduledTask { $null }
    function Get-LanCandidates { [pscustomobject]@{Alias='Ethernet';Address='192.0.2.10';Dhcp=$false} }
    function Get-WslDistroNames { @() }
    function Assert-PackageSource { }
    function Assert-NdiToolsFilesAvailable { }
    function Prepare-ClientPackages { }
    function Assert-ServerDownloads { }
    function Assert-ServerOwner { }
    function Assert-LinuxDownloads { }
    function Get-NdiDiscoveryService { $null }
    function Get-DiscoveryDelayedStart { $null }
    function Restore-DiscoveryDelayedStart { }
    function Get-DiscoveryConfigPath { Join-Path $script:StateRoot 'fixture-discovery.json' }
    function Stop-Service { throw 'Unexpected service stop in test' }
    function Start-Service { throw 'Unexpected service start in test' }
    function Set-Service { throw 'Unexpected service configuration in test' }
    function Remove-NetFirewallRule { throw 'Unexpected firewall removal in test' }
    function Remove-NetFirewallHyperVRule { throw 'Unexpected Hyper-V firewall removal in test' }
}
$repairMocks = {
    function Ensure-WslFeatures { $true }
    function Ensure-MirroredNetworking { }
    function Ensure-Ubuntu { param($Config) $Config.DistroName }
    function Ensure-Docker { }
    function Install-NdiTools { }
    function Configure-NdiServer { }
    function Install-FirewallRules { }
    function Install-Shortcuts { }
    function Install-StartupTask { }
    function Test-SuiteHealth { }
    function Clear-ResumeContinuation { }
    function Show-SuiteSummary { }
    function Test-KiloContainer { $true }
    function Get-LegacyKiloConfig { New-Config }
    function Recreate-KiloContainer { $script:Recreated++ }
    function Invoke-Wsl { }
    $script:Recreated = 0
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & {
            . $engine
            . $baseMocks
            $Action = 'Menu'
            $LauncherMode = $false
            $PreferredInterfaceAlias = ''
            $PreferredIpAddress = ''
            $ConfigurationPath = ''
            $ConfirmRemoval = $false
            $PackageDirectory = ''
            $AcceptLicenses = $false
            $script:StateRoot = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
            $script:ConfigPath = Join-Path $script:StateRoot 'installer-config.json'
            $script:StartupScriptPath = Join-Path $script:StateRoot 'watchdog.ps1'
            & $Body
        } | Out-Null
        $results.Add([pscustomobject]@{Name=$Name;Passed=$true})
        Write-Host "PASS $Name"
    } catch {
        $results.Add([pscustomobject]@{Name=$Name;Passed=$false})
        Write-Host "FAIL $Name`: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
}

try {
    . (Join-Path $PSScriptRoot 'Qa.Regression.ps1')
    . (Join-Path $PSScriptRoot 'ClientUpdate.Regression.ps1')
    Test-Case 'Client stages both packages before any installation and stops on unavailable downloads' {
        Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Prepare-ClientPackages' }, $true).Extent.Text)
        $AcceptLicenses = $true
        $script:Calls = [Collections.Generic.List[string]]::new()
        function Install-PcAgent { param([switch]$PrepareOnly) $script:Calls.Add("Agent-$PrepareOnly"); if (-not $PrepareOnly) { throw 'Installation must remain gated' }; $true }
        function Install-NdiTools { param([switch]$ClientOnly,[switch]$PrepareOnly) $script:Calls.Add("NDI-$PrepareOnly"); throw 'NDI source offline' }
        function Save-ComponentReceipt { throw 'No role should be recorded before prerequisites pass' }
        Assert-Throws { Install-ClientTools } 'NDI source offline'
        Assert-True (($script:Calls -join ',') -eq 'Agent-True,NDI-True') 'Client installed a component before all downloads were ready.'
    }
    Test-Case 'Server unavailable package gates features and configuration writes' {
        Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ServerDownloads' }, $true).Extent.Text)
        function Test-WslRuntime { $false }
        function Invoke-RestMethod { throw 'fixture DNS failure' }
        function Save-Config { throw 'Unexpected configuration mutation' }
        function Ensure-WslFeatures { throw 'Unexpected Windows mutation' }
        Assert-Throws { Repair-Suite -RequestedConfiguration (New-Config) -LicenseAccepted } 'WSL prerequisites cannot be downloaded'
    }
    Test-Case 'Readiness rejects captive portals and inaccessible package sources' {
        Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-PackageSource' }, $true).Extent.Text)
        function Invoke-WebRequest { @{Headers=@{'Content-Type'='text/html'}} }
        Assert-Throws { Assert-PackageSource 'https://example.invalid/package.exe' } 'web page instead of a package'
        function Invoke-WebRequest { throw 'Proxy authentication required' }
        Assert-Throws { Assert-PackageSource 'https://example.invalid/package.exe' } 'Required download unavailable from example.invalid'
    }
    Test-Case 'Client and server receipt roles survive independent removal' {
        Save-ComponentReceipt 'client'
        Save-ComponentReceipt 'server'
        $path = Join-Path $script:StateRoot 'installation-components.json'
        Assert-True (@((Get-Content $path -Raw | ConvertFrom-Json).roles).Count -eq 2) 'Combined role was lost.'
        Save-ComponentReceipt 'server' -Remove
        Assert-True (((Get-Content $path -Raw | ConvertFrom-Json).roles -join ',') -eq 'client') 'Server removal erased the Client role.'
    }
    Test-Case 'Suite ports and prerelease ordering are consistent' {
        Assert-True ((Compare-PcAgentVersion '0.7.0-dev.2' '0.7.0') -lt 0) 'Development build collapsed to stable.'
        Assert-True ((Compare-PcAgentVersion '0.7.0-dev.10' '0.7.0-dev.2') -gt 0) 'Development version ordering is lexical.'
        foreach ($port in @(8080,8091,8094)) { $config = New-Config; $config.WebPort = $port; Assert-Throws { Assert-SuitePorts $config } 'reserved' }
        $config = New-Config; $config.NdiDiscoveryPort = 5960; Assert-Throws { Assert-SuitePorts $config } '5959'
    }
    Test-Case 'Server ownership and WSL-context readiness fail before dependent changes' {
        Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ServerOwner' }, $true).Extent.Text)
        function Get-InteractiveUserSid { 'different-desktop-owner' }
        Assert-Throws { Assert-ServerOwner } 'signed-in administrator desktop'
        Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-LinuxDownloads' }, $true).Extent.Text)
        function Invoke-WslScript {
            param($Distro,$Script)
            Assert-True ($Distro -eq 'Fixture' -and $Script -match 'registry-1.docker.io' -and $Script -match 'apt-get' -and $Script -notmatch 'apt-get install') 'Linux gate did not use the actual package context.'
            throw 'Fixture WSL DNS failure'
        }
        Assert-Throws { Assert-LinuxDownloads 'Fixture' } 'unavailable inside WSL'
    }
    Test-Case 'Explicit local client packages never fall back to the internet' {
        $PackageDirectory = Join-Path $testRoot 'offline-input'
        New-Item -ItemType Directory -Path $PackageDirectory -Force | Out-Null
        $source = Join-Path $PackageDirectory 'NDI-Tools.exe'
        Set-Content -LiteralPath $source -Value 'offline fixture'
        function Assert-PackageSource { throw 'Offline path attempted an internet probe' }
        $destination = Join-Path $testRoot 'offline-copy.exe'
        Download-FileWithProgress -Uri $script:NdiToolsUrl -Destination $destination -BasePercent 0 -PercentSpan 1 -Status 'Fixture'
        Assert-True ((Get-Content $destination -Raw) -eq (Get-Content $source -Raw)) 'Explicit package bytes were not retained.'
        Assert-Throws { Download-FileWithProgress -Uri 'https://github.com/fixture/PC-Agent.zip' -Destination $destination -BasePercent 0 -PercentSpan 1 -Status 'Fixture' } 'missing|offline|Offline'
    }
    Test-Case 'Native request validates typed settings without saving them' {
        $requestFile = Join-Path $testRoot 'valid-request.json'
        $request = New-Config
        $request.WebPort = 8088
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestFile
        $config = Get-RequestedSuiteConfig $requestFile
        Assert-True ($config.WebPort -eq 8088 -and $config.LinkPort -eq 50000) 'Requested ports were lost.'
        Assert-True (-not (Test-Path -LiteralPath $script:ConfigPath)) 'Reviewing a request changed saved settings.'
    }
    Test-Case 'Native request rejects invalid ports, addresses, and stale adapters' {
        $requestFile = Join-Path $testRoot 'invalid-request.json'
        foreach ($case in @(
            @('WebPort',0,'Invalid WebPort'), @('WebPort',65536,'Invalid WebPort'),
            @('LinkPort',50001,'must be even'), @('LinkPort',65535,'must be even'),
            @('NdiDiscoveryPort',80,'different TCP ports'), @('PublicIp','127.0.0.1','usable IPv4'),
            @('PublicIp','224.0.0.1','usable IPv4'), @('PublicIp','169.254.1.1','usable IPv4'),
            @('PublicIp','192.0.2.10;whoami','usable IPv4'), @('PublicIp','192.0.2.11','no longer available'),
            @('PrimaryInterfaceAlias','Missing','no longer available'), @('SchemaVersion',2,'Unsupported')
        )) {
            $request = New-Config
            $request.($case[0]) = $case[1]
            $request | ConvertTo-Json | Set-Content -LiteralPath $requestFile
            Assert-Throws { Get-RequestedSuiteConfig $requestFile } $case[2]
        }
    }
    Test-Case 'Native request preserves saved data location and vendor image' {
        $old = New-Config
        $old.LinuxDataPath = '/root/kilolink-server'
        $old.KiloLinkImage = 'kiloview/klnk-pro:v1.2'
        Save-Config $old
        $request = New-Config
        $request.LinuxDataPath = '/opt/another-path'
        $request.KiloLinkImage = 'untrusted/image:latest'
        $requestFile = Join-Path $testRoot 'preserve-request.json'
        $request | ConvertTo-Json | Set-Content -LiteralPath $requestFile
        $config = Get-RequestedSuiteConfig $requestFile
        Assert-True ($config.LinuxDataPath -eq '/root/kilolink-server' -and $config.KiloLinkImage -eq 'kiloview/klnk-pro:v1.2') 'The UI request replaced infrastructure settings.'
    }
    Test-Case 'Repair imports the existing data mount when saved settings are missing' {
        function Get-WslDistroNames { 'KiloLink-Ubuntu' }
        function Test-KiloContainer { $true }
        function Get-LegacyKiloConfig { $old = New-Config; $old.LinuxDataPath = '/root/kilolink-server'; $old }
        $requestFile = Join-Path $testRoot 'legacy-request.json'
        New-Config | ConvertTo-Json | Set-Content -LiteralPath $requestFile
        $config = Get-RequestedSuiteConfig $requestFile
        Assert-True ($config.LinuxDataPath -eq '/root/kilolink-server') 'Repair replaced the existing data mount.'
        function Get-LegacyKiloConfig { $null }
        Assert-Throws { Get-RequestedSuiteConfig $requestFile } 'preserve its data'
    }
    Test-Case 'Launcher mode fails immediately if an engine prompt is reached' {
        $LauncherMode = $true
        Assert-Throws { Read-InstallerInput 'Unexpected menu' } 'Windows interface'
    }
    Test-Case 'Maintenance registration points Windows to native actions for the WSL owner' {
        $node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Register-MaintenanceEntry'},$false)
        . ([scriptblock]::Create($node.Extent.Text))
        $LauncherMode = $true
        $script:PersistentLauncherPath = Join-Path $testRoot 'maintenance-fixture.exe'
        Set-Content -LiteralPath $script:PersistentLauncherPath -Value 'fixture'
        $script:RegistryValues = @{}
        $script:ShortcutSaved = $false
        function New-Item { }
        function New-ItemProperty {
            param($Path,$Name,$Value,$PropertyType,[switch]$Force)
            Assert-True ($Path -like 'HKCU:*') 'Maintenance was registered for users who cannot access the WSL distribution.'
            $script:RegistryValues[$Name] = $Value
        }
        $script:FakeShortcut = [pscustomobject]@{TargetPath=''}
        $script:FakeShortcut | Add-Member ScriptMethod Save { $script:ShortcutSaved = $true }
        $script:FakeShell = [pscustomobject]@{}
        $script:FakeShell | Add-Member ScriptMethod CreateShortcut { param($Path) $script:FakeShortcut }
        function New-Object { param($ComObject) if ($ComObject -ne 'WScript.Shell') { throw 'Unexpected COM object' }; $script:FakeShell }
        Register-MaintenanceEntry
        Assert-True ($script:RegistryValues.UninstallString -eq ('"{0}" --uninstall' -f $script:PersistentLauncherPath)) 'Windows uninstall is not routed to native confirmation.'
        Assert-True ($script:RegistryValues.ModifyPath -eq ('"{0}" --repair' -f $script:PersistentLauncherPath)) 'Windows repair entry is incorrect.'
        Assert-True ($script:ShortcutSaved -and $script:FakeShortcut.TargetPath -eq $script:PersistentLauncherPath) 'The maintenance shortcut was not saved.'
    }
    Test-Case 'Native install completes one operation without menu input' {
        . $repairMocks
        $LauncherMode = $true
        $Action = 'Install'
        function Read-InstallerInput { throw 'Unexpected text prompt' }
        Repair-Suite -RequestedConfiguration (New-Config) -LicenseAccepted
        Assert-True ($script:OperationOutcome -eq 'Completed') 'Direct install did not complete.'
        Assert-True ((Get-SavedConfig).PublicIp -eq '192.0.2.10') 'Configuration was not persisted for restart.'
    }
    Test-Case 'Confirmed native uninstall removes managed components and retains reusable setup' {
        $Action = 'Uninstall'
        $LauncherMode = $true
        Save-Config (New-Config)
        $script:RemovedPaths = [Collections.Generic.List[string]]::new()
        $script:NativeArguments = ''
        function Get-UbuntuDistro { 'KiloLink-Ubuntu' }
        function Get-WslDistroNames { 'KiloLink-Ubuntu' }
        function Test-KiloContainer { $false }
        function Get-NdiRegistration { $null }
        function Get-NdiDiscoveryService { $null }
        function Stop-ManagedTask { }
        function Remove-ResumeTask { }
        function Unregister-ScheduledTask { }
        function Get-NetFirewallRule { @() }
        function Get-NetFirewallHyperVRule { @() }
        function Remove-NetFirewallRule { }
        function Remove-NetFirewallHyperVRule { }
        function Remove-LegacyPortProxies { }
        function Remove-Item { param($LiteralPath,[switch]$Force,[switch]$Recurse,$ErrorAction) $script:RemovedPaths.Add($LiteralPath) }
        function Invoke-Native { param($FilePath,$Arguments) $script:NativeArguments = $FilePath + ' ' + ($Arguments -join ' ') }
        function Read-InstallerInput { throw 'Unexpected text prompt' }
        Uninstall-Suite -Confirmed
        Assert-True ($script:OperationOutcome -eq 'Completed') 'Native uninstall did not complete.'
        Assert-True ($script:NativeArguments -eq 'wsl.exe --unregister KiloLink-Ubuntu') 'Uninstall did not target the dedicated distribution.'
        Assert-True ($script:RemovedPaths -contains $script:ConfigPath) 'Uninstall retained the active suite configuration.'
        Assert-True ($script:RemovedPaths -notcontains $script:StateRoot -and $script:RemovedPaths -notcontains $script:PersistentLauncherPath) 'Uninstall tried to delete its running reusable launcher.'
    }
    Test-Case 'Requested settings are not saved when licence acceptance is cancelled' {
        $old = New-Config
        Save-Config $old
        $request = New-Config
        $request.WebPort = 8088
        function Confirm-LicenseAcceptance { $false }
        Repair-Suite -RequestedConfiguration $request
        Assert-True ((Get-SavedConfig).WebPort -eq 80) 'Cancelled request overwrote previous settings.'
    }
    Test-Case 'Native update applies requested settings without prompts' {
        . $repairMocks
        $Action = 'Update'
        $LauncherMode = $true
        Save-Config (New-Config)
        $request = New-Config
        $request.WebPort = 8088
        $ConfigurationPath = Join-Path $testRoot 'update-request.json'
        $request | ConvertTo-Json | Set-Content -LiteralPath $ConfigurationPath
        function Get-UbuntuDistro { 'KiloLink-Ubuntu' }
        function Update-KiloLink { }
        function Invoke-WslScript { }
        function Read-InstallerInput { throw 'Unexpected text prompt' }
        Update-Suite
        Assert-True ((Get-SavedConfig).WebPort -eq 8088 -and $script:OperationOutcome -eq 'Completed') 'Update did not apply the requested web port.'
    }
    Test-Case 'Restarted update resumes updating and clears continuation after success' {
        Save-Config (New-Config)
        function Get-ResumeState { [pscustomobject]@{Action='Update'} }
        function Remove-ResumeTask { }
        function Wait-ResumeNetwork { }
        function Repair-Suite { throw 'Update was incorrectly converted to repair' }
        function Update-Suite { Set-OperationOutcome 'Completed' 'Updated'; $script:Updated = $true }
        function Clear-ResumeContinuation { $script:Cleared = $true }
        $script:Updated = $false
        $script:Cleared = $false
        Resume-Suite
        Assert-True ($script:Updated -and $script:Cleared) 'The requested update was not resumed and cleared.'
    }
    Test-Case 'Native restart continuation waits for the user to restart' {
        $Action = 'Resume'
        $LauncherMode = $true
        $AutoRestart = $false
        function Register-ResumeContinuation { }
        function Read-InstallerInput { throw 'Unexpected text prompt' }
        Request-RestartAndResume 'Fixture restart'
        Assert-True ($script:OperationOutcome -eq 'RestartRequired') 'Native restart did not report the required outcome.'
    }
    Test-Case 'Cancelled repair preserves the previous configuration' {
        $config = New-Config
        Save-Config $config
        function Read-SuiteConfig { $new = New-Config; $new.WebPort = 8088; $new }
        function Confirm-LicenseAcceptance { $false }
        Repair-Suite
        Assert-True ((Get-SavedConfig).WebPort -eq 80) 'Cancellation overwrote the applied port.'
        Assert-True ($script:OperationOutcome -eq 'Cancelled') 'Cancellation was not reported.'
    }
    Test-Case 'Repair retries settings saved before an interrupted attempt' {
        . $repairMocks
        $config = New-Config
        $config.WebPort = 8088
        Save-Config $config
        Repair-Suite -UseSavedConfiguration -LicenseAccepted
        Assert-True ($script:Recreated -eq 1) 'The stale container was not recreated.'
        Assert-True ($script:OperationOutcome -eq 'Completed') 'Successful repair was not recorded.'
    }
    Test-Case 'Matching live container is retained' {
        . $repairMocks
        Sync-KiloConfig (New-Config)
        Assert-True ($script:Recreated -eq 0) 'A matching container was unnecessarily recreated.'
    }
    Test-Case 'Unreadable live configuration blocks recreation' {
        . $repairMocks
        function Get-LegacyKiloConfig { $null }
        Assert-Throws { Sync-KiloConfig (New-Config) } 'Could not read the live'
        Assert-True ($script:Recreated -eq 0) 'An unreadable container was replaced.'
    }
    Test-Case 'Update applies the static IP selected in the launcher' {
        . $repairMocks
        $config = New-Config
        Save-Config $config
        $PreferredInterfaceAlias = 'Production'
        $PreferredIpAddress = '192.0.2.20'
        function Get-LanCandidates { [pscustomobject]@{Alias='Production';Address='192.0.2.20';Dhcp=$false} }
        function Get-UbuntuDistro { 'KiloLink-Ubuntu' }
        function Invoke-WslScript { }
        function Update-KiloLink { }
        Update-Suite
        $saved = Get-SavedConfig
        Assert-True ($saved.PublicIp -eq '192.0.2.20' -and $saved.PrimaryInterfaceAlias -eq 'Production') 'Update retained the old adapter/address.'
        Assert-True ($script:Recreated -eq 1) 'Update did not apply the address to the container.'
    }
    Test-Case 'Unattended repair reconciles a changed DHCP address after reboot' {
        . $repairMocks
        Save-Config (New-Config)
        function Get-LanCandidates { [pscustomobject]@{Alias='Ethernet';Address='192.0.2.30';Dhcp=$true} }
        Repair-Suite -UseSavedConfiguration -LicenseAccepted
        Assert-True ((Get-SavedConfig).PublicIp -eq '192.0.2.30') 'The saved address survived a DHCP change.'
        Assert-True ($script:Recreated -eq 1) 'The container address was not reconciled.'
    }
    Test-Case 'Unavailable launcher address is rejected' {
        $PreferredInterfaceAlias = 'Ethernet'
        $PreferredIpAddress = '192.0.2.99'
        Assert-Throws { Sync-PrimaryLanAddress (New-Config) } 'no longer available'
    }

    Test-Case 'NDI versions normalize omitted zero components and reject uncertain labels' {
        foreach ($value in @('6.0','6.0.0','6.0.0.0')) {
            Assert-True ((Convert-ToNdiToolsVersion $value) -eq [version]'6.0.0.0') 'Equivalent NDI versions compared differently.'
        }
        foreach ($value in @('', 'unknown', '6.0.0-preview', 'version 6.0.0', '6.0.0.0.1')) {
            Assert-True ($null -eq (Convert-ToNdiToolsVersion $value)) 'An uncertain NDI version could suppress an update.'
        }
    }
    Test-Case 'NDI metadata reads the labelled Tools version for the selected official package' {
        function Invoke-WebRequest {
            param($Uri, $Headers, $TimeoutSec)
            Assert-True ($Uri -eq 'https://ndi.video/tools/' -and $Headers['Cache-Control'] -eq 'no-cache' -and $TimeoutSec -le 20) 'NDI metadata did not use a bounded fresh official-page request.'
            [pscustomobject]@{
                Links=@([pscustomobject]@{href=$script:NdiToolsUrl})
                Content='<a>NDI 6.3</a><div>Version 6.3.2</div><div>Version 6.3.2.0</div><script>"<div>Version 9.0.0</div>"</script><!-- <div>Version 8.0.0</div> -->'
            }
        }
        Assert-True ((Get-CurrentNdiToolsVersion -Uri $script:NdiToolsUrl) -eq [version]'6.3.2.0') 'The advertised Tools version was not read correctly.'
    }
    Test-Case 'Missing ambiguous or unrelated NDI metadata cannot mark the package current' {
        foreach ($content in @('', '<div>NDI 6.3</div>', '<div>Version 6.3.2-preview</div>', '<div>Version 6.3.2</div><div>Version 6.3.3</div>')) {
            function Invoke-WebRequest { [pscustomobject]@{Links=@([pscustomobject]@{href=$script:NdiToolsUrl});Content=$content} }
            Assert-True ($null -eq (Get-CurrentNdiToolsVersion -Uri $script:NdiToolsUrl)) 'Uncertain metadata suppressed a package check.'
        }
        function Invoke-WebRequest { [pscustomobject]@{Links=@([pscustomobject]@{href='https://downloads.ndi.tv/Tools/NDI%207%20Tools.exe'});Content='<div>Version 7.0.0</div>'} }
        Assert-True ($null -eq (Get-CurrentNdiToolsVersion -Uri $script:NdiToolsUrl)) 'A different package supplied the version.'
        function Invoke-WebRequest { throw 'Fixture metadata unavailable' }
        Assert-True ($null -eq (Get-CurrentNdiToolsVersion -Uri $script:NdiToolsUrl)) 'Unavailable metadata prevented the installer fallback.'
    }
    $ndiMocks = {
        $script:NdiInstalled = $false
        $script:NdiDownloads = 0
        $script:NdiInstallCalls = 0
        $script:NdiVersionChecks = 0
        $script:NdiSignatureChecks = 0
        function Get-CurrentNdiToolsVersion { $script:NdiVersionChecks++; [version]'6.0.0.0' }
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='6.0.0'} }
        function Get-NdiDiscoveryExe { if ($script:NdiInstalled) { 'C:\Fake\NDI Discovery Service.exe' } }
        function Download-FileWithProgress { $script:NdiDownloads++ }
        function Get-InstallerSignatureWithProgress { $script:NdiSignatureChecks++; [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=NDI Fixture'}} }
        function Get-Item { [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductVersion='6.0.0'}} }
        function Start-QuietInstaller {
            $script:NdiInstallCalls++
            $script:NdiInstalled = $true
            [pscustomobject]@{HasExited=$true;ExitCode=0} | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
        }
    }
    Test-Case 'Missing NDI executable triggers a same-version reinstall' {
        . $ndiMocks
        Install-NdiTools
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1) 'A stale registration prevented repair.'
    }
    Test-Case 'Healthy NDI repair does not reinstall' {
        . $ndiMocks
        $script:NdiInstalled = $true
        Install-NdiTools
        Assert-True ($script:NdiDownloads -eq 0 -and $script:NdiInstallCalls -eq 0) 'Healthy NDI was reinstalled.'
    }
    Test-Case 'NDI repair fails if the package does not restore Discovery' {
        . $ndiMocks
        function Get-NdiDiscoveryExe { $null }
        Assert-Throws { Install-NdiTools } 'executable is still missing'
    }
    Test-Case 'Current NDI skips downloads through preflight and update and checks again next time' {
        . $ndiMocks
        $script:NdiInstalled = $true
        Install-NdiTools -UpdateOnly -PrepareOnly
        Assert-True ($script:NdiVersionChecks -eq 1 -and $script:PreparedNdiCheck) 'Preflight did not retain the current version check.'
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 0 -and $script:NdiInstallCalls -eq 0 -and $script:NdiSignatureChecks -eq 0) 'Current NDI downloaded or ran an installer.'
        Assert-True ($script:NdiVersionChecks -eq 1 -and -not $script:PreparedNdiCheck) 'Update did not consume its preflight result.'
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiVersionChecks -eq 2 -and $script:NdiDownloads -eq 0) 'A later update reused stale version metadata.'
    }
    Test-Case 'A newer installed NDI version avoids downloading an older package' {
        . $ndiMocks
        $script:NdiInstalled = $true
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='7.0.0'} }
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 0 -and $script:NdiInstallCalls -eq 0) 'A newer local NDI version was downloaded or downgraded.'
    }
    Test-Case 'An older NDI installation stages one verified package and installs it' {
        . $ndiMocks
        $script:NdiInstalled = $true
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='5.0.0'} }
        Install-NdiTools -UpdateOnly -PrepareOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 0 -and $script:NdiSignatureChecks -eq 1) 'The update package was not verified before mutation.'
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1 -and $script:NdiSignatureChecks -eq 2) 'The staged package was downloaded twice or not reverified before execution.'
    }
    Test-Case 'Unavailable NDI metadata falls back to one verified download' {
        . $ndiMocks
        $script:NdiInstalled = $true
        function Get-CurrentNdiToolsVersion { $null }
        Install-NdiTools -UpdateOnly -PrepareOnly
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiSignatureChecks -eq 2 -and $script:NdiInstallCalls -eq 0) 'Metadata fallback bypassed package verification or reinstalled healthy NDI.'
    }
    Test-Case 'An unknown installed NDI version cannot bypass the verified installer' {
        . $ndiMocks
        $script:NdiInstalled = $true
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='unknown'} }
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1 -and $script:NdiVersionChecks -eq 0) 'An unknown installation was marked current.'
    }
    Test-Case 'NDI update repairs missing Discovery even at the advertised current version' {
        . $ndiMocks
        Install-NdiTools -UpdateOnly -PrepareOnly
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1 -and $script:NdiVersionChecks -eq 0) 'Version metadata prevented Discovery repair.'
    }
    Test-Case 'NDI rechecks local version and Discovery after a current preflight result' {
        . $ndiMocks
        $script:NdiInstalled = $true
        Install-NdiTools -UpdateOnly -PrepareOnly
        $script:NdiInstalled = $false
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1) 'Disappearing Discovery was hidden by a preflight result.'
        Install-NdiTools -UpdateOnly -PrepareOnly
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='5.0.0'} }
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 2 -and $script:NdiInstallCalls -eq 2) 'An older local replacement was hidden by a preflight result.'
    }
    Test-Case 'Explicit offline NDI updates never request online version metadata' {
        . $ndiMocks
        $script:NdiInstalled = $true
        $PackageDirectory = $testRoot
        function Get-CurrentNdiToolsVersion { throw 'Unexpected online metadata request' }
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiSignatureChecks -eq 1 -and $script:NdiInstallCalls -eq 0) 'Offline package version and signature were not checked.'
    }
    Test-Case 'NDI update metadata cannot authorize an unsigned newer installer' {
        . $ndiMocks
        $script:NdiInstalled = $true
        function Get-CurrentNdiToolsVersion { [version]'7.0.0.0' }
        function Get-InstallerSignatureWithProgress { [pscustomobject]@{Status='NotSigned'} }
        Assert-Throws { Install-NdiTools -UpdateOnly -PrepareOnly } 'signature validation failed'
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 0 -and -not $script:PreparedNdiInstaller) 'Unverified newer NDI reached installation.'
    }
    Test-Case 'NDI preflight rejects locked files before staging an installation' {
        . $ndiMocks
        function Assert-NdiToolsFilesAvailable { throw 'NDI Tools files are in use by: Fixture Server (PID 123).' }
        Assert-Throws { Install-NdiTools -PrepareOnly } 'files are in use.*Fixture Server'
        Assert-True ($script:NdiInstallCalls -eq 0 -and -not $script:PreparedNdiInstaller) 'The locked package reached installation or successful preflight.'
    }
    Test-Case 'NDI rechecks locks when consuming a verified prepared package' {
        . $ndiMocks
        Install-NdiTools -PrepareOnly
        function Assert-NdiToolsFilesAvailable { throw 'NDI Tools files are in use by: New Fixture Server.' }
        Assert-Throws { Install-NdiTools } 'files are in use.*New Fixture Server'
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 0) 'A newly locked file reached installation after preflight.'
    }
    Test-Case 'NDI uses a vendor log and never closes or restarts other applications' {
        . $ndiMocks
        function Start-QuietInstaller {
            param($FilePath, $ArgumentList)
            Assert-True ($ArgumentList -contains '/NOCLOSEAPPLICATIONS' -and $ArgumentList -contains '/NORESTARTAPPLICATIONS' -and $ArgumentList -contains '/NORESTART' -and $ArgumentList -contains '/RESTARTEXITCODE=3010') 'The installer can close apps or hide a restart requirement.'
            $log = @($ArgumentList | Where-Object { $_ -like '/LOG=*' })
            Assert-True ($log.Count -eq 1 -and $log[0].Contains($script:StateRoot)) 'The vendor diagnostic log is missing or outside the test state.'
            [pscustomobject]@{HasExited=$true;ExitCode=5} | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
        }
        Assert-Throws { Install-NdiTools } 'failed with exit code 5.*Vendor log:'
    }

    . (Join-Path $PSScriptRoot 'ServerUpdate.Regression.ps1')

    Test-Case 'Client resolves the current official NDI download including a future major version' {
        function Invoke-WebRequest {
            [pscustomobject]@{Links=@(
                [pscustomobject]@{name='anchor-without-href'},
                [pscustomobject]@{href='https://downloads.ndi.tv/Tools/NDI%207%20Tools.exe'},
                [pscustomobject]@{href='https://downloads.ndi.tv/Tools/NDI%207%20Tools.exe'},
                [pscustomobject]@{href='https://downloads.ndi.tv/Tools/NDIToolsInstaller.pkg'},
                [pscustomobject]@{href='https://example.com/Tools/NDI%207%20Tools.exe'}
            )}
        }
        Assert-True ((Get-CurrentNdiToolsUrl) -eq 'https://downloads.ndi.tv/Tools/NDI%207%20Tools.exe') 'The client download is tied to an old NDI major version.'
    }
    Test-Case 'An ambiguous or missing NDI download fails instead of using a stale URL' {
        function Invoke-WebRequest { [pscustomobject]@{Links=@()} }
        Assert-Throws { Get-CurrentNdiToolsUrl } 'could not be identified'
        function Invoke-WebRequest { [pscustomobject]@{Links=@(
            [pscustomobject]@{href='https://downloads.ndi.tv/Tools/NDI%207%20Tools.exe'},
            [pscustomobject]@{href='https://downloads.ndi.tv/Tools/NDI%208%20Tools.exe'}
        )} }
        Assert-Throws { Get-CurrentNdiToolsUrl } 'could not be identified'
    }
    $clientNdiMocks = {
        . $ndiMocks
        function Get-CurrentNdiToolsUrl { 'https://downloads.ndi.tv/Tools/NDI%207%20Tools.exe' }
        function Get-NdiDiscoveryExe { throw 'Client must not require Discovery Server' }
        function Download-FileWithProgress { param($Uri) $script:NdiDownloads++; $script:DownloadedNdiUrl = $Uri }
    }
    Test-Case 'Fresh client installs NDI without requiring a server component' {
        . $clientNdiMocks
        function Get-NdiRegistration { if ($script:NdiInstalled) { [pscustomobject]@{DisplayVersion='6.0.0'} } }
        Install-NdiTools -ClientOnly
        Assert-True ($script:NdiInstallCalls -eq 1 -and $script:DownloadedNdiUrl -match 'NDI%207') 'Fresh client did not install the current package.'
    }
    Test-Case 'Client reinstalls the current NDI package to repair missing files' {
        . $clientNdiMocks
        $script:NdiInstalled = $true
        Install-NdiTools -ClientOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1) 'Client bypassed latest-package validation or repair.'
    }
    Test-Case 'Client installs a newer NDI package and retains newer installed versions' {
        . $clientNdiMocks
        $script:NdiInstalled = $true
        function Get-Item { [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductVersion='7.0.0'}} }
        Install-NdiTools -ClientOnly
        Assert-True ($script:NdiInstallCalls -eq 1) 'An older NDI installation was not updated.'
        $script:NdiInstallCalls = 0
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='8.0.0'} }
        Install-NdiTools -ClientOnly
        Assert-True ($script:NdiInstallCalls -eq 0) 'Client attempted to downgrade NDI Tools.'
    }
    Test-Case 'Client refuses unsigned NDI downloads before launching a process' {
        . $clientNdiMocks
        function Get-InstallerSignatureWithProgress { [pscustomobject]@{Status='NotSigned'} }
        Assert-Throws { Install-NdiTools -ClientOnly } 'signature validation failed'
        Assert-True ($script:NdiInstallCalls -eq 0) 'An unverified NDI package was executed.'
    }
    Test-Case 'Client preserves the NDI restart exit code without scheduling a server resume' {
        . $clientNdiMocks
        function Start-QuietInstaller {
            param($ArgumentList)
            Assert-True ($ArgumentList -contains '/RESTARTEXITCODE=3010' -and $ArgumentList -contains '/NORESTART' -and $ArgumentList -contains '/NORESTARTAPPLICATIONS') 'NDI can restart Windows or applications without the Windows UI.'
            [pscustomobject]@{HasExited=$true;ExitCode=3010} | Add-Member -MemberType ScriptMethod -Name Dispose -Value { } -PassThru
        }
        Install-NdiTools -ClientOnly
        Assert-True $script:NdiRestartRequired 'NDI restart requirement was discarded.'
    }
    $clientOperationMocks = {
        $AcceptLicenses = $true
        $script:ClientSteps = New-Object Collections.Generic.List[string]
        function Install-NdiTools { param([switch]$ClientOnly) Assert-True $ClientOnly 'Client did not select NDI-only installation'; $script:ClientSteps.Add('NDI'); $script:NdiRestartRequired = $false }
        function Install-PcAgent { $script:ClientSteps.Add('Agent'); $true }
        function Save-Config { throw 'Client reached server configuration' }
        function Get-RequestedSuiteConfig { throw 'Client requested server settings' }
        function Get-LanCandidates { throw 'Client reached server networking' }
        function Ensure-WslFeatures { throw 'Client reached WSL setup' }
        function Configure-NdiServer { throw 'Client configured Discovery Server' }
        function Install-FirewallRules { throw 'Client opened server firewall ports' }
        function Register-MaintenanceEntry { throw 'Client registered server maintenance' }
    }
    Test-Case 'Client installs NDI then PC Agent without server setup or configuration writes' {
        . $clientOperationMocks
        Install-ClientTools
        Assert-True (($script:ClientSteps -join ',') -eq 'NDI,Agent' -and $script:OperationOutcome -eq 'Completed') 'Client installation did not complete both components in order.'
        Assert-True (-not (Test-Path -LiteralPath $script:ConfigPath)) 'Client saved a server configuration.'
    }
    Test-Case 'Client requires NDI licence acceptance before downloading or installing' {
        . $clientOperationMocks
        $AcceptLicenses = $false
        Assert-Throws { Install-ClientTools } 'licence before installing'
        Assert-True ($script:ClientSteps.Count -eq 0) 'Client changed the system before acceptance.'
    }
    Test-Case 'Cancelled PC Agent setup is not reported as successful client installation' {
        . $clientOperationMocks
        function Install-PcAgent { $false }
        Install-ClientTools
        Assert-True ($script:OperationOutcome -eq 'Cancelled' -and $script:OperationMessage -match 'PC Agent setup was not completed') 'Partial client setup was reported as complete.'
    }
    Test-Case 'Client reports an NDI restart after successful or cancelled agent setup' {
        . $clientOperationMocks
        function Install-NdiTools { $script:NdiRestartRequired = $true }
        Install-ClientTools
        Assert-True ($script:OperationOutcome -eq 'RestartRequired' -and (Get-InstallerExitCode) -eq 3010) 'Client restart was reported as completion.'
        function Install-PcAgent { $false }
        Install-ClientTools
        Assert-True ($script:OperationOutcome -eq 'RestartRequired' -and $script:OperationMessage -match 'not completed') 'A pending restart obscured incomplete agent setup.'
    }
    Test-Case 'A failed PC Agent install cannot complete the client operation' {
        . $clientOperationMocks
        function Install-PcAgent { throw 'Fixture PC Agent download failure' }
        Assert-Throws { Install-ClientTools } 'download failure'
        Assert-True ($script:OperationOutcome -ne 'Completed') 'Agent failure was reported as success.'
    }
    $pcReleaseMocks = {
        $script:PcRelease = [pscustomobject]@{draft=$false;prerelease=$false;target_commitish='main';tag_name='v0.7.0';assets=@(
            [pscustomobject]@{name='NDI-Configurator-PC-Agent-win-x64.zip';size=100;digest=('sha256:' + ('a' * 64));browser_download_url='https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/download/v0.7.0/NDI-Configurator-PC-Agent-win-x64.zip'}
        )}
        function Invoke-RestMethod { $script:PcRelease }
    }
    Test-Case 'PC Agent selects the complete stable package from its own production feed' {
        . $pcReleaseMocks
        $release = Get-PcAgentRelease
        Assert-True ($release.Version -eq [version]'0.7.0' -and $release.Size -eq 100 -and $release.Hash -eq ('a' * 64)) 'The PC Agent release metadata was changed or lost.'
        $script:PcRelease.prerelease = $true
        Assert-Throws { Get-PcAgentRelease } 'production release could not be verified'
    }
    Test-Case 'PC Agent rejects untrusted download URLs and missing SHA-256 metadata' {
        . $pcReleaseMocks
        $script:PcRelease.assets[0].browser_download_url = 'https://example.com/agent.zip'
        Assert-Throws { Get-PcAgentRelease } 'download URL, size or SHA-256'
        . $pcReleaseMocks
        $script:PcRelease.assets[0].PSObject.Properties.Remove('digest')
        Assert-Throws { Get-PcAgentRelease } 'download URL, size or SHA-256'
    }
    $publicReleaseMocks = {
        $script:PublicTag = 'https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/tag/v0.7.0'
        $script:PublicChecksum = ('a' * 64) + '  NDI-Configurator-PC-Agent-win-x64.zip' + "`r`n"
        $script:PublicSize = '133089006'
        $script:PublicModernResponse = $false
        function Invoke-RestMethod { throw 'The remote server returned an error: (403) Forbidden.' }
        function Invoke-WebRequest {
            param($Uri, $Method)
            if ($Uri.EndsWith('/latest')) {
                if ($script:PublicModernResponse) { return [pscustomobject]@{BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri=[uri]$script:PublicTag}}} }
                return [pscustomobject]@{BaseResponse=[pscustomobject]@{ResponseUri=[uri]$script:PublicTag}}
            }
            Assert-True ($Uri.StartsWith('https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/download/v0.7.0/')) 'Fallback left the exact publisher release.'
            if ($Uri.EndsWith('.sha256')) { return [pscustomobject]@{Content=$script:PublicChecksum} }
            Assert-True ($Method -eq 'Head') 'Metadata check downloaded the complete package.'
            return [pscustomobject]@{Headers=@{'Content-Length'=$script:PublicSize}}
        }
    }
    Test-Case 'GitHub 403 falls back to a verified public PC Agent release in PowerShell 5 and 7' {
        . $publicReleaseMocks
        foreach ($modern in @($false,$true)) {
            $script:PublicModernResponse = $modern
            if ($modern) { $script:PublicChecksum = [Text.Encoding]::UTF8.GetBytes($script:PublicChecksum) }
            $release = Get-PcAgentRelease
            Assert-True ($release.Version -eq [version]'0.7.0' -and $release.Size -eq 133089006 -and $release.Hash -eq ('a' * 64)) 'The public release lost its version, size or checksum.'
        }
    }
    Test-Case 'PC Agent public fallback rejects foreign redirects, preview tags and mismatched checksums' {
        . $publicReleaseMocks
        foreach ($bad in @('https://example.com/releases/tag/v0.7.0','https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/tag/v0.8.0-dev.1')) {
            $script:PublicTag = $bad
            Assert-Throws { Get-PcAgentRelease } 'public production release could not be verified'
        }
        . $publicReleaseMocks
        $script:PublicChecksum = ('a' * 64) + '  another-package.zip'
        Assert-Throws { Get-PcAgentRelease } 'checksum is missing or invalid'
        . $publicReleaseMocks
        $script:PublicSize = '9999999999'
        Assert-Throws { Get-PcAgentRelease } 'download size is invalid'
    }
    Test-Case 'NDI failure always disposes the private desktop and preserves its failure code' {
        . $clientNdiMocks
        $script:QuietDisposed = $false
        function Start-QuietInstaller {
            [pscustomobject]@{HasExited=$true;ExitCode=7} | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:QuietDisposed = $true } -PassThru
        }
        Assert-Throws { Install-NdiTools -ClientOnly } 'failed with exit code 7'
        Assert-True $script:QuietDisposed 'A failed vendor install left its windows running.'
    }
    Test-Case 'PC Agent archive validation rejects traversal and duplicate paths before extraction' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($badPath in @('../escape.exe','/absolute.exe','nested/../../escape.exe','GOOD.txt','file.txt:stream','folder/NUL.txt')) {
            $archive = Join-Path $testRoot ([guid]::NewGuid().ToString('N') + '.zip')
            $zip = [IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
            try { [void]$zip.CreateEntry('good.txt'); [void]$zip.CreateEntry($badPath) } finally { $zip.Dispose() }
            $destination = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
            Assert-Throws { Expand-PcAgentPackage $archive $destination } 'unsafe|not supported|illegal|format'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $destination 'good.txt'))) 'Extraction began before every path was validated.'
        }
    }
    Test-Case 'PC Agent archive extraction supports normal Windows filenames and nested payloads' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = Join-Path $testRoot 'valid-agent.zip'
        $zip = [IO.Compression.ZipFile]::Open($archive,[IO.Compression.ZipArchiveMode]::Create)
        try { [void]$zip.CreateEntry('NDI Configurator PC Agent Setup.exe'); [void]$zip.CreateEntry('Agent/NDI Configurator PC Agent.exe') } finally { $zip.Dispose() }
        $destination = Join-Path $testRoot 'valid-agent-payload'
        Expand-PcAgentPackage $archive $destination
        Assert-True (Test-Path -LiteralPath (Join-Path $destination 'Agent\NDI Configurator PC Agent.exe')) 'The complete nested agent payload was not extracted.'
    }
    Test-Case 'PC Agent validates product identity and normalizes binary versions' {
        function Test-Path { $true }
        function Get-Item { [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductName='NDI Configurator PC Agent';ProductVersion='0.7.0.0'}} }
        Assert-True ((Get-PcAgentBinaryVersion 'fixture.exe' 'NDI Configurator PC Agent') -eq [version]'0.7.0') 'The valid four-part binary version was rejected.'
        Assert-True ($null -eq (Get-PcAgentBinaryVersion 'fixture.exe' 'Other Product')) 'A different product passed identity validation.'
    }
    Test-Case 'PC Agent retains a configured newer independent installation without downloading' {
        function Get-PcAgentRelease { [pscustomobject]@{Version=[version]'0.7.0'} }
        function Get-PcAgentBinaryVersion { [version]'0.8.0' }
        function Test-PcAgentConfigured { $true }
        function Download-FileWithProgress { throw 'A newer PC Agent must not be downloaded over' }
        Assert-True (Install-PcAgent) 'A newer configured PC Agent was rejected.'
    }
    Test-Case 'PC Agent refuses a corrupted release package before extraction or execution' {
        function Get-PcAgentRelease { [pscustomobject]@{Version=[version]'0.7.0';Url='https://example.invalid/fixture';Size=7;Hash=('0' * 64)} }
        function Get-PcAgentBinaryVersion { $null }
        function Download-FileWithProgress { param($Destination) [IO.File]::WriteAllBytes($Destination,[Text.Encoding]::ASCII.GetBytes('fixture')) }
        function Expand-PcAgentPackage { throw 'Corrupt package reached extraction' }
        Assert-Throws { Install-PcAgent } 'size or SHA-256 did not match'
    }
    Test-Case 'PC Agent setup cancellation and an unconfigured zero exit remain incomplete' {
        $script:AgentSetupExitCode = 2
        function Start-Process {
            param($WindowStyle)
            Assert-True ($WindowStyle -eq 'Normal') 'The native PC Agent window was hidden.'
            $process = [pscustomobject]@{HasExited=$true;ExitCode=$script:AgentSetupExitCode}
            $process | Add-Member ScriptMethod Dispose { }
            return $process
        }
        function Test-PcAgentConfigured { $false }
        Assert-True (-not (Invoke-PcAgentSetup 'C:\Fixture\Agent Setup.exe')) 'EULA cancellation was treated as completed installation.'
        $script:AgentSetupExitCode = 0
        Assert-True (-not (Invoke-PcAgentSetup 'C:\Fixture\Agent Setup.exe')) 'Closing before adapter setup was treated as success.'
        function Test-PcAgentConfigured { $true }
        Assert-True (Invoke-PcAgentSetup 'C:\Fixture\Agent Setup.exe') 'Configured agent setup was rejected.'
        $script:AgentSetupExitCode = 1
        Assert-Throws { Invoke-PcAgentSetup 'C:\Fixture\Agent Setup.exe' } 'failed with exit code 1'
    }
    Test-Case 'PC Agent verifies the complete download and installed files around its native setup' {
        $script:AgentSetupRan = $false
        $script:AgentPayloadReady = $false
        $bytes = [Text.Encoding]::ASCII.GetBytes('fixture')
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $script:AgentFixtureHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') } finally { $sha.Dispose() }
        function Get-PcAgentRelease { [pscustomobject]@{Version=[version]'0.7.0';Url='https://example.invalid/fixture';Size=7;Hash=$script:AgentFixtureHash} }
        function Download-FileWithProgress { param($Destination) [IO.File]::WriteAllBytes($Destination,[Text.Encoding]::ASCII.GetBytes('fixture')) }
        function Expand-PcAgentPackage {
            param($Archive,$Destination)
            $script:AgentPayloadReady = $true
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Destination 'LICENSE.md') -Value 'Fixture licence'
        }
        function Get-PcAgentBinaryVersion {
            param($Path,$Product)
            Assert-True ($Product -eq 'NDI Configurator PC Agent') 'The package product metadata does not match the real release.'
            if ($script:AgentSetupRan -or ($script:AgentPayloadReady -and $Path -like '*\Payload-*\*')) { [version]'0.7.0' }
        }
        function Invoke-PcAgentSetup {
            param($Path)
            Assert-True ($script:AgentPayloadReady -and $Path -like '*\Payload-*\NDI Configurator PC Agent Setup.exe') 'The native setup launched outside its verified package.'
            $script:AgentSetupRan = $true
            $true
        }
        Assert-True (Install-PcAgent) 'The complete verified agent flow did not finish.'
        Assert-True $script:AgentSetupRan 'The agent was reported installed without launching setup.'
    }

    Test-Case 'Firewall opens the complete streaming range in both firewalls' {
        function Remove-NetFirewallRule { }
        function Remove-NetFirewallHyperVRule { }
        $script:Rules = New-Object Collections.Generic.List[object]
        function Get-NetFirewallRule { }
        function Get-NetFirewallHyperVRule { }
        function New-NetFirewallRule {
            param($DisplayName,$Group,$Direction,$Action,$Protocol,$LocalPort,$Profile,$RemoteAddress,$LocalAddress,$EdgeTraversalPolicy)
            Assert-True (($Profile -join ',') -eq 'Domain,Private' -and $RemoteAddress -eq 'LocalSubnet' -and $EdgeTraversalPolicy -eq 'Block') 'Environment firewall lost its LAN/profile boundary.'
            if ($Protocol -eq 'TCP') { Assert-True ($LocalAddress -eq '192.0.2.10') 'TCP management traffic is not scoped to the selected local address.' }
            $script:Rules.Add([pscustomobject]@{Kind='Windows';Protocol=$Protocol;Ports=$LocalPort})
        }
        function New-NetFirewallHyperVRule {
            param($Name,$DisplayName,$Direction,$VMCreatorId,$Protocol,$LocalPorts,$Action)
            $script:Rules.Add([pscustomobject]@{Kind='HyperV';Protocol=$Protocol;Ports=$LocalPorts})
        }
        Install-FirewallRules (New-Config)
        foreach ($kind in @('Windows','HyperV')) {
            foreach ($protocol in @('TCP','UDP')) {
                foreach ($port in @(7960,7962,8500,10000)) {
                    $allowed = $false
                    foreach ($rule in @($script:Rules | Where-Object { $_.Kind -eq $kind -and $_.Protocol -eq $protocol })) {
                        foreach ($range in $rule.Ports) {
                            $bounds = ([string]$range).Split('-')
                            if (($bounds.Count -eq 1 -and $port -eq [int]$bounds[0]) -or
                                ($bounds.Count -eq 2 -and $port -ge [int]$bounds[0] -and $port -le [int]$bounds[1])) { $allowed = $true }
                        }
                    }
                    Assert-True $allowed "$kind $protocol blocks port $port."
                }
            }
        }
    }

    $ndiHealthMocks = {
        function Get-NdiDiscoveryService { [pscustomobject]@{Name='NDI';Status='Running'} }
        function Get-CimInstance { [pscustomobject]@{ProcessId=777} }
        function Get-NdiDiscoveryExe { 'C:\Fake\NDI Discovery Service.exe' }
        function Get-NetTCPConnection { [pscustomobject]@{LocalAddress='0.0.0.0';OwningProcess=777} }
    }
    Test-Case 'NDI service must own a listening socket' {
        . $ndiHealthMocks
        Assert-True (Test-NdiServerReady (New-Config)) 'A healthy NDI listener was rejected.'
        function Get-NetTCPConnection { [pscustomobject]@{LocalAddress='0.0.0.0';OwningProcess=888} }
        Assert-True (-not (Test-NdiServerReady (New-Config))) 'An unrelated listener passed NDI health.'
    }
    Test-Case 'Stopped NDI service fails readiness' {
        . $ndiHealthMocks
        function Get-NdiDiscoveryService { [pscustomobject]@{Name='NDI';Status='Stopped'} }
        Assert-True (-not (Test-NdiServerReady (New-Config))) 'A stopped service passed.'
    }
    Test-Case 'NDI fallback task must be running and own the listener' {
        . $ndiHealthMocks
        function Get-NdiDiscoveryService { $null }
        function Get-ScheduledTask { [pscustomobject]@{State='Running'} }
        function Get-Process { [pscustomobject]@{Path='C:\Fake\NDI Discovery Service.exe'} }
        Assert-True (Test-NdiServerReady (New-Config)) 'A healthy fallback task was rejected.'
        function Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        Assert-True (-not (Test-NdiServerReady (New-Config))) 'An idle fallback task passed.'
    }
    $healthMocks = {
        function Get-ScheduledTask { [pscustomobject]@{State='Running'} }
        function Invoke-Wsl { 'running' }
        function Test-NdiServerReady { $true }
        function Invoke-WebRequest { [pscustomobject]@{StatusCode=200} }
    }
    Test-Case 'Healthy services pass without waiting' {
        . $healthMocks
        Test-SuiteHealth (New-Config) -TimeoutSeconds 0
    }
    Test-Case 'Stopped NDI and unavailable web fail the final health check' {
        . $healthMocks
        function Test-NdiServerReady { $false }
        function Invoke-WebRequest { throw 'Connection refused' }
        Assert-Throws { Test-SuiteHealth (New-Config) -TimeoutSeconds 0 } 'NDI Discovery Server.*Connection refused'
    }
    Test-Case 'Health checks retry startup delays and stop at the deadline' {
        . $healthMocks
        $script:Seconds = 0
        function Get-Date { [datetime]'2026-09-05T00:00:00Z' + [timespan]::FromSeconds($script:Seconds) }
        function Wait-SuiteProgressInterval { $script:Seconds += 2 }
        function Invoke-WebRequest {
            if ($script:Seconds -lt 2) { throw 'Starting' }
            [pscustomobject]@{StatusCode=200}
        }
        Test-SuiteHealth (New-Config) -TimeoutSeconds 4
        Assert-True ($script:Seconds -eq 2) 'A delayed web service was not retried.'
        $script:Seconds = 0
        function Invoke-WebRequest { throw 'Still unavailable' }
        Assert-Throws { Test-SuiteHealth (New-Config) -TimeoutSeconds 4 } 'after 4 seconds'
        Assert-True ($script:Seconds -eq 4) 'Health retries exceeded the deadline.'
    }
    Test-Case 'Running tasks are stopped before replacement' {
        $script:Stopped = $false
        function Get-ScheduledTask { [pscustomobject]@{State=$(if ($script:Stopped) {'Ready'} else {'Running'})} }
        function Stop-ScheduledTask { $script:Stopped = $true }
        Stop-ManagedTask 'Test task'
        Assert-True $script:Stopped 'The old task remained running.'
    }
    Test-Case 'Task stop timeout prevents replacement' {
        function Get-ScheduledTask { [pscustomobject]@{State='Running'} }
        function Stop-ScheduledTask { }
        function Wait-SuiteProgressInterval { }
        Assert-Throws { Stop-ManagedTask 'Test task' -TimeoutSeconds 0 } 'did not stop'
    }

    $menuMocks = {
        $script:Inputs = New-Object Collections.Generic.Queue[string]
        foreach ($inputValue in @('1','','4')) { $script:Inputs.Enqueue($inputValue) }
        function Clear-Host { }
        function Show-State { }
        function Get-InstallState { [pscustomobject]@{Any=$true} }
        function Read-InstallerInput { $script:Inputs.Dequeue() }
    }
    Test-Case 'Failed operation then Exit retains failure status' {
        . $menuMocks
        function Update-Suite { throw 'Simulated update failure' }
        Show-Menu
        Assert-True ((Get-InstallerExitCode) -eq 1 -and $script:OperationOutcome -eq 'Failed') 'Menu discarded an operation failure.'
    }
    Test-Case 'A successful retry clears a previous failure' {
        Set-OperationOutcome 'Failed' 'Failed first attempt'
        Set-OperationOutcome 'Running' 'Retrying'
        Assert-True ((Get-InstallerExitCode) -eq 1) 'An incomplete retry cleared failure.'
        Set-OperationOutcome 'Completed' 'Recovered'
        Assert-True ((Get-InstallerExitCode) -eq 0) 'A successful retry retained failure.'
    }
    Test-Case 'Restart continuation reports restart-required exit code' {
        Set-OperationOutcome 'RestartRequired' 'Restart pending'
        Assert-True ((Get-InstallerExitCode) -eq 3010) 'Restart was reported as completed.'
    }
    Test-Case 'PowerShell entry point returns failure and emits a failure event' {
        $fixtureMocks = @'
$script:StateRoot = Join-Path $PSScriptRoot 'fixture-state'
$script:Inputs = New-Object Collections.Generic.Queue[string]
foreach ($value in @('1','','4')) { $script:Inputs.Enqueue($value) }
function Ensure-Administrator { }
function Clear-Host { }
function Show-State { }
function Get-InstallState { [pscustomobject]@{Any=$true} }
function Read-InstallerInput { $script:Inputs.Dequeue() }
function Update-Suite { throw 'Fixture update failure' }

'@
        $source = [IO.File]::ReadAllText($installerPath)
        $fixturePath = Join-Path $testRoot 'entry-fixture.ps1'
        [IO.File]::WriteAllText($fixturePath,$source.Insert($entryOffset,$fixtureMocks),[Text.Encoding]::UTF8)
        $output = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath -LauncherMode -Action Update -AcceptLicenses
        $code = $LASTEXITCODE
        Assert-True ($code -eq 1) "The real entry point returned $code after failure."
        $events = @($output | Where-Object { $_ -like '@@KILOVIEW_EVENT@@*' } | ForEach-Object { $_.Substring('@@KILOVIEW_EVENT@@'.Length) | ConvertFrom-Json })
        Assert-True (@($events | Where-Object { $_.type -eq 'outcome' -and $_.outcome -eq 'Failed' }).Count -eq 1) 'The launcher failure event was missing.'
    }
    Test-Case 'Real Client entry point needs no network request and enforces acceptance' {
        $fixtureMocks = @'
function Ensure-Administrator { }
function Write-InstallerLog { }
function Install-NdiTools { param([switch]$ClientOnly) if (-not $ClientOnly) { throw 'Not the client NDI path' }; $script:NdiRestartRequired = $false }
function Install-PcAgent { $true }
function Get-RequestedSuiteConfig { throw 'Client requested server configuration' }
function Repair-Suite { throw 'Client entered server installation' }
function Register-MaintenanceEntry { throw 'Client registered server maintenance' }

'@
        $source = [IO.File]::ReadAllText($installerPath)
        $fixturePath = Join-Path $testRoot 'client-entry-fixture.ps1'
        [IO.File]::WriteAllText($fixturePath,$source.Insert($entryOffset,$fixtureMocks),[Text.Encoding]::UTF8)
        $output = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath -LauncherMode -Action InstallClient -AcceptLicenses
        Assert-True ($LASTEXITCODE -eq 0) 'The Client action failed without a server request.'
        Assert-True (($output -join "`n") -match '"outcome":"Completed"') 'The real client entry point did not report both tools installed.'
        $fixtureReceipt = Join-Path $env:ProgramData 'KiloLink\installation-components.json'
        Assert-True (Test-Path -LiteralPath $fixtureReceipt) 'The child Client fixture did not write its receipt inside the isolated ProgramData.'
        $output = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath -LauncherMode -Action InstallClient
        Assert-True ($LASTEXITCODE -eq 1 -and ($output -join "`n") -match '"outcome":"Failed"') 'Missing NDI acceptance was not rejected by the real entry point.'
    }
    Test-Case 'Generated watchdog task retries failures and preserves WSL exit codes' {
        $script:TaskEvents = New-Object Collections.Generic.List[string]
        function Stop-ManagedTask { $script:TaskEvents.Add('Stop') }
        function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Argument=$Argument} }
        function New-ScheduledTaskTrigger { [pscustomobject]@{Delay=''} }
        function New-ScheduledTaskPrincipal { [pscustomobject]@{User='Fixture'} }
        function New-ScheduledTaskSettingsSet { param($RestartCount,$RestartInterval) [pscustomobject]@{RestartCount=$RestartCount;RestartInterval=$RestartInterval} }
        function Register-ScheduledTask { param($Settings) $script:TaskEvents.Add('Register'); $script:TaskSettings = $Settings }
        function Start-ScheduledTask { $script:TaskEvents.Add('Start') }
        Install-StartupTask (New-Config)
        Assert-True (($script:TaskEvents -join ',') -eq 'Stop,Register,Start') 'The old watchdog was not replaced in the correct order.'
        Assert-True ($script:TaskSettings.RestartCount -eq 3 -and $script:TaskSettings.RestartInterval.TotalMinutes -eq 1) 'The watchdog has no bounded failure retry.'
        $helperTokens = $null
        $helperErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:StartupScriptPath,[ref]$helperTokens,[ref]$helperErrors)
        Assert-True ($helperErrors.Count -eq 0) ($helperErrors | Out-String)
        $fixturePath = Join-Path $testRoot 'watchdog-exit-fixture.ps1'
        $fixture = "function wsl.exe { `$global:LASTEXITCODE = 7 }`n" + [IO.File]::ReadAllText($script:StartupScriptPath)
        [IO.File]::WriteAllText($fixturePath,$fixture,[Text.Encoding]::UTF8)
        & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath | Out-Null
        Assert-True ($LASTEXITCODE -eq 7) 'The generated watchdog swallowed the WSL exit code.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Web.Extensions
    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root 'Kiloview-Environment-Setup.exe')))
    $formType = $assembly.GetType('KiloLink.Setup.SetupForm')
    $staticFlags = [Reflection.BindingFlags]'NonPublic,Static'
    $instanceFlags = [Reflection.BindingFlags]'NonPublic,Instance'
    $networkScript = $formType.GetMethod('BuildStaticNetworkScript',$staticFlags).Invoke($null,@('Ethernet','192.0.2.20',24,'192.0.2.1','192.0.2.1',''))
    Test-Case 'Native setup starts with Server or Client before loading network adapters' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            Assert-True ($formType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Role') 'The first screen is not the role choice.'
            Assert-True ($formType.GetField('serverChoice',$instanceFlags).GetValue($form).Checked) 'Server is not the normal default.'
            Assert-True ($formType.GetField('networkAdapterBox',$instanceFlags).GetValue($form).Items.Count -eq 0) 'Network discovery ran before the role choice.'
            Assert-True ($form.AcceptButton -eq $formType.GetField('roleNextButton',$instanceFlags).GetValue($form)) 'Enter does not advance the role choice.'
            [void]$formType.GetMethod('ChooseRole',$instanceFlags).Invoke($form,@())
            Assert-True ($formType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Welcome') 'Server did not retain its existing maintenance flow.'
            Assert-True ($formType.GetField('networkAdapterBox',$instanceFlags).GetValue($form).Items.Count -eq 0) 'Server queried networking before the maintenance choice.'
        } finally { $form.Dispose() }
    }
    Test-Case 'Native pages fit their content across display scales and constrained desktops' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $form.Opacity = 0; $form.ShowInTaskbar = $false; $form.Show()
            $formType.GetField('preferredInterfaceAlias',$instanceFlags).SetValue($form,'Production Ethernet')
            $formType.GetField('preferredIpAddress',$instanceFlags).SetValue($form,'192.0.2.10')
            foreach ($scale in @([single]1, [single]1.25, [single]1.5, [single]2, [single]2.5, [single]1)) {
                [void]$formType.GetMethod('ApplyDisplayScale',$instanceFlags).Invoke($form,@($scale))
                [void]$formType.GetMethod('ApplyDisplayScale',$instanceFlags).Invoke($form,@($scale))
                foreach ($method in @('ShowHome','ShowServerHome','ShowNetworkPage','ShowSettings','ReviewSelectedAction','ShowProgressView')) {
                    $args = if ($method -eq 'ShowSettings') { @('') } else { @() }
                    [void]$formType.GetMethod($method,$instanceFlags).Invoke($form,$args)
                    [Windows.Forms.Application]::DoEvents()
                    foreach ($area in @([Drawing.Rectangle]::new(0,0,1920,1040),[Drawing.Rectangle]::new(0,0,1366,728))) {
                        [void]$formType.GetMethod('FitPageToArea',$instanceFlags).Invoke($form,@($area,$true))
                        $page = $formType.GetMethod('CurrentPage',$instanceFlags).Invoke($form,@())
                        Assert-True ($form.Width -le $area.Width -and $form.Height -le $area.Height) "$method at $scale exceeds the desktop."
                        $controls = @($page.Controls | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0 })
                        foreach ($control in $controls) {
                            Assert-True ($control.Right -le $page.ClientSize.Width -and $control.Left -ge 0) "$method at $scale clips $($control.Text) horizontally."
                            Assert-True (-not ($control -is [Windows.Forms.RichTextBox]) -and $control.Font.FontFamily.Name -ne 'Consolas') 'A console-style output pane is visible.'
                            foreach ($other in $controls) {
                                if ($control -ne $other) { Assert-True (-not $control.Bounds.IntersectsWith($other.Bounds)) "$method at $scale overlaps '$($control.Text)' and '$($other.Text)'." }
                            }
                        }
                        $lastBottom = ($controls | Measure-Object Bottom -Maximum).Maximum
                        Assert-True ($page.AutoScrollMinSize.Height -ge $lastBottom) 'Controls are unreachable at the end of the page.'
                        if ($scale -eq 1 -and $method -eq 'ShowHome') { Assert-True ($form.Height -lt 430) 'The first page retained a large blank area.' }
                        $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
                        try { $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)) } finally { $bitmap.Dispose() }
                    }
                }
            }
        } finally { $form.Dispose() }
    }
    Test-Case 'Native Client skips server networking and ports and reviews only client tools' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Show()
            $formType.GetField('clientChoice',$instanceFlags).GetValue($form).Checked = $true
            [void]$formType.GetMethod('ChooseRole',$instanceFlags).Invoke($form,@())
            Assert-True ($formType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Review') 'Client did not skip server setup.'
            Assert-True ($formType.GetField('networkAdapterBox',$instanceFlags).GetValue($form).Items.Count -eq 0) 'Client queried server adapters.'
            $review = $formType.GetField('reviewText',$instanceFlags).GetValue($form).Text
            Assert-True ($review -match 'NDI Tools' -and $review -match 'PC Agent' -and $review -notmatch 'KiloLink Server|Discovery Server|Server IPv4') 'Client review contains server configuration.'
            $links = @($formType.GetField('reviewPanel',$instanceFlags).GetValue($form).Controls | Where-Object { $_ -is [Windows.Forms.LinkLabel] -and $_.Visible })
            Assert-True ($links.Count -eq 2 -and @($links | Where-Object Name -eq 'kiloTerms').Count -eq 0) 'Client showed the wrong vendor licences.'
            $arguments = $formType.GetMethod('BuildOperationArguments',$instanceFlags)
            Assert-Throws { $arguments.Invoke($form,@()) } 'NDI Tools licence acceptance'
            $formType.GetField('acceptanceBox',$instanceFlags).GetValue($form).Checked = $true
            Assert-True ($arguments.Invoke($form,@()) -eq ' -Action InstallClient -AcceptLicenses') 'Client created a server request or launched a menu.'
            Assert-True ($null -eq $formType.GetField('requestPath',$instanceFlags).GetValue($form)) 'Client wrote a network configuration request.'
            [void]$formType.GetMethod('ShowHome',$instanceFlags).Invoke($form,@())
            Assert-True ($formType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Role') 'Back to setup skipped the role choice.'
        } finally { $form.Dispose() }
    }
    Test-Case 'Native client completion and restart omit server endpoints and continuation promises' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $formType.GetField('selectedAction',$instanceFlags).SetValue($form,'InstallClient')
            $handler = $formType.GetMethod('HandleOutputLine',$instanceFlags)
            [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@{"type":"summary","webUrl":"http://192.0.2.10:80/","ndiEndpoint":"192.0.2.10:5959"}'))
            Assert-True ($null -eq $formType.GetField('resultWebUrl',$instanceFlags).GetValue($form)) 'Client exposed a KiloLink login.'
            [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@{"type":"outcome","outcome":"Completed","message":"NDI Tools and PC Agent are installed."}'))
            [void]$formType.GetMethod('FinishWizardOperation',$instanceFlags).Invoke($form,@(0))
            $endpoint = $formType.GetField('endpointLabel',$instanceFlags).GetValue($form).Text
            Assert-True ($endpoint -match 'onboard this PC' -and $endpoint -notmatch 'admin|5959') 'Client completion used server endpoints.'
            [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@{"type":"outcome","outcome":"RestartRequired","message":"Restart Windows to finish NDI Tools installation."}'))
            [void]$formType.GetMethod('ApplyInstallerOutcome',$instanceFlags).Invoke($form,@(3010))
            $status = $formType.GetField('progressStatusLabel',$instanceFlags).GetValue($form).Text
            Assert-True ($status -match 'NDI Tools' -and $status -notmatch 'sign back in to continue') 'Client restart incorrectly promised server continuation.'
        } finally { $form.Dispose(); [Environment]::ExitCode = 0 }
    }
    Test-Case 'Native uninstall reaches review without requiring network configuration' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $formType.GetField('uninstallChoice',$instanceFlags).GetValue($form).Checked = $true
            [void]$formType.GetMethod('BeginSelectedAction',$instanceFlags).Invoke($form,@())
            Assert-True ($formType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Review') 'Uninstall was blocked by the network page.'
            $execute = $formType.GetField('executeButton',$instanceFlags).GetValue($form)
            Assert-True (-not $execute.Enabled) 'Data removal is enabled before confirmation.'
            $arguments = $formType.GetMethod('BuildOperationArguments',$instanceFlags)
            Assert-Throws { $arguments.Invoke($form,@()) } 'Confirm permanent data removal'
            $formType.GetField('acceptanceBox',$instanceFlags).GetValue($form).Checked = $true
            Assert-True ($execute.Enabled -and $arguments.Invoke($form,@()) -eq ' -Action Uninstall -ConfirmRemoval') 'Native confirmation did not select the uninstall action.'
        } finally { $form.Dispose() }
    }
    Test-Case 'Native service controls reject odd link ports and conflicting TCP listeners' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $formType.GetField('preferredInterfaceAlias',$instanceFlags).SetValue($form,'Ethernet')
            $formType.GetField('preferredIpAddress',$instanceFlags).SetValue($form,'192.0.2.10')
            $validate = $formType.GetMethod('ValidateServiceSettings',$instanceFlags)
            Assert-True ($null -eq $validate.Invoke($form,@())) 'Default ports were rejected.'
            $formType.GetField('linkPortBox',$instanceFlags).GetValue($form).Value = 50001
            Assert-True ($validate.Invoke($form,@()) -match 'must be even') 'An odd link port was allowed.'
            $formType.GetField('linkPortBox',$instanceFlags).GetValue($form).Value = 50000
            $formType.GetField('ndiPortBox',$instanceFlags).GetValue($form).Value = 80
            Assert-True ($validate.Invoke($form,@()) -match 'different TCP ports') 'Two listeners on one TCP port were allowed.'
        } finally { $form.Dispose() }
    }
    Test-Case 'Native review requires acceptance and serializes all configurable values' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $formType.GetField('launcherDirectory',$instanceFlags).SetValue($form,$testRoot)
            $formType.GetField('preferredInterfaceAlias',$instanceFlags).SetValue($form,'Ethernet "AV"')
            $formType.GetField('preferredIpAddress',$instanceFlags).SetValue($form,'192.0.2.10')
            $formType.GetField('webPortBox',$instanceFlags).GetValue($form).Value = 8088
            [void]$formType.GetMethod('ReviewSelectedAction',$instanceFlags).Invoke($form,@())
            $arguments = $formType.GetMethod('BuildOperationArguments',$instanceFlags)
            Assert-Throws { $arguments.Invoke($form,@()) } 'licence acceptance'
            $formType.GetField('acceptanceBox',$instanceFlags).GetValue($form).Checked = $true
            $value = $arguments.Invoke($form,@())
            Assert-True ($value -like ' -Action Install -AcceptLicenses -ConfigurationPath *') 'The worker still launches an interactive menu.'
            $request = $formType.GetField('requestPath',$instanceFlags).GetValue($form)
            $json = Get-Content -Raw -LiteralPath $request | ConvertFrom-Json
            Assert-True ($json.PrimaryInterfaceAlias -eq 'Ethernet "AV"' -and $json.WebPort -eq 8088 -and $json.LinkPort -eq 50000 -and $json.NdiDiscoveryPort -eq 5959 -and $json.PublicIp -eq '192.0.2.10') 'Request serialization lost or changed a setting.'
            [void]$formType.GetMethod('FinishWizardOperation',$instanceFlags).Invoke($form,@(0))
            Assert-True (-not (Test-Path -LiteralPath $request)) 'The completed request was not cleaned up.'
        } finally { $form.Dispose() }
    }
    $networkMocks = {
        $script:NetworkApplied = $false
        $script:Rollback = $false
        $script:AddressReads = 0
        $script:Seconds = 0
        function Get-Date { [datetime]'2026-09-05T00:00:00Z' + [timespan]::FromSeconds($script:Seconds) }
        function Start-Sleep { $script:Seconds++ }
        function Get-NetAdapter { [pscustomobject]@{ifIndex=7;Name='Ethernet'} }
        function Get-NetIPInterface { [pscustomobject]@{Dhcp='Enabled'} }
        function Get-NetIPAddress {
            if ($script:NetworkApplied) {
                $script:AddressReads++
                [pscustomobject]@{IPAddress='192.0.2.20';PrefixLength=24;PrefixOrigin='Manual';AddressState=$script:AddressState}
            } else { [pscustomobject]@{IPAddress='192.0.2.10';PrefixLength=24;PrefixOrigin='Dhcp';AddressState='Preferred'} }
        }
        function Get-NetRoute { }
        function Get-DnsClientServerAddress { [pscustomobject]@{ServerAddresses=@('192.0.2.1')} }
        function Set-NetIPInterface { param($InterfaceIndex,$AddressFamily,$Dhcp,$ErrorAction) if ($Dhcp -eq 'Enabled') { $script:Rollback = $true } }
        function Remove-NetRoute { }
        function Remove-NetIPAddress { }
        function New-NetIPAddress { $script:NetworkApplied = $true }
        function Set-DnsClientServerAddress { }
    }
    Test-Case 'Generated network script parses and accepts a preferred address' {
        . $networkMocks
        $script:AddressState = 'Preferred'
        $output = & ([scriptblock]::Create($networkScript))
        Assert-True ($output -match 'Configured 192.0.2.20') 'Preferred address was rejected.'
        Assert-True (-not $script:Rollback) 'A usable address was rolled back.'
    }
    Test-Case 'Duplicate static address triggers rollback' {
        . $networkMocks
        $script:AddressState = 'Duplicate'
        Assert-Throws { & ([scriptblock]::Create($networkScript)) } 'already in use'
        Assert-True $script:Rollback 'DHCP was not restored after a duplicate address.'
    }
    Test-Case 'Tentative address times out and rolls back' {
        . $networkMocks
        $script:AddressState = 'Tentative'
        Assert-Throws { & ([scriptblock]::Create($networkScript)) } 'did not become usable'
        Assert-True ($script:Seconds -eq 30 -and $script:Rollback) 'Timeout did not restore DHCP.'
    }
    Test-Case 'Launcher distinguishes completion, failure, cancellation and restart' {
        $form = $formType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
        try {
            $handler = $formType.GetMethod('HandleOutputLine',$instanceFlags)
            $complete = $formType.GetMethod('ApplyInstallerOutcome',$instanceFlags)
            $activity = $formType.GetField('activityLabel',$instanceFlags).GetValue($form)
            $progress = $formType.GetField('progressBar',$instanceFlags).GetValue($form)
            $progressValue = $progress.GetType().GetProperty('Value',$instanceFlags)
            foreach ($case in @(
                @('Idle',0,'Setup closed'),
                @('Cancelled',0,'Operation cancelled'),
                @('RestartRequired',3010,'Restart required'),
                @('Failed',1,'Setup needs attention'),
                @('Running',0,'Setup needs attention'),
                @('Completed',0,'Setup finished')
            )) {
                $progressValue.SetValue($progress,25,$null)
                $eventLine = '@@KILOVIEW_EVENT@@' + (@{type='outcome';outcome=$case[0];message='Test outcome'} | ConvertTo-Json -Compress)
                [void]$handler.Invoke($form,@($eventLine))
                [void]$complete.Invoke($form,@([int]$case[1]))
                Assert-True ($activity.Text -eq $case[2]) "Incorrect launcher label for $($case[0]): $($activity.Text)"
                Assert-True (($progressValue.GetValue($progress,$null) -eq 100) -eq ($case[0] -eq 'Completed')) "Incorrect completion progress for $($case[0])."
            }
        } finally { $form.Dispose(); [Environment]::ExitCode = 0 }
    }
    Test-Case 'Packaged executable embeds the current installer and localhost shortcuts' {
        $reader = New-Object IO.StreamReader($assembly.GetManifestResourceStream('KiloLink.Setup.Install-KiloLinkSuite.ps1'))
        try { $embedded = $reader.ReadToEnd() } finally { $reader.Dispose() }
        Assert-True ($embedded -ceq [IO.File]::ReadAllText($installerPath)) 'Rebuild required: embedded installer differs from source.'
        Assert-True ($embedded.Contains('http://127.0.0.1:')) 'The local shortcut change is absent from the executable.'
        $reader = New-Object IO.StreamReader($assembly.GetManifestResourceStream('KiloLink.Setup.QuietInstaller.cs'))
        try { $quiet = $reader.ReadToEnd() } finally { $reader.Dispose() }
        Assert-True ($quiet -ceq [IO.File]::ReadAllText((Join-Path $root 'launcher\QuietInstaller.cs'))) 'The hidden vendor installer helper is stale or missing.'
    }

    Test-Case 'Watchdog exits on startup failure and checks services again after startup' {
        Assert-True (Test-Path -LiteralPath $BashPath) 'Git Bash is required; supply its executable with -BashPath.'
        $stubRoot = Join-Path $testRoot 'watchdog-stubs'
        New-Item -ItemType Directory -Path $stubRoot | Out-Null
        $utf8 = New-Object Text.UTF8Encoding($false)
        $systemctl = @'
#!/bin/sh
if [ "$MOCK_MODE" = startup ] || [ -f "$MOCK_MARKER" ]; then
    echo SERVICE_FAILURE
    exit 1
fi
echo SERVICE_OK
'@
        $docker = "#!/bin/sh`nif [ `"`$1`" = inspect ]; then echo true; fi`n"
        $sleep = "#!/bin/sh`necho KEEPALIVE_TICK`nprintf tick > `"`$MOCK_MARKER`"`n"
        foreach ($stub in @(@('systemctl',$systemctl),@('docker',$docker),@('sleep',$sleep))) {
            [IO.File]::WriteAllText((Join-Path $stubRoot $stub[0]),$stub[1].Replace("`r`n","`n"),$utf8)
        }
        $unixRoot = '/' + $stubRoot.Substring(0,1).ToLowerInvariant() + $stubRoot.Substring(2).Replace('\','/')
        foreach ($mode in @('startup','later')) {
            $probe = "export PATH='$unixRoot':/usr/bin:/bin`nexport MOCK_MODE='$mode'`nexport MOCK_MARKER='$unixRoot/$mode.marker'`n" + (Get-KiloWatchdogCommand)
            $probePath = Join-Path $stubRoot "$mode.sh"
            [IO.File]::WriteAllText($probePath,$probe,$utf8)
            $output = & $BashPath --noprofile --norc $probePath
            $code = $LASTEXITCODE
            Assert-True ($code -ne 0) 'Watchdog hid a service failure.'
            Assert-True ($output -contains 'SERVICE_FAILURE') 'The service failure was not exercised.'
            Assert-True (($output -contains 'KEEPALIVE_TICK') -eq ($mode -eq 'later')) 'Watchdog entered keepalive before startup succeeded, or failed to recheck services.'
        }
    }
} finally {
    $env:TEMP = $originalTemp
    $env:ProgramData = $originalProgramData
    [Environment]::ExitCode = 0
}
$currentLiveReceiptHash = if (Test-Path -LiteralPath $liveReceiptPath) { (Get-FileHash -LiteralPath $liveReceiptPath -Algorithm SHA256).Hash } else { $null }
Assert-True ($currentLiveReceiptHash -eq $liveReceiptHash) 'The regression suite changed the live deployment receipt.'
$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ("{0}/{1} regression checks passed. Test artifacts: {2}" -f ($results.Count - $failed.Count),$results.Count,$testRoot)
if ($failed.Count -gt 0) { exit 1 }
