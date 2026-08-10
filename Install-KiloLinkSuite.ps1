#Requires -Version 5.1
# Copyright (c) 2026 John Lightfoot
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Menu-driven installer for KiloLink Server Pro, NDI Tools, and NDI Discovery Server.

.DESCRIPTION
    KiloLink runs in Docker Engine inside a dedicated Ubuntu WSL 2 distribution.
    Windows 11 mirrored networking exposes its TCP, UDP, and multicast traffic
    on physical adapters. The selected stable IPv4 address is advertised to
    KiloLink devices, while the services listen on all available interfaces.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Repair', 'Update', 'Resume')]
    [string]$Action = 'Menu',
    [switch]$AcceptLicenses,
    [switch]$AutoRestart,
    [switch]$LauncherMode,
    [string]$LogPath,
    [string]$PreferredInterfaceAlias,
    [string]$PreferredIpAddress
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:StateRoot = Join-Path $env:ProgramData 'KiloLink'
$script:ConfigPath = Join-Path $script:StateRoot 'installer-config.json'
$script:StartupScriptPath = Join-Path $script:StateRoot 'start-kilolink.ps1'
$script:StartupTaskName = 'KiloLink WSL Startup'
$script:NdiTaskName = 'NDI Discovery Server Startup'
$script:FirewallGroup = 'KiloLink Suite Installer'
$script:HyperVPrefix = 'KiloLinkSuite-'
$script:WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$script:ManagedDistroName = 'KiloLink-Ubuntu'
$script:ContainerName = 'KLNKSVR-pro'
$script:KiloImage = 'kiloview/klnk-pro:latest'
$script:LinuxDataPath = '/opt/kilolink-server'
$script:NdiToolsUrl = 'https://downloads.ndi.tv/Tools/NDI%206%20Tools.exe'
$script:KiloInstallerUrl = 'https://www.kiloview.com/downloads/klnk-pro/install.sh'
$script:InstallerLogPath = Join-Path $script:StateRoot 'installer.log'
$script:ResumeStatePath = Join-Path $script:StateRoot 'resume-state.json'
$script:ResumeTaskName = 'KiloLink Suite Installation Resume'
$script:PersistentLauncherPath = Join-Path $script:StateRoot 'Launcher\Kiloview-Environment-Setup.exe'
$script:RestartScheduled = $false
$script:MaximumResumeAttempts = 3
$script:KiloDefaultUsername = 'admin'
$script:KiloDefaultPassword = 'Kiloview001'
$script:ProgressActive = $false
$script:ProgressActivity = ''
$script:ProgressStatus = ''
$script:ProgressPercent = 0
$script:ProgressPulseIndex = 0
$script:ProgressLastPulse = [datetime]::MinValue
$script:LauncherEventPrefix = '@@KILOVIEW_EVENT@@'

function Write-LauncherEvent {
    param([string]$Type, [hashtable]$Data = @{})
    if (-not $LauncherMode) { return }
    $payload = [ordered]@{ type = $Type }
    foreach ($key in $Data.Keys) {
        $payload[$key] = $Data[$key]
    }
    [Console]::Out.WriteLine($script:LauncherEventPrefix + ($payload | ConvertTo-Json -Compress -Depth 4))
    [Console]::Out.Flush()
}

function Read-InstallerInput {
    param([string]$Prompt)
    if ($LauncherMode) {
        Write-LauncherEvent -Type 'prompt' -Data @{ prompt = $Prompt }
        return [Console]::In.ReadLine()
    }
    return Read-Host $Prompt
}

function Write-InstallerLog {
    param([string]$Message)
    if (-not (Test-Path -LiteralPath $script:StateRoot)) { return }
    # wsl.exe can emit UTF-16 text through a native pipeline. Strip embedded
    # NUL characters so diagnostics remain readable in Notepad and on screen.
    $cleanMessage = ([string]$Message -replace [char]0, '').TrimEnd()
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $cleanMessage
    Add-Content -LiteralPath $script:InstallerLogPath -Value $line -Encoding UTF8
}

function Start-SuiteProgress {
    param([string]$Activity, [string]$Status = 'Preparing')
    $script:ProgressActive = $true
    $script:ProgressActivity = $Activity
    $script:ProgressStatus = $Status
    $script:ProgressPercent = 0
    $script:ProgressPulseIndex = 0
    $script:ProgressLastPulse = [datetime]::MinValue
    Set-SuiteProgress -Percent 1 -Status $Status
}

function Set-SuiteProgress {
    param([int]$Percent, [string]$Status)
    if (-not $script:ProgressActive) { return }
    $script:ProgressPercent = [Math]::Max($script:ProgressPercent, [Math]::Min(100, $Percent))
    if ($Status) { $script:ProgressStatus = $Status }
    if (-not $LauncherMode) {
        Write-Progress -Id 1 -Activity $script:ProgressActivity -Status ("{0} ({1}%)" -f $script:ProgressStatus, $script:ProgressPercent) -PercentComplete $script:ProgressPercent
    }
    Write-LauncherEvent -Type 'progress' -Data @{
        activity = $script:ProgressActivity
        status = $script:ProgressStatus
        percent = $script:ProgressPercent
    }
    Write-InstallerLog ("PROGRESS {0}% - {1}" -f $script:ProgressPercent, $script:ProgressStatus)
}

