#Requires -Version 5.1
<#
Run after Build-Setup.ps1. No elevation, WSL distribution, vendor installation,
live network changes, or scheduled tasks are required. Git Bash is used only
to exercise the generated watchdog against fake service commands.
#>
[CmdletBinding()]
param([string]$BashPath = "$env:ProgramFiles\Git\bin\bash.exe")

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('kilolink-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$originalTemp = $env:TEMP
$env:TEMP = $testRoot
$results = New-Object Collections.Generic.List[object]

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    $failure = $null
    try { & $Body | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -and $failure -match $Pattern) "Expected failure matching '$Pattern'; received '$failure'."
}
function New-Config {
    [pscustomobject]@{PrimaryInterfaceAlias='Ethernet';PublicIp='192.0.2.10';WebPort=80;LinkPort=50000;NdiDiscoveryPort=5959;DistroName='KiloLink-Ubuntu';LinuxDataPath='/opt/kilolink-server';KiloLinkImage='kiloview/klnk-pro:latest'}
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
    Test-Case 'Cancelled repair preserves the previous configuration' {
        $config = New-Config
        Save-Config $config
        function Read-SuiteConfig { $new = New-Config; $new.WebPort = 8080; $new }
        function Confirm-LicenseAcceptance { $false }
        Repair-Suite
        Assert-True ((Get-SavedConfig).WebPort -eq 80) 'Cancellation overwrote the applied port.'
        Assert-True ($script:OperationOutcome -eq 'Cancelled') 'Cancellation was not reported.'
    }
    Test-Case 'Repair retries settings saved before an interrupted attempt' {
        . $repairMocks
        $config = New-Config
        $config.WebPort = 8080
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

    $ndiMocks = {
        $script:NdiInstalled = $false
        $script:NdiDownloads = 0
        $script:NdiInstallCalls = 0
        function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='6.0.0'} }
        function Get-NdiDiscoveryExe { if ($script:NdiInstalled) { 'C:\Fake\NDI Discovery Service.exe' } }
        function Download-FileWithProgress { $script:NdiDownloads++ }
        function Get-InstallerSignatureWithProgress { [pscustomobject]@{Status='Valid'} }
        function Get-Item { [pscustomobject]@{VersionInfo=[pscustomobject]@{ProductVersion='6.0.0'}} }
        function Start-Process {
            $script:NdiInstallCalls++
            $script:NdiInstalled = $true
            [pscustomobject]@{HasExited=$true;ExitCode=0}
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
    Test-Case 'Same-version NDI update is skipped when files are healthy' {
        . $ndiMocks
        $script:NdiInstalled = $true
        Install-NdiTools -UpdateOnly
        Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 0) 'A current healthy package was reinstalled.'
    }

    Test-Case 'Firewall opens the complete streaming range in both firewalls' {
        $script:Rules = New-Object Collections.Generic.List[object]
        function Get-NetFirewallRule { }
        function Get-NetFirewallHyperVRule { }
        function New-NetFirewallRule {
            param($DisplayName,$Group,$Direction,$Action,$Protocol,$LocalPort)
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
        $output = & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $fixturePath -LauncherMode
        $code = $LASTEXITCODE
        Assert-True ($code -eq 1) "The real entry point returned $code after failure."
        $events = @($output | Where-Object { $_ -like '@@KILOVIEW_EVENT@@*' } | ForEach-Object { $_.Substring('@@KILOVIEW_EVENT@@'.Length) | ConvertFrom-Json })
        Assert-True (@($events | Where-Object { $_.type -eq 'outcome' -and $_.outcome -eq 'Failed' }).Count -eq 1) 'The launcher failure event was missing.'
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
    [Environment]::ExitCode = 0
}
$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ("{0}/{1} regression checks passed. Test artifacts: {2}" -f ($results.Count - $failed.Count),$results.Count,$testRoot)
if ($failed.Count -gt 0) { exit 1 }
