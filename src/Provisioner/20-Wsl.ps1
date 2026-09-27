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
        $quietSource = Join-Path $PSScriptRoot 'launcher\QuietInstaller.cs'
        if (Test-Path -LiteralPath $quietSource) { Copy-Item -LiteralPath $quietSource -Destination (Join-Path (Split-Path -Parent $resumeScript) 'QuietInstaller.cs') -Force }
        $arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$resumeScript`" -Action Resume -AcceptLicenses -LauncherMode -LogPath `"$(Join-Path $script:StateRoot 'setup-launcher.log')`""
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
        Action = if ($Action -eq 'Resume') { Get-PropertyValue $oldState 'Action' 'Repair' } elseif ($Action -in @('Setup','Update','MaintainRuntime')) { $Action } else { 'Repair' }
    } | ConvertTo-Json | Set-Content -LiteralPath $script:ResumeStatePath -Encoding UTF8
    Write-InstallerLog "Registered restart continuation attempt $attempt for $identity. Reason: $Reason"
}

function Request-RestartAndResume {
    param([string]$Reason)
    Register-ResumeContinuation -Reason $Reason
    $script:RestartScheduled = $true
    Set-OperationOutcome 'RestartRequired' 'Restart Windows and sign back in to continue setup.'
    if ($script:ProgressActive) {
        Stop-SuiteProgress
    }
    Write-Host ''
    Write-Heading 'Windows restart required'
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host 'Setup will resume automatically about 20 seconds after you sign back in.' -ForegroundColor Green

    $restartNow = ($Action -eq 'Resume' -and -not $LauncherMode) -or $AutoRestart
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