function Update-SuiteProgressPulse {
    if (-not $script:ProgressActive) { return }
    $now = Get-Date
    if (($now - $script:ProgressLastPulse).TotalMilliseconds -lt 250) { return }
    $script:ProgressLastPulse = $now
    $frames = @('|', '/', '-', '\')
    $frame = $frames[$script:ProgressPulseIndex % $frames.Count]
    $script:ProgressPulseIndex++
    if (-not $LauncherMode) {
        Write-Progress -Id 1 -Activity $script:ProgressActivity -Status ("{0} ({1}%)" -f $script:ProgressStatus, $script:ProgressPercent) -CurrentOperation ("Working {0}" -f $frame) -PercentComplete $script:ProgressPercent
    }
    Write-LauncherEvent -Type 'pulse' -Data @{
        activity = $script:ProgressActivity
        status = $script:ProgressStatus
        percent = $script:ProgressPercent
    }
}

function Wait-SuiteProgressInterval {
    param([int]$Milliseconds = 3000)
    $deadline = (Get-Date).AddMilliseconds($Milliseconds)
    do {
        Update-SuiteProgressPulse
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
}

function Stop-SuiteProgress {
    if (-not $script:ProgressActive) { return }
    if (-not $LauncherMode) {
        Write-Progress -Id 1 -Activity $script:ProgressActivity -Completed
    }
    Write-LauncherEvent -Type 'progress' -Data @{
        activity = $script:ProgressActivity
        status = $script:ProgressStatus
        percent = $script:ProgressPercent
    }
    $script:ProgressActive = $false
}

function Write-Detail {
    param([string]$Text, [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray)
    Write-InstallerLog $Text
    Write-LauncherEvent -Type 'log' -Data @{ message = $Text }
    if (-not $script:ProgressActive) {
        Write-Host $Text -ForegroundColor $ForegroundColor
    }
}

function Write-Heading {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Text)
    if ($script:ProgressActive) {
        Set-SuiteProgress -Percent ([Math]::Min(98, $script:ProgressPercent + 1)) -Status $Text
        return
    }
    Write-Host ''
    Write-Host "-- $Text" -ForegroundColor Yellow
}

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if (Test-Administrator) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Save this script to a .ps1 file before running it.'
    }
    Write-Host 'Requesting Administrator access...' -ForegroundColor Yellow
    $elevationArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Action -ne 'Menu') { $elevationArguments += " -Action $Action" }
    if ($AcceptLicenses) { $elevationArguments += ' -AcceptLicenses' }
    if ($AutoRestart) { $elevationArguments += ' -AutoRestart' }
    if ($LauncherMode) { $elevationArguments += ' -LauncherMode' }
    if ($LogPath) { $elevationArguments += " -LogPath `"$LogPath`"" }
    Start-Process powershell.exe -ArgumentList $elevationArguments -Verb RunAs | Out-Null
    exit 0
}

function Get-SavedConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json
    } catch {
        Write-Warning "Saved configuration is unreadable: $($_.Exception.Message)"
        return $null
    }
}

function Save-Config {
    param($Config)
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    if ($null -eq $Config.PSObject.Properties['UpdatedAt']) {
        $Config | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue (Get-Date).ToString('o')
    } else {
        $Config.UpdatedAt = (Get-Date).ToString('o')
    }
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode,
        [switch]$Capture
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $recentOutput = New-Object Collections.Generic.List[string]
    try {
        # Windows PowerShell 5.1 converts native stderr into non-terminating
        # PowerShell errors. With the script-wide preference set to Stop, normal
        # progress written to stderr (for example by systemctl enable) would
        # otherwise terminate the operation even when the process exits 0.
        $ErrorActionPreference = 'Continue'
        if ($Capture -and $script:ProgressActive) {
            # Some checks need their output returned to the caller (for example,
            # docker pull/image comparison). Stream those lines into a list so
            # long-running captured commands still animate the progress display.
            $captured = New-Object Collections.Generic.List[string]
            & $FilePath @Arguments 2>&1 | ForEach-Object {
                $line = ([string]$_ -replace [char]0, '').TrimEnd()
                $captured.Add($line)
                if ($line) { $recentOutput.Add($line) }
                Write-InstallerLog $line
                Update-SuiteProgressPulse
            }
            $output = @($captured)
        } elseif ($Capture) {
            $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object {
                $line = ([string]$_ -replace [char]0, '').TrimEnd()
                if ($line) { $recentOutput.Add($line) }
                $line
            })
        } else {
            # Interactive mode sends verbose native output to the installer log
            # while keeping a frequently refreshed progress bar on screen.
            & $FilePath @Arguments 2>&1 | ForEach-Object {
                $line = ([string]$_ -replace [char]0, '').TrimEnd()
                if ($line) {
                    $recentOutput.Add($line)
                    if ($recentOutput.Count -gt 12) { $recentOutput.RemoveAt(0) }
                }
                if ($script:ProgressActive) {
                    Write-InstallerLog $line
                    Update-SuiteProgressPulse
                } else {
                    Write-Host $line
                }
            }
            $output = $null
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (-not $IgnoreExitCode -and $code -ne 0) {
        $message = 'Command failed with exit code {0}: {1} {2}' -f $code, $FilePath, ($Arguments -join ' ')
        $diagnostic = @($recentOutput | Where-Object { $_ } | Select-Object -Last 6) -join ' '
        if ($diagnostic) { $message += [Environment]::NewLine + 'Reported by command: ' + $diagnostic }
        throw $message
    }
    if ($Capture) {
        return @($output | ForEach-Object { [string]$_ })
    }
}

function Get-WslDistroNames {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return @()
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # A clean Windows installation has wsl.exe present even when the WSL
        # platform is not installed. Its expected diagnostic on stderr must not
        # terminate the installer menu while $ErrorActionPreference is Stop.
        $ErrorActionPreference = 'Continue'
        $output = & wsl.exe --list --quiet 2>$null
        $code = $LASTEXITCODE
    } catch {
        Write-InstallerLog "WSL distribution probe is not available: $($_.Exception.Message)"
        return @()
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0) {
        return @()
    }
    return @($output | ForEach-Object { ([string]$_ -replace [char]0, '').Trim() } | Where-Object { $_ })
}

function Test-WslRuntime {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & wsl.exe --status 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Wait-WslRuntime {
    param([int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-WslRuntime) {
            return $true
        }
        Wait-SuiteProgressInterval
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-ResumeState {
    if (-not (Test-Path -LiteralPath $script:ResumeStatePath)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $script:ResumeStatePath | ConvertFrom-Json
    } catch {
        Write-InstallerLog "Resume state could not be read: $($_.Exception.Message)"
        return $null
    }
}

function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $script:ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Clear-ResumeContinuation {
    Remove-ResumeTask
    Remove-Item -LiteralPath $script:ResumeStatePath -Force -ErrorAction SilentlyContinue
}

function Register-ResumeContinuation {
    param([string]$Reason)
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $oldState = Get-ResumeState
    $attempt = if ($oldState) { [int](Get-PropertyValue $oldState 'Attempt' 0) + 1 } else { 1 }
    if ($attempt -gt $script:MaximumResumeAttempts) {
        throw "Windows prerequisites still require a restart after $($script:MaximumResumeAttempts) attempts. Check virtualization and Windows Update before retrying."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (Test-Path -LiteralPath $script:PersistentLauncherPath) {
        $taskAction = New-ScheduledTaskAction -Execute $script:PersistentLauncherPath -Argument '--resume'
    } else {
        if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
            throw 'Setup cannot create a restart continuation because neither the persistent launcher nor a script path is available.'
        }
        $resumeScript = Join-Path $script:StateRoot 'Launcher\Install-KiloLinkSuite.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $resumeScript) -Force | Out-Null
        if (-not [string]::Equals([IO.Path]::GetFullPath($PSCommandPath), [IO.Path]::GetFullPath($resumeScript), [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $resumeScript -Force
        }
        $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`" -Action Resume -AcceptLicenses -LauncherMode -LogPath `"$(Join-Path $script:StateRoot 'setup-launcher.log')`""
        $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
    if ($null -ne $trigger.PSObject.Properties['Delay']) {
        $trigger.Delay = 'PT20S'
    }
    $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:ResumeTaskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    $registeredTask = Get-ScheduledTask -TaskName $script:ResumeTaskName -ErrorAction SilentlyContinue
    if (-not $registeredTask) {
        throw 'Windows did not retain the scheduled continuation task, so Setup will not restart the computer.'
    }

    [pscustomobject]@{
        SchemaVersion = 1
        Attempt = $attempt
        Reason = $Reason
        RegisteredAt = (Get-Date).ToString('o')
        User = $identity
    } | ConvertTo-Json | Set-Content -LiteralPath $script:ResumeStatePath -Encoding UTF8
    Write-InstallerLog "Registered restart continuation attempt $attempt for $identity. Reason: $Reason"
}

function Request-RestartAndResume {
    param([string]$Reason)
    Register-ResumeContinuation -Reason $Reason
    $script:RestartScheduled = $true
    if ($script:ProgressActive) {
        Stop-SuiteProgress
    }
    Write-Host ''
    Write-Heading 'Windows restart required'
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host 'Setup will resume automatically about 20 seconds after you sign back in.' -ForegroundColor Green

    $restartNow = $Action -eq 'Resume' -or $AutoRestart
    if ($Action -eq 'Menu') {
        $answer = Read-InstallerInput 'Restart Windows now? [Y/n]'
        $restartNow = [string]::IsNullOrWhiteSpace($answer) -or $answer -match '^(?i)y(?:es)?$'
    }
    if ($restartNow) {
        Write-Host 'Windows will restart in 20 seconds. Save any other open work now.' -ForegroundColor Yellow
        Invoke-Native shutdown.exe @('/r', '/t', '20', '/c', 'Kiloview Environment Setup is continuing after restart.')
    } else {
        Write-Host 'Restart Windows manually when ready; Setup will continue after the next sign-in.' -ForegroundColor Yellow
    }
}

function Get-UbuntuDistro {
    param([string]$Preferred)
    $distros = @(Get-WslDistroNames)
    if ($Preferred -and $distros -contains $Preferred) {
        return $Preferred
    }
    if ($distros -contains $script:ManagedDistroName) {
        return $script:ManagedDistroName
    }
    return $null
}

function Wait-WslDistroRegistration {
    param([string]$Distro, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Get-WslDistroNames) -contains $Distro) {
            return $true
        }
        Wait-SuiteProgressInterval
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Test-WslDistroReady {
    param([string]$Distro)
    if (-not $Distro -or -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & wsl.exe -d $Distro -u root --cd / -- true 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-WslDistroLaunchProbe {
    param([string]$Distro)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& wsl.exe -d $Distro -u root --cd / -- true 2>&1 | ForEach-Object {
            ([string]$_ -replace [char]0, '').Trim()
        } | Where-Object { $_ })
        $code = $LASTEXITCODE
    } catch {
        $output = @($_.Exception.Message)
        $code = -1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in $output) { Write-InstallerLog "WSL launch probe: $line" }
    return [pscustomobject]@{
        Success = $code -eq 0
        ExitCode = $code
        Output = @($output)
    }
}

function Get-WslDistroVersion {
    param([string]$Distro)
    $lines = @(Invoke-Native wsl.exe @('--list', '--verbose') -IgnoreExitCode -Capture)
    $escapedName = [regex]::Escape($Distro)
    foreach ($line in $lines) {
        $clean = ([string]$line -replace [char]0, '').TrimEnd()
        if ($clean -match ("^\s*\*?\s*{0}\s+\S+\s+([12])\s*$" -f $escapedName)) {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Get-WslLaunchFailureMessage {
    param([string]$Distro, [string[]]$Output)
    $diagnostic = @($Output | Where-Object { $_ }) -join ' '
    if ($diagnostic -match 'WSL_E_VM_MODE_INVALID_STATE|HCS_E_HYPERV_NOT_INSTALLED|virtual machine platform|virtualization') {
        return @"
Windows cannot start the WSL 2 virtual machine for '$Distro'. WSL reported: $diagnostic

This guest does not currently have usable virtualization extensions. If Windows is itself running in a VM, enable nested virtualization on the VM host, fully power the VM off and on, then rerun Setup and choose Repair / reconfigure. On a Hyper-V host run: Set-VMProcessor -VMName '<VM name>' -ExposeVirtualizationExtensions `$true
"@.Trim()
    }
    if ($diagnostic) {
        return "The WSL distribution '$Distro' registered but could not start. WSL reported: $diagnostic"
    }
    return "The WSL distribution '$Distro' registered but could not start (exit code unavailable). Check $script:InstallerLogPath."
}

function Wait-WslDistroReady {
    param([string]$Distro, [int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-WslDistroReady $Distro) {
            return $true
        }
        Wait-SuiteProgressInterval
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Invoke-Wsl {
    param(
        [string]$Distro,
        [string]$Command,
        [switch]$IgnoreExitCode,
        [switch]$Capture
    )
    $arguments = @('-d', $Distro, '-u', 'root', '--cd', '/', '--', 'bash', '-lc', $Command)
    return Invoke-Native wsl.exe $arguments -IgnoreExitCode:$IgnoreExitCode -Capture:$Capture
}

function Invoke-WslScript {
    param(
        [string]$Distro,
        [string]$Content,
        [switch]$Capture
    )
    # PowerShell here-strings use Windows CRLF endings. Bash treats the trailing
    # carriage return as part of tokens such as "pipefail", so normalize every
    # generated Linux script before it crosses the WSL boundary.
    $normalizedContent = ([string]$Content).Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object Text.UTF8Encoding($false)
    $base64 = [Convert]::ToBase64String($utf8.GetBytes($normalizedContent))
    $command = "printf '%s' '$base64' | base64 -d > /tmp/kilolink-suite.sh && chmod 700 /tmp/kilolink-suite.sh && bash /tmp/kilolink-suite.sh"
    return Invoke-Wsl $Distro $command -Capture:$Capture
}

function Test-KiloContainer {
    param([string]$Distro)
    if (-not $Distro) {
        return $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Some nested hypervisors emit a non-fatal WSL warning on stderr even
        # when the command succeeds. Health detection must follow the native
        # exit code rather than promoting that warning to a terminating error.
        $ErrorActionPreference = 'Continue'
        & wsl.exe -d $Distro -u root --cd / -- bash -lc "docker inspect '$script:ContainerName' >/dev/null 2>&1" 2>$null
        $code = $LASTEXITCODE
        return $code -eq 0
    } catch {
        Write-InstallerLog "KiloLink container probe failed: $($_.Exception.Message)"
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Get-NdiRegistration {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    }
    return @($items | Where-Object {
        $name = [string](Get-PropertyValue $_ 'DisplayName' '')
        $publisher = [string](Get-PropertyValue $_ 'Publisher' '')
        $name -match '^NDI\s+\d+\s+Tools' -or ($name -match 'NDI.*Tools' -and $publisher -match 'NDI|Vizrt|NewTek')
    } | Select-Object -First 1)[0]
}

function Get-NdiDiscoveryExe {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'NDI\NDI 6 Tools\Discovery\NDI Discovery Service.exe'),
        (Join-Path $env:ProgramFiles 'NDI\NDI 6 Tools\Discovery Service\NDI Discovery Service.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    $root = Join-Path $env:ProgramFiles 'NDI'
    if (Test-Path -LiteralPath $root) {
        $found = Get-ChildItem -LiteralPath $root -Filter 'NDI Discovery Service.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }
    return $null
}

function Get-NdiDiscoveryService {
    return @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'NDI.*Discovery' -or $_.DisplayName -match 'NDI.*Discovery'
    } | Select-Object -First 1)[0]
}

function Get-InstallState {
    $config = Get-SavedConfig
    $preferred = if ($config) { [string](Get-PropertyValue $config 'DistroName' '') } else { '' }
    $distro = Get-UbuntuDistro $preferred
    $container = if ($distro) { Test-KiloContainer $distro } else { $false }
    $ndi = Get-NdiRegistration
    $startup = Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
    $ndiTask = Get-ScheduledTask -TaskName $script:NdiTaskName -ErrorAction SilentlyContinue
    $ndiService = Get-NdiDiscoveryService
    return [pscustomobject]@{
        Any = [bool]($config -or $container -or $ndi -or $startup -or $ndiTask -or $ndiService)
        Config = $config
        Distro = $distro
        KiloLink = $container
        NDITools = [bool]$ndi
        NDIServer = [bool]($ndiTask -or $ndiService)
    }
}

function Get-LanCandidates {
    $list = New-Object Collections.Generic.List[object]
    $configurations = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address
    })
    foreach ($item in $configurations) {
        $alias = [string]$item.InterfaceAlias
        $description = [string]$item.InterfaceDescription
        if ($alias -match 'vEthernet|WSL|Loopback|Docker|Hyper-V|Default Switch' -or
            $description -match 'Virtual|Hyper-V|Docker|WSL|Loopback|VPN|TAP|Tunnel') {
            continue
        }
        foreach ($address in @($item.IPv4Address)) {
            if ($address.IPAddress -like '127.*' -or $address.IPAddress -like '169.254.*') {
                continue
            }
            $isWired = $alias -match 'Ethernet|Local Area|LAN' -or $description -match 'Ethernet|Gigabit|2.5Gb|10Gb'
            $isDhcp = $address.PrefixOrigin -eq 'Dhcp'
            $hasGateway = [bool]$item.IPv4DefaultGateway
            $score = 0
            if ($isWired) { $score += 100 }
            if ($isDhcp) { $score += 20 }
            if ($hasGateway) { $score += 10 }
            $list.Add([pscustomobject]@{
                Alias = $alias
                Description = $description
                Address = [string]$address.IPAddress
                Dhcp = $isDhcp
                Wired = $isWired
                Score = $score
            })
        }
    }
    $sort = @(
        @{ Expression = 'Score'; Descending = $true },
        @{ Expression = 'Alias'; Descending = $false }
    )
    return @($list | Sort-Object -Property $sort)
}

function Select-PrimaryLanAddress {
    param(
        $Saved,
        [string]$PreferredAlias,
        [string]$PreferredAddress
    )
    $candidates = @(Get-LanCandidates)
    if ($candidates.Count -eq 0) {
        throw 'No physical Ethernet or Wi-Fi IPv4 address was detected. Connect the PC to the network and retry.'
    }
    $savedAlias = if ($Saved) { [string](Get-PropertyValue $Saved 'PrimaryInterfaceAlias' '') } else { '' }
    $defaultIndex = 0
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $preferredAliasMatches = $PreferredAlias -and
            $candidates[$i].Alias -eq $PreferredAlias
        $preferredAddressMatches = -not $PreferredAddress -or
            $candidates[$i].Address -eq $PreferredAddress
        if ($preferredAliasMatches -and $preferredAddressMatches) {
            Write-Host "Using the adapter selected in the launcher: $($candidates[$i].Alias) / $($candidates[$i].Address)" -ForegroundColor Cyan
            return $candidates[$i]
        }
        if ($savedAlias -and $candidates[$i].Alias -eq $savedAlias) {
            $defaultIndex = $i
        }
    }
    Write-Host ''
    Write-Host 'Physical network addresses (internal Docker/WSL adapters are excluded):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $type = if ($candidates[$i].Wired) { 'wired' } else { 'wireless' }
        $origin = if ($candidates[$i].Dhcp) { 'DHCP' } else { 'static/manual' }
        Write-Host ("  {0}. {1} - {2} ({3}, {4})" -f ($i + 1), $candidates[$i].Alias, $candidates[$i].Address, $type, $origin)
    }
    while ($true) {
        $answer = Read-InstallerInput "Primary advertised adapter [$($defaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $candidates[$defaultIndex]
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
            return $candidates[$number - 1]
        }
        Write-Host 'Choose one of the listed adapter numbers.' -ForegroundColor Red
    }
}

function Read-Port {
    param([string]$Prompt, [int]$Default, [switch]$EvenPair)
    while ($true) {
        $answer = Read-InstallerInput "$Prompt [$Default]"
        $number = $Default
        if ($answer -and -not [int]::TryParse($answer, [ref]$number)) {
            Write-Host 'Enter a numeric port.' -ForegroundColor Red
            continue
        }
        $maximum = if ($EvenPair) { 65534 } else { 65535 }
        if ($number -lt 1 -or $number -gt $maximum) {
            Write-Host "Enter a port between 1 and $maximum." -ForegroundColor Red
            continue
        }
        if ($EvenPair -and $number % 2 -ne 0) {
            Write-Host 'The KiloLink link port must be even because it uses this port and the next one.' -ForegroundColor Red
            continue
        }
        return $number
    }
}

function Get-LegacyKiloConfig {
    param([string]$Distro)
    if (-not $Distro -or -not (Test-KiloContainer $Distro)) {
        return $null
    }
    try {
        $lines = Invoke-Wsl $Distro "docker inspect '$script:ContainerName'" -Capture
        $inspection = ($lines -join [Environment]::NewLine) | ConvertFrom-Json
        $container = @($inspection)[0]
        $environment = @{}
        foreach ($entry in @($container.Config.Env)) {
            if ($entry -match '^([^=]+)=(.*)$') {
                $environment[$matches[1]] = $matches[2]
            }
        }
        $mount = @($container.Mounts | Where-Object { $_.Destination -eq '/data' } | Select-Object -First 1)[0]
        return [pscustomobject]@{
            PublicIp = if ($environment.ContainsKey('stream_server_ip')) { $environment.stream_server_ip } else { $null }
            WebPort = if ($environment.ContainsKey('web_port')) { $environment.web_port } else { $null }
            LinkPort = if ($environment.ContainsKey('server_port')) { $environment.server_port } else { $null }
            LinuxDataPath = if ($mount) { [string]$mount.Source } else { $script:LinuxDataPath }
            KiloLinkImage = if ($container.Config.Image) { [string]$container.Config.Image } else { $script:KiloImage }
        }
    } catch {
        Write-Warning "Could not import the existing KiloLink container settings: $($_.Exception.Message)"
        return $null
    }
}

function Read-SuiteConfig {
    param([switch]$UseSaved)
    $saved = if ($UseSaved) { Get-SavedConfig } else { $null }
    $savedDistro = if ($saved) { [string](Get-PropertyValue $saved 'DistroName' '') } else { '' }
    $savedDistroHasKiloLink = $savedDistro -and
        ((Get-WslDistroNames) -contains $savedDistro) -and
        (Test-KiloContainer $savedDistro)
    $preferredDistro = if ($savedDistroHasKiloLink) { $savedDistro } else { $script:ManagedDistroName }
    if ($savedDistro -and $savedDistro -ne $preferredDistro) {
        Write-Host "Using dedicated WSL distribution '$($script:ManagedDistroName)'; '$savedDistro' will not be modified." -ForegroundColor Yellow
    }
    $distro = Get-UbuntuDistro $preferredDistro
    if (-not $distro) { $distro = $preferredDistro }
    $legacy = if (-not $saved -and (Get-WslDistroNames) -contains $distro) { Get-LegacyKiloConfig $distro } else { $null }
    $adapter = Select-PrimaryLanAddress `
        -Saved $saved `
        -PreferredAlias $PreferredInterfaceAlias `
        -PreferredAddress $PreferredIpAddress
    $webDefault = if ($saved) { [int](Get-PropertyValue $saved 'WebPort' 80) } elseif ($legacy -and $legacy.WebPort) { [int]$legacy.WebPort } else { 80 }
    $linkDefault = if ($saved) { [int](Get-PropertyValue $saved 'LinkPort' 50000) } elseif ($legacy -and $legacy.LinkPort) { [int]$legacy.LinkPort } else { 50000 }
    $ndiDefault = if ($saved) { [int](Get-PropertyValue $saved 'NdiDiscoveryPort' 5959) } else { 5959 }
    if ($adapter.Dhcp) {
        Write-Host 'Warning: this server is using DHCP. Configure a DHCP reservation or rerun the launcher to set a static address.' -ForegroundColor Yellow
    } else {
        Write-Host 'Using a stable static/manual IPv4 address for this server.' -ForegroundColor Green
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        PrimaryInterfaceAlias = $adapter.Alias
        PublicIp = $adapter.Address
        WebPort = Read-Port 'KiloLink web port' $webDefault
        LinkPort = Read-Port 'KiloLink link port' $linkDefault -EvenPair
        NdiDiscoveryPort = Read-Port 'NDI Discovery Server port' $ndiDefault
        DistroName = $distro
        LinuxDataPath = if ($saved) { [string](Get-PropertyValue $saved 'LinuxDataPath' $script:LinuxDataPath) } elseif ($legacy) { [string]$legacy.LinuxDataPath } else { $script:LinuxDataPath }
        KiloLinkImage = if ($saved) { [string](Get-PropertyValue $saved 'KiloLinkImage' $script:KiloImage) } elseif ($legacy) { [string]$legacy.KiloLinkImage } else { $script:KiloImage }
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function Confirm-LicenseAcceptance {
    Write-Host ''
    Write-Host 'This downloads Kiloview and NDI software and performs unattended installation.' -ForegroundColor Yellow
    Write-Host "Kiloview's current licence is published in its official installer: $($script:KiloInstallerUrl)" -ForegroundColor Yellow
    Write-Host 'You must accept the vendors license agreements to continue.' -ForegroundColor Yellow
    return (Read-InstallerInput 'Type YES to accept and continue') -ieq 'YES'
}

function Test-SupportedWindows {
    $current = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$current.CurrentBuildNumber
    if ($build -lt 22621) {
        throw 'Windows 11 22H2 (build 22621) or later is required for mirrored WSL networking.'
    }
}

function Ensure-WslFeatures {
    Test-SupportedWindows
    Write-Step 'Checking WSL prerequisites'
    $restart = $false
    foreach ($name in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
        if ($feature.State -eq 'EnablePending') {
            $restart = $true
            continue
        }
        if ($feature.State -ne 'Enabled') {
            Write-Detail "Enabling $name"
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
            if ($result.RestartNeeded) { $restart = $true }
            $verified = Get-WindowsOptionalFeature -Online -FeatureName $name
            if ($verified.State -notin @('Enabled', 'EnablePending')) {
                throw "Windows feature $name did not enter an enabled state. Current state: $($verified.State)."
            }
            if ($verified.State -eq 'EnablePending') { $restart = $true }
        }
    }
    if ($restart) {
        Request-RestartAndResume 'Windows must finish enabling WSL and Virtual Machine Platform before Linux can start.'
        return $false
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Request-RestartAndResume 'Windows enabled the required features but wsl.exe is not available until the next restart.'
        return $false
    }
    if (-not (Test-WslRuntime)) {
        Write-Step 'Installing the Windows Subsystem for Linux runtime'
        Invoke-Native wsl.exe @('--install', '--no-distribution') -IgnoreExitCode
        Set-SuiteProgress -Percent ([Math]::Min(14, $script:ProgressPercent + 2)) -Status 'Waiting for the WSL runtime to become ready'
        if (-not (Wait-WslRuntime -TimeoutSeconds 120)) {
            Request-RestartAndResume 'The WSL runtime was installed but has not become ready in the current Windows session.'
            return $false
        }
    }
    Write-Step 'Updating and verifying the Windows Subsystem for Linux runtime'
    Invoke-Native wsl.exe @('--update') -IgnoreExitCode
    if (-not (Wait-WslRuntime -TimeoutSeconds 180)) {
        Request-RestartAndResume 'WSL did not report a healthy runtime after installation and update.'
        return $false
    }
    Invoke-Native wsl.exe @('--set-default-version', '2')
    if (-not (Test-WslRuntime)) {
        throw 'WSL stopped responding after its default version was set. Check virtualization support and the diagnostic log.'
    }
    Write-Detail 'WSL runtime and required Windows features are ready.' Green
    return $true
}

function Set-IniKey {
    param(
        [Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )
    $sectionIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^\s*\[{0}\]\s*$' -f [regex]::Escape($Section))) {
            $sectionIndex = $i
            break
        }
    }
    if ($sectionIndex -lt 0) {
        if ($Lines.Count -gt 0) { $Lines.Add('') }
        $Lines.Add("[$Section]")
        $Lines.Add("$Key=$Value")
        return $true
    }
    $nextSection = $Lines.Count
    for ($i = $sectionIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[.+\]\s*$') {
            $nextSection = $i
            break
        }
    }
    for ($i = $sectionIndex + 1; $i -lt $nextSection; $i++) {
        if ($Lines[$i] -match ('^\s*{0}\s*=' -f [regex]::Escape($Key))) {
            $newValue = "$Key=$Value"
            if ($Lines[$i] -ne $newValue) {
                $Lines[$i] = $newValue
                return $true
            }
            return $false
        }
    }
    $Lines.Insert($nextSection, "$Key=$Value")
    return $true
}

function Ensure-MirroredNetworking {
    Write-Step 'Configuring mirrored WSL networking on all physical adapters'
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path) { $lines.Add([string]$line) }
    }
    $changed = $false
    $changed = (Set-IniKey $lines 'wsl2' 'networkingMode' 'mirrored') -or $changed
    $changed = (Set-IniKey $lines 'wsl2' 'dnsTunneling' 'true') -or $changed
    $changed = (Set-IniKey $lines 'wsl2' 'firewall' 'true') -or $changed
    $changed = (Set-IniKey $lines 'experimental' 'hostAddressLoopback' 'true') -or $changed
    if ($changed) {
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($path, $lines.ToArray(), $utf8)
        Invoke-Native wsl.exe @('--shutdown') -IgnoreExitCode
    }
}

function Ensure-Ubuntu {
    param($Config)
    $distro = Get-UbuntuDistro ([string]$Config.DistroName)
    if (-not $distro) {
        Write-Step "Installing dedicated Ubuntu WSL 2 distribution '$($script:ManagedDistroName)'"
        Invoke-Native wsl.exe @('--install', 'Ubuntu', '--name', $script:ManagedDistroName, '--version', '2', '--no-launch')
        Set-SuiteProgress -Percent ([Math]::Min(27, $script:ProgressPercent + 2)) -Status 'Waiting for the dedicated Ubuntu distribution to register'
        if (-not (Wait-WslDistroRegistration -Distro $script:ManagedDistroName -TimeoutSeconds 180)) {
            Request-RestartAndResume "The $($script:ManagedDistroName) distribution was installed but has not registered in the current Windows session."
            return $null
        }
        $distro = $script:ManagedDistroName
    }
    $Config.DistroName = $distro
    Save-Config $Config
    Write-Step "Verifying $distro as a working WSL 2 distribution"
    $probe = Get-WslDistroLaunchProbe $distro
    if (-not $probe.Success) {
        $message = Get-WslLaunchFailureMessage -Distro $distro -Output $probe.Output
        if ($message -match 'nested virtualization') { throw $message }
        Set-SuiteProgress -Percent ([Math]::Min(28, $script:ProgressPercent + 1)) -Status "Waiting for $distro to finish its first launch"
        if (-not (Wait-WslDistroReady -Distro $distro -TimeoutSeconds 180)) {
            $probe = Get-WslDistroLaunchProbe $distro
            throw (Get-WslLaunchFailureMessage -Distro $distro -Output $probe.Output)
        }
    }
    $version = Get-WslDistroVersion $distro
    if ($version -ne 2) {
        Write-Step "Converting $distro to WSL 2"
        Invoke-Native wsl.exe @('--set-version', $distro, '2')
    }
    if (-not (Wait-WslDistroReady -Distro $distro -TimeoutSeconds 60)) {
        $probe = Get-WslDistroLaunchProbe $distro
        throw (Get-WslLaunchFailureMessage -Distro $distro -Output $probe.Output)
    }
    return $distro
}

function Ensure-Docker {
    param([string]$Distro)
    Write-Step "Installing systemd, Docker Engine, and Avahi in $Distro"

    Set-SuiteProgress -Percent ([Math]::Min(40, $script:ProgressPercent + 2)) -Status 'Enabling systemd in the dedicated WSL distribution'
    $enableSystemd = @'
set -euo pipefail
touch /etc/wsl.conf
awk '
BEGIN { in_boot=0; saw_boot=0; wrote_systemd=0 }
function finish_boot() {
    if (in_boot && !wrote_systemd) {
        print "systemd=true"
        wrote_systemd=1
    }
}
/^[[:space:]]*\[boot\][[:space:]]*$/ {
    finish_boot()
    in_boot=1
    saw_boot=1
    wrote_systemd=0
    print
    next
}
/^[[:space:]]*\[.*\][[:space:]]*$/ {
    finish_boot()
    in_boot=0
    print
    next
}
in_boot && /^[[:space:]]*systemd[[:space:]]*=/ {
    if (!wrote_systemd) {
        print "systemd=true"
        wrote_systemd=1
    }
    next
}
{ print }
END {
    finish_boot()
    if (!saw_boot) {
        print ""
        print "[boot]"
        print "systemd=true"
    }
}
' /etc/wsl.conf > /etc/wsl.conf.kilolink
mv /etc/wsl.conf.kilolink /etc/wsl.conf
'@
    Invoke-WslScript $Distro $enableSystemd
    Set-SuiteProgress -Percent ([Math]::Min(42, $script:ProgressPercent + 2)) -Status 'Restarting WSL with systemd enabled'
    Invoke-Native wsl.exe @('--shutdown') -IgnoreExitCode
    if (-not (Wait-WslDistroReady -Distro $Distro -TimeoutSeconds 120)) {
        throw "$Distro did not restart with systemd within 120 seconds."
    }

    Set-SuiteProgress -Percent ([Math]::Min(44, $script:ProgressPercent + 2)) -Status 'Installing Linux networking and service prerequisites'
    $installDocker = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg avahi-daemon dbus iproute2 libnss-mdns

# WSL appends the Windows PATH by default. Docker Desktop can therefore make
# `command -v docker` resolve to a Windows interop shim under /mnt/c even when
# this dedicated distro has no Linux Docker Engine or docker.service.
if [ ! -x /usr/bin/docker ] || ! dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" >/dev/null 2>&1 || true
    done
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if [ "$(ps -p 1 -o comm= | tr -d ' ')" != "systemd" ]; then
    echo "systemd is not PID 1" >&2
    exit 20
fi
systemctl enable --now docker
systemctl enable --now avahi-daemon
docker version >/dev/null
'@
    Invoke-WslScript $Distro $installDocker
}

function Install-KiloLink {
    param($Config)
    if (Test-KiloContainer $Config.DistroName) {
        Write-Detail 'KiloLink Server Pro is already installed.' Green
        Invoke-Wsl $Config.DistroName "docker update --restart always '$script:ContainerName' >/dev/null; docker start '$script:ContainerName' >/dev/null || true"
        return
    }

    Write-Step 'Installing KiloLink Server Pro'
    # Deploy the official image with the same container settings published by
    # Kiloview's installer. This avoids automating a variable interactive prompt
    # sequence while retaining the user's explicit licence acceptance above.
    Recreate-KiloContainer $Config -Pull
    Write-Detail 'KiloLink Server Pro installed.' Green
}

function Recreate-KiloContainer {
    param($Config, [switch]$Pull)
    Set-SuiteProgress -Percent ([Math]::Min(88, $script:ProgressPercent + 2)) -Status $(if ($Pull) { 'Downloading the KiloLink Server Pro image' } else { 'Preparing the KiloLink Server Pro image' })
    $pullCommand = if ($Pull) { 'docker pull "__IMAGE__"' } else { 'docker image inspect "__IMAGE__" >/dev/null' }
    $template = @'
set -euo pipefail
__PULL_COMMAND__
docker rm -f "__CONTAINER__" >/dev/null 2>&1 || true
mkdir -p "__DATA_PATH__"
docker run -d --name "__CONTAINER__" --ulimit nofile=10000:10000 -e "web_port=__WEB__" -e "server_port=__LINK__" -e "stream_server_ip=__IP__" -e "stream_server_port=__LINK_PLUS_ONE__" -v /var/run/avahi-daemon:/var/run/avahi-daemon -v /var/run/dbus:/var/run/dbus -v "__DATA_PATH__":/data --restart=always --network host --privileged=true "__IMAGE__" /bin/bash /start_server.sh
docker inspect "__CONTAINER__" >/dev/null
'@
    $content = $template.Replace('__PULL_COMMAND__', $pullCommand)
    $content = $content.Replace('__CONTAINER__', $script:ContainerName)
    $content = $content.Replace('__DATA_PATH__', [string]$Config.LinuxDataPath)
    $content = $content.Replace('__WEB__', [string]$Config.WebPort)
    $content = $content.Replace('__LINK_PLUS_ONE__', [string]([int]$Config.LinkPort + 1))
    $content = $content.Replace('__LINK__', [string]$Config.LinkPort)
    $content = $content.Replace('__IP__', [string]$Config.PublicIp)
    $content = $content.Replace('__IMAGE__', [string]$Config.KiloLinkImage)
    Set-SuiteProgress -Percent ([Math]::Min(90, $script:ProgressPercent + 2)) -Status 'Creating the KiloLink Server Pro container'
    Invoke-WslScript $Config.DistroName $content
}

function Sync-KiloConfig {
    param($Old, $New)
    if (-not (Test-KiloContainer $New.DistroName)) {
        Install-KiloLink $New
        return
    }
    $changed =
        ([string](Get-PropertyValue $Old 'PublicIp' '') -ne [string]$New.PublicIp) -or
        ([int](Get-PropertyValue $Old 'WebPort' 0) -ne [int]$New.WebPort) -or
        ([int](Get-PropertyValue $Old 'LinkPort' 0) -ne [int]$New.LinkPort)
    if ($changed) {
        Write-Step 'Applying the changed KiloLink network configuration'
        Recreate-KiloContainer $New
    } else {
        Invoke-Wsl $New.DistroName "docker update --restart always '$script:ContainerName' >/dev/null; docker start '$script:ContainerName' >/dev/null || true"
    }
}

function Convert-ToVersion {
    param([string]$Value)
    if (-not $Value) { return $null }
    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')
    if (-not $match.Success) { return $null }
    try { return [version]$match.Value } catch { return $null }
}

function Download-FileWithProgress {
    param(
        [string]$Uri,
        [string]$Destination,
        [int]$BasePercent,
        [int]$PercentSpan,
        [string]$Status
    )
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if (-not $script:ProgressActive -or -not (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
        return
    }

    $job = $null
    try {
        $job = Start-BitsTransfer -Source $Uri -Destination $Destination -DisplayName 'KiloLink Suite package download' -Asynchronous
        if (-not $job.JobId) {
            throw 'BITS did not return a job identifier.'
        }
        while ($true) {
            $job = Get-BitsTransfer -JobId $job.JobId
            if ($job.JobState -eq 'Transferred') { break }
            if ($job.JobState -in @('Error', 'TransientError', 'Cancelled')) {
                throw "BITS download entered state $($job.JobState): $($job.ErrorDescription)"
            }
            # BITS reports UInt64.MaxValue until the server supplies the content length.
            # Treat that sentinel as unknown so the UI never displays an absurd total.
            if ($job.BytesTotal -gt 0 -and [uint64]$job.BytesTotal -ne [uint64]::MaxValue) {
                $fraction = [Math]::Min(1, [double]$job.BytesTransferred / [double]$job.BytesTotal)
                $percent = $BasePercent + [int]([Math]::Floor($fraction * $PercentSpan))
                $downloaded = [Math]::Round($job.BytesTransferred / 1MB, 1)
                $total = [Math]::Round($job.BytesTotal / 1MB, 1)
                Set-SuiteProgress -Percent $percent -Status ("{0}: {1} MB / {2} MB" -f $Status, $downloaded, $total)
            } else {
                Update-SuiteProgressPulse
            }
            Start-Sleep -Milliseconds 300
        }
        Complete-BitsTransfer -BitsJob $job
    } catch {
        if ($job) {
            Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-InstallerLog "BITS download failed; falling back to Invoke-WebRequest: $($_.Exception.Message)"
        Set-SuiteProgress -Percent $BasePercent -Status "$Status (fallback download)"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
    }
}

function Get-InstallerSignatureWithProgress {
    param([string]$Path)
    if (-not $script:ProgressActive) {
        return Get-AuthenticodeSignature -LiteralPath $Path
    }
    $job = Start-Job -ScriptBlock {
        param($InstallerPath)
        Get-AuthenticodeSignature -LiteralPath $InstallerPath
    } -ArgumentList $Path
    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            Update-SuiteProgressPulse
            Start-Sleep -Milliseconds 300
            $job = Get-Job -Id $job.Id
        }
        if ($job.State -ne 'Completed') {
            $reason = [string]$job.ChildJobs[0].JobStateInfo.Reason
            throw "Signature verification failed to complete: $reason"
        }
        return Receive-Job -Job $job
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Install-NdiTools {
    param([switch]$UpdateOnly)
    $registration = Get-NdiRegistration
    if ($UpdateOnly -and -not $registration) {
        Write-Detail 'NDI Tools is missing. Choose Repair / Reconfigure to install it.' Yellow
        return
    }
    if ($registration -and -not $UpdateOnly) {
        $installedVersion = Convert-ToVersion ([string](Get-PropertyValue $registration 'DisplayVersion' ''))
        Write-Detail "NDI Tools $installedVersion is already installed." Green
        return
    }

    Write-Step 'Checking the current NDI Tools package'
    $downloadDir = Join-Path $env:TEMP 'KiloLinkSuite'
    $installer = Join-Path $downloadDir 'NDI-Tools.exe'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    Download-FileWithProgress -Uri $script:NdiToolsUrl -Destination $installer -BasePercent $script:ProgressPercent -PercentSpan 8 -Status 'Downloading NDI Tools'

    Set-SuiteProgress -Percent ([Math]::Min(90, $script:ProgressPercent + 1)) -Status 'Verifying the NDI Tools signature'
    $signature = Get-InstallerSignatureWithProgress -Path $installer
    if ([string]$signature.Status -ne 'Valid') {
        throw "NDI installer signature validation failed: $($signature.Status)"
    }
    $installedVersion = if ($registration) { Convert-ToVersion ([string](Get-PropertyValue $registration 'DisplayVersion' '')) } else { $null }
    $packageVersion = Convert-ToVersion ((Get-Item -LiteralPath $installer).VersionInfo.ProductVersion)
    $install = -not $registration -or -not $installedVersion -or -not $packageVersion -or $packageVersion -gt $installedVersion
    if (-not $install) {
        Write-Detail "NDI Tools $installedVersion is current." Green
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Set-SuiteProgress -Percent ([Math]::Min(92, $script:ProgressPercent + 2)) -Status 'Installing NDI Tools'
    $process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') -PassThru
    while (-not $process.HasExited) {
        Update-SuiteProgressPulse
        Start-Sleep -Milliseconds 300
        $process.Refresh()
    }
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "NDI Tools installer failed with exit code $($process.ExitCode)."
    }
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if (-not (Get-NdiRegistration)) {
        throw 'NDI Tools finished installing but was not detected in Programs and Features.'
    }
    Write-Detail 'NDI Tools installed or updated.' Green
}

function Configure-NdiServer {
    param($Config)
    Write-Step 'Configuring NDI Discovery Server on all physical adapters'
    $exe = Get-NdiDiscoveryExe
    if (-not $exe) {
        throw 'NDI Discovery Service.exe was not found in the NDI Tools installation.'
    }

    $ndiConfigDir = Join-Path $env:ProgramData 'NDI'
    New-Item -ItemType Directory -Path $ndiConfigDir -Force | Out-Null
    [pscustomobject]@{
        binding = '0.0.0.0'
        port_no = [string]$Config.NdiDiscoveryPort
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ndiConfigDir 'ndi-discovery-service.v1.json') -Encoding UTF8

    $service = Get-NdiDiscoveryService
    if (-not $service) {
        try {
            $process = Start-Process -FilePath $exe -ArgumentList @('install') -PassThru -WindowStyle Hidden
            if (-not $process.WaitForExit(15000)) { $process.Kill() }
        } catch {
            Write-Warning "NDI service registration was unavailable: $($_.Exception.Message)"
        }
        $service = Get-NdiDiscoveryService
    }

    if ($service) {
        Unregister-ScheduledTask -TaskName $script:NdiTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Set-Service -Name $service.Name -StartupType Automatic
        if ($service.Status -eq 'Running') {
            Restart-Service -Name $service.Name -Force
        } else {
            Start-Service -Name $service.Name
        }
        Write-Detail "NDI Discovery Server is running as $($service.DisplayName)." Green
        return
    }

    $action = New-ScheduledTaskAction -Execute $exe -Argument "-bind 0.0.0.0 -port $($Config.NdiDiscoveryPort)"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT20S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:NdiTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $script:NdiTaskName
    Write-Detail 'NDI Discovery Server startup task installed.' Green
}

function Install-FirewallRules {
    param($Config)
    Write-Step 'Opening the required Windows and WSL firewall ports'
    Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $tcpPorts = @([string]$Config.WebPort, '30000-30300', '5960-7961')
    $udpPorts = @([string]$Config.LinkPort, [string]([int]$Config.LinkPort + 1), '30000-30300', '5353', '5960-7961')
    New-NetFirewallRule -DisplayName 'KiloLink Suite TCP' -Group $script:FirewallGroup -Direction Inbound -Action Allow -Protocol TCP -LocalPort $tcpPorts | Out-Null
    New-NetFirewallRule -DisplayName 'KiloLink Suite UDP' -Group $script:FirewallGroup -Direction Inbound -Action Allow -Protocol UDP -LocalPort $udpPorts | Out-Null
    New-NetFirewallRule -DisplayName 'NDI Discovery Server TCP' -Group $script:FirewallGroup -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([string]$Config.NdiDiscoveryPort) | Out-Null
    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        foreach ($name in @("$($script:HyperVPrefix)TCP", "$($script:HyperVPrefix)UDP")) {
            Get-NetFirewallHyperVRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
        }
        New-NetFirewallHyperVRule -Name "$($script:HyperVPrefix)TCP" -DisplayName 'KiloLink WSL TCP' -Direction Inbound -VMCreatorId $script:WslVmCreatorId -Protocol TCP -LocalPorts $tcpPorts -Action Allow | Out-Null
        New-NetFirewallHyperVRule -Name "$($script:HyperVPrefix)UDP" -DisplayName 'KiloLink WSL UDP' -Direction Inbound -VMCreatorId $script:WslVmCreatorId -Protocol UDP -LocalPorts $udpPorts -Action Allow | Out-Null
    } else {
        Write-Warning 'Hyper-V firewall cmdlets are unavailable. Install current Windows updates if LAN clients cannot reach KiloLink.'
    }
}

function Install-Shortcuts {
    param($Config)
    Write-Step 'Creating KiloLink browser shortcuts'
    $url = "http://$($Config.PublicIp):$($Config.WebPort)/"
    $nl = [Environment]::NewLine
    $content = (@('[InternetShortcut]', "URL=$url", "IconFile=$env:SystemRoot\System32\SHELL32.dll", 'IconIndex=14') -join $nl) + $nl
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $programs = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Kiloview'
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    New-Item -ItemType Directory -Path $programs -Force | Out-Null
    $content | Set-Content -LiteralPath (Join-Path $desktop 'KiloLink Server Pro.url') -Encoding ASCII
    $content | Set-Content -LiteralPath (Join-Path $programs 'KiloLink Server Pro.url') -Encoding ASCII
    Write-Detail "Shortcut target: $url" Green
}

function Install-StartupTask {
    param($Config)
    Write-Step 'Installing the KiloLink startup and watchdog task'
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $template = @'
$ErrorActionPreference = 'Continue'
$Distro = '__DISTRO__'
$Container = '__CONTAINER__'
$LogPath = '__LOG__'
Start-Transcript -Path $LogPath -Append | Out-Null
Write-Host ('KiloLink watchdog ' + [DateTime]::Now.ToString('o'))
$linux = "systemctl start docker; systemctl start avahi-daemon; docker update --restart always '$Container' >/dev/null 2>&1 || true; docker start '$Container' >/dev/null 2>&1 || true; docker ps --filter name='$Container'; exec sleep infinity"
& wsl.exe -d $Distro -u root --cd / -- bash -lc $linux
Stop-Transcript | Out-Null
'@
    $helper = $template.Replace('__DISTRO__', [string]$Config.DistroName)
    $helper = $helper.Replace('__CONTAINER__', $script:ContainerName)
    $helper = $helper.Replace('__LOG__', (Join-Path $script:StateRoot 'startup.log'))
    $helper | Set-Content -LiteralPath $script:StartupScriptPath -Encoding UTF8
    $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:StartupScriptPath + '"'
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument $taskArguments
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT30S'
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $logon.Delay = 'PT30S'
    $watchdog = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -StartWhenAvailable
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $script:StartupTaskName -Action $action -Trigger @($boot, $logon, $watchdog) -Principal $principal -Settings $settings -Force | Out-Null
    } catch {
        Write-Warning 'A boot-time S4U task was blocked. Installing logon and watchdog triggers instead.'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $script:StartupTaskName -Action $action -Trigger @($logon, $watchdog) -Principal $principal -Settings $settings -Force | Out-Null
    }
    Start-ScheduledTask -TaskName $script:StartupTaskName
}

function Test-SuiteHealth {
    param($Config)
    Write-Step 'Verifying installed components'
    $taskDeadline = (Get-Date).AddSeconds(20)
    do {
        $startupTask = Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
        if ($startupTask -and $startupTask.State -eq 'Running') { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $taskDeadline)
    if (-not $startupTask -or $startupTask.State -ne 'Running') {
        throw 'The KiloLink WSL keepalive task did not remain running.'
    }
    $statusOutput = Invoke-Wsl $Config.DistroName "docker inspect -f '{{.State.Status}}' '$script:ContainerName'" -IgnoreExitCode -Capture
    $status = @($statusOutput | Select-Object -Last 1)[0]
    if ($status -ne 'running') {
        throw "KiloLink container state is '$status' instead of 'running'."
    }
    if (-not (Get-NdiDiscoveryService) -and -not (Get-ScheduledTask -TaskName $script:NdiTaskName -ErrorAction SilentlyContinue)) {
        throw 'NDI Discovery Server has no service or startup task.'
    }
    $url = "http://$($Config.PublicIp):$($Config.WebPort)/"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -TimeoutSec 15
        Write-Detail "KiloLink web response: HTTP $($response.StatusCode)" Green
    } catch {
        Write-Warning "KiloLink is running, but the web check failed: $($_.Exception.Message)"
    }
}

function Show-SuiteSummary {
    param($Config, [string]$Heading = 'Suite configuration is complete')
    $url = "http://$($Config.PublicIp):$($Config.WebPort)/"
    Write-Host ''
    Write-Heading $Heading
    Write-Host "Primary adapter:       $($Config.PrimaryInterfaceAlias) / $($Config.PublicIp)"
    Write-Host 'Listening adapters:    all active physical adapters (0.0.0.0)'
    Write-Host ''
    Write-Host 'Installed products and access details' -ForegroundColor Green
    Write-Host "KiloLink Server Pro:   $url"
    Write-Host "  Default username:    $($script:KiloDefaultUsername)"
    Write-Host "  Default password:    $($script:KiloDefaultPassword)"
    Write-Host '  Change this password immediately after the first login.' -ForegroundColor Yellow
    Write-Host '  Existing installations retain their previously configured password.' -ForegroundColor DarkGray
    Write-Host 'NDI Tools:             Installed Windows applications (no web interface)'
    Write-Host "NDI Discovery Server:  tcp://$($Config.PublicIp):$($Config.NdiDiscoveryPort) (no web interface or login)"
    Write-Host "KiloLink device link:  $($Config.PublicIp):$($Config.LinkPort)-$([int]$Config.LinkPort + 1) UDP"
    Write-Host ''
    Write-Host "Detailed install log:  $($script:InstallerLogPath)" -ForegroundColor DarkGray
}

function Repair-Suite {
    param(
        [switch]$UseSavedConfiguration,
        [switch]$LicenseAccepted
    )
    $old = Get-SavedConfig
    if ($UseSavedConfiguration) {
        if (-not $old) {
            throw 'A saved configuration is required for unattended repair.'
        }
        $config = ($old | ConvertTo-Json -Depth 5) | ConvertFrom-Json
    } else {
        $config = Read-SuiteConfig -UseSaved
    }
    Save-Config $config
    if (-not $LicenseAccepted -and -not (Confirm-LicenseAcceptance)) {
        Write-Host 'Operation cancelled.' -ForegroundColor Yellow
        return
    }
    $showProgress = $Action -in @('Menu', 'Resume')
    $succeeded = $false
    if ($showProgress) { Start-SuiteProgress -Activity 'Installing KiloLink Server Pro and NDI' -Status 'Preparing the saved configuration' }
    try {
        Set-SuiteProgress -Percent 5 -Status 'Checking Windows and WSL prerequisites'
        if (-not (Ensure-WslFeatures)) { return }
        Set-SuiteProgress -Percent 15 -Status 'Configuring mirrored multi-adapter networking'
        Ensure-MirroredNetworking
        Set-SuiteProgress -Percent 22 -Status 'Preparing the dedicated Ubuntu environment'
        $distro = Ensure-Ubuntu $config
        if (-not $distro) { return }
        Set-SuiteProgress -Percent 30 -Status 'Preparing systemd, Docker Engine, and Avahi'
        Ensure-Docker $distro
        Set-SuiteProgress -Percent 48 -Status 'Installing or validating KiloLink Server Pro'
        if ($old -and (Test-KiloContainer $distro)) {
            Sync-KiloConfig $old $config
        } else {
            Install-KiloLink $config
        }
        Set-SuiteProgress -Percent 60 -Status 'Installing or validating NDI Tools'
        Install-NdiTools
        Set-SuiteProgress -Percent 70 -Status 'Configuring NDI Discovery Server'
        Configure-NdiServer $config
        Set-SuiteProgress -Percent 77 -Status 'Opening Windows and WSL firewall ports'
        Install-FirewallRules $config
        Set-SuiteProgress -Percent 84 -Status 'Creating browser shortcuts'
        Install-Shortcuts $config
        Set-SuiteProgress -Percent 89 -Status 'Installing the persistent WSL watchdog'
        Install-StartupTask $config
        Set-SuiteProgress -Percent 94 -Status 'Saving the suite configuration'
        Save-Config $config
        Set-SuiteProgress -Percent 96 -Status 'Verifying services and web access'
        Test-SuiteHealth $config
        Set-SuiteProgress -Percent 100 -Status 'Installation complete'
        $succeeded = $true
    } finally {
        if ($showProgress) { Stop-SuiteProgress }
    }
    if ($succeeded) {
        Clear-ResumeContinuation
        Show-SuiteSummary $config
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
    Repair-Suite -UseSavedConfiguration -LicenseAccepted
}

function Update-KiloLink {
    param($Config)
    if (-not (Test-KiloContainer $Config.DistroName)) {
        Write-Detail 'KiloLink is missing. Choose Repair / Reconfigure.' Yellow
        return
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
    $content = $template.Replace('__CONTAINER__', $script:ContainerName).Replace('__IMAGE__', [string]$Config.KiloLinkImage)
    $output = Invoke-WslScript $Config.DistroName $content -Capture
    if ($output -contains 'KILOLINK_UPDATE') {
        Write-Detail 'A newer image was found. Recreating the container while retaining its data.' Yellow
        Recreate-KiloContainer $Config
        Write-Detail 'KiloLink updated.' Green
    } else {
        Write-Detail 'KiloLink is current.' Green
    }
}

function Update-Suite {
    $config = Get-SavedConfig
    if (-not $config) {
        Write-Host 'No saved configuration exists. Choose Repair / Reconfigure.' -ForegroundColor Yellow
        return
    }
    $showProgress = $Action -eq 'Menu'
    $succeeded = $false
    if ($showProgress) { Start-SuiteProgress -Activity 'Updating KiloLink Server Pro and NDI' -Status 'Preparing the saved configuration' }
    try {
        Set-SuiteProgress -Percent 6 -Status 'Checking Windows and WSL prerequisites'
        if (-not (Ensure-WslFeatures)) { return }
        Set-SuiteProgress -Percent 16 -Status 'Starting the dedicated Ubuntu services'
        $distro = Get-UbuntuDistro ([string]$config.DistroName)
        if (-not $distro) {
            Write-Host 'Ubuntu is missing. Choose Repair / Reconfigure.' -ForegroundColor Yellow
            return
        }
        $config.DistroName = $distro
        Invoke-Wsl $distro 'systemctl start docker; systemctl start avahi-daemon'
        Set-SuiteProgress -Percent 23 -Status 'Checking the primary DHCP address'
        $oldConfig = ($config | ConvertTo-Json -Depth 5) | ConvertFrom-Json
        $currentAdapter = @(Get-LanCandidates | Where-Object {
            $_.Alias -eq $config.PrimaryInterfaceAlias -and $_.Dhcp
        } | Select-Object -First 1)[0]
        if ($currentAdapter -and $currentAdapter.Address -ne $config.PublicIp) {
            Write-Detail "DHCP changed $($config.PrimaryInterfaceAlias) from $($config.PublicIp) to $($currentAdapter.Address)." Yellow
            $config.PublicIp = $currentAdapter.Address
            Sync-KiloConfig $oldConfig $config
        }
        Set-SuiteProgress -Percent 30 -Status 'Updating Ubuntu and Docker packages'
        Write-Step 'Updating Ubuntu and Docker packages'
        $linuxUpdate = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
systemctl enable --now docker
systemctl enable --now avahi-daemon
'@
        Invoke-WslScript $distro $linuxUpdate
        Set-SuiteProgress -Percent 52 -Status 'Checking the KiloLink container image'
        Update-KiloLink $config
        Set-SuiteProgress -Percent 64 -Status 'Checking the NDI Tools package'
        Install-NdiTools -UpdateOnly
        Set-SuiteProgress -Percent 76 -Status 'Refreshing NDI Discovery Server'
        Configure-NdiServer $config
        Set-SuiteProgress -Percent 82 -Status 'Refreshing firewall rules and shortcuts'
        Install-FirewallRules $config
        Install-Shortcuts $config
        Set-SuiteProgress -Percent 89 -Status 'Refreshing the persistent WSL watchdog'
        Install-StartupTask $config
        Set-SuiteProgress -Percent 94 -Status 'Saving the updated configuration'
        Save-Config $config
        Set-SuiteProgress -Percent 96 -Status 'Verifying services and web access'
        Test-SuiteHealth $config
        Set-SuiteProgress -Percent 100 -Status 'Update complete'
        $succeeded = $true
    } finally {
        if ($showProgress) { Stop-SuiteProgress }
    }
    if ($succeeded) { Show-SuiteSummary $config 'Suite update is complete' }
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
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -PassThru
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
    Write-Heading 'Uninstall KiloLink Suite'
    Write-Host 'This removes KiloLink and its persisted data, NDI Tools/Discovery Server,' -ForegroundColor Yellow
    Write-Host 'scheduled tasks, installer firewall rules, and browser shortcuts.' -ForegroundColor Yellow
    Write-Host "The dedicated $($script:ManagedDistroName) distribution will be deleted." -ForegroundColor Yellow
    Write-Host 'WSL, unrelated distributions, and the shared .wslconfig file will be retained.' -ForegroundColor Yellow
    if ((Read-InstallerInput 'Type UNINSTALL to continue') -cne 'UNINSTALL') {
        Write-Host 'Uninstall cancelled.' -ForegroundColor Yellow
        return
    }

    $showProgress = $Action -eq 'Menu'
    if ($showProgress) { Start-SuiteProgress -Activity 'Uninstalling the KiloLink and NDI suite' -Status 'Preparing removal' }
    try {
    Set-SuiteProgress -Percent 8 -Status 'Stopping startup tasks and NDI services'
    $config = Get-SavedConfig
    $preferred = if ($config) { [string](Get-PropertyValue $config 'DistroName' '') } else { '' }
    $distro = Get-UbuntuDistro $preferred
    Remove-ResumeTask
    Unregister-ScheduledTask -TaskName $script:StartupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:NdiTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $ndiService = Get-NdiDiscoveryService
    if ($ndiService) {
        Stop-Service -Name $ndiService.Name -Force -ErrorAction SilentlyContinue
    }

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

    $ndi = Get-NdiRegistration
    if ($ndi) {
        Set-SuiteProgress -Percent 50 -Status 'Uninstalling NDI Tools and Discovery Server'
        Write-Step 'Uninstalling NDI Tools and Discovery Server'
        $command = [string](Get-PropertyValue $ndi 'QuietUninstallString' '')
        if (-not $command) { $command = [string](Get-PropertyValue $ndi 'UninstallString' '') }
        if ($command) {
            Invoke-UninstallCommand $command
        } else {
            Write-Warning 'NDI Tools is installed, but its uninstaller entry is missing.'
        }
    }

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
    Remove-Item -LiteralPath $script:StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if ($showProgress) { Stop-SuiteProgress }
    }
    Write-Host 'Uninstall complete. WSL and unrelated distributions were retained.' -ForegroundColor Green
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

Ensure-Administrator
$transcriptStarted = $false
$backgroundExitCode = 0
try {
    if ($LogPath) {
        $logDirectory = Split-Path -Parent $LogPath
        if ($logDirectory) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Start-Transcript -LiteralPath $LogPath -Append | Out-Null
        $transcriptStarted = $true
    }
    switch ($Action) {
        'Menu' { Show-Menu }
        'Repair' {
            if (-not $AcceptLicenses) {
                throw 'Unattended repair requires -AcceptLicenses after the vendor agreements have been reviewed and accepted.'
            }
            Repair-Suite -UseSavedConfiguration -LicenseAccepted
        }
        'Update' { Update-Suite }
        'Resume' {
            if (-not $AcceptLicenses) {
                throw 'A restart continuation requires the license acceptance recorded by the initial setup run.'
            }
            Resume-Suite
            if ($LauncherMode -and -not $script:RestartScheduled) {
                Write-Host ''
                Read-InstallerInput 'Setup has finished. Press Enter to close this window' | Out-Null
            }
        }
    }
} catch {
    $backgroundExitCode = 1
    Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "State and logs are under $script:StateRoot" -ForegroundColor Yellow
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
if ($backgroundExitCode -ne 0) {
    if ($Action -in @('Menu', 'Resume') -and $LauncherMode) {
        Write-Host ''
        Read-InstallerInput 'Press Enter to close this window' | Out-Null
    }
    exit $backgroundExitCode
}
