function Set-OperationOutcome {
    param(
        [ValidateSet('Idle', 'Running', 'Completed', 'Cancelled', 'RestartRequired', 'Failed')]
        [string]$Outcome,
        [string]$Message
    )
    $script:OperationOutcome = $Outcome
    $script:OperationMessage = $Message
    if ($Outcome -eq 'Failed') { $script:OperationFailed = $true }
    if ($Outcome -eq 'Completed') { $script:OperationFailed = $false }
    if ($Outcome -eq 'Running' -and $script:ActiveJournal -and $script:ActiveJournal.outcome -ne 'Running') { $script:ActiveJournal = $null }
    if ($script:ActiveJournal) {
        $script:ActiveJournal.outcome = $Outcome
        Save-DeploymentJournal
    }
    Write-LauncherEvent -Type 'outcome' -Data @{ outcome = $Outcome; message = $Message }
}

function Get-InstallerExitCode {
    if ($script:OperationOutcome -eq 'RestartRequired') { return 3010 }
    if ($script:OperationFailed -or $script:OperationOutcome -eq 'Running') { return 1 }
    return 0
}

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
        throw "Setup needs configuration from the Windows interface: $Prompt. Return to setup and review the settings."
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
    if ($Action -in @('Inspect','Plan')) { return }
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
    if ($LauncherMode) { $elevationArguments = '-WindowStyle Hidden ' + $elevationArguments + ' -LauncherMode' }
    if ($LogPath) { $elevationArguments += " -LogPath `"$LogPath`"" }
    if ($ConfigurationPath) { $elevationArguments += " -ConfigurationPath `"$ConfigurationPath`"" }
    if ($PackageDirectory) { $elevationArguments += " -PackageDirectory `"$PackageDirectory`"" }
    if ($ConfirmRemoval) { $elevationArguments += ' -ConfirmRemoval' }
    if ($PreferredInterfaceAlias) { $elevationArguments += " -PreferredInterfaceAlias `"$PreferredInterfaceAlias`"" }
    if ($PreferredIpAddress) { $elevationArguments += " -PreferredIpAddress `"$PreferredIpAddress`"" }
    if ($LauncherMode) { Start-Process powershell.exe -ArgumentList $elevationArguments -Verb RunAs -WindowStyle Hidden | Out-Null }
    else { Start-Process powershell.exe -ArgumentList $elevationArguments -Verb RunAs | Out-Null }
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
    Write-StateJson $script:ConfigPath $Config
}

function Get-RequestedSuiteConfig {
    param([string]$Path)
    $request = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ([int](Get-PropertyValue $request 'SchemaVersion' 0) -ne 1) {
        throw 'Unsupported setup configuration. Reopen the current installer.'
    }
    $alias = [string](Get-PropertyValue $request 'PrimaryInterfaceAlias' '')
    $address = [string](Get-PropertyValue $request 'PublicIp' '')
    $ip = $null
    if (-not $alias -or $address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($address, [ref]$ip) -or
        $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $ip.GetAddressBytes()[0] -in @(0, 127) -or $ip.GetAddressBytes()[0] -ge 224 -or
        ($ip.GetAddressBytes()[0] -eq 169 -and $ip.GetAddressBytes()[1] -eq 254)) {
        throw 'Select a physical adapter with a usable IPv4 address in Network settings.'
    }
    $ports = @{}
    foreach ($name in @('WebPort', 'LinkPort', 'NdiDiscoveryPort')) {
        $port = 0
        if (-not [int]::TryParse([string](Get-PropertyValue $request $name ''), [ref]$port) -or
            $port -lt 1 -or $port -gt 65535) { throw "Invalid $name. Enter a port between 1 and 65535." }
        $ports[$name] = $port
    }
    if ($ports.LinkPort % 2 -ne 0 -or $ports.LinkPort -gt 65534) {
        throw 'The KiloLink link port must be even and between 2 and 65534.'
    }
    if ($ports.WebPort -eq $ports.NdiDiscoveryPort) {
        throw 'KiloLink web and NDI Discovery must use different TCP ports.'
    }
    Assert-SuitePorts ([pscustomobject]$ports)
    $adapter = @(Get-LanCandidates | Where-Object { $_.Alias -eq $alias -and $_.Address -eq $address })
    if ($adapter.Count -eq 0) { throw 'The selected adapter/address is no longer available. Refresh Network settings and retry.' }
    $saved = Get-SavedConfig
    $distro = [string](Get-PropertyValue $saved 'DistroName' $script:ManagedDistroName)
    $distros = @(Get-WslDistroNames)
    if ($distro -ne $script:ManagedDistroName -and
        ($distros -notcontains $distro -or -not (Test-KiloContainer $distro))) {
        $distro = $script:ManagedDistroName
    }
    $existing = $saved
    if (-not $existing -and $distros -contains $distro -and (Test-KiloContainer $distro)) {
        $existing = Get-LegacyKiloConfig $distro
        if (-not $existing) { throw 'Could not read the existing container settings. Repair stopped to preserve its data.' }
    }
    # Infrastructure values are retained, never accepted from the UI request.
    $dataPath = [string](Get-PropertyValue $existing 'LinuxDataPath' $script:LinuxDataPath)
    $image = [string](Get-PropertyValue $existing 'KiloLinkImage' $script:KiloImage)
    if ($distro -notmatch '^[a-zA-Z0-9_.-]+$' -or
        $dataPath -notmatch '^/(?:opt|root|home/[a-zA-Z0-9_-]+)/kilolink-server/?$' -or
        $image -notmatch '^kiloview/klnk-pro(?::[a-zA-Z0-9_.-]+|@sha256:[a-fA-F0-9]{64})?$') {
        throw 'Saved container settings are outside the supported vendor image or data locations. Review installer-config.json before continuing.'
    }
    return [pscustomobject]@{
        SchemaVersion = 1; PrimaryInterfaceAlias = $alias; PublicIp = $address
        WebPort = $ports.WebPort; LinkPort = $ports.LinkPort; NdiDiscoveryPort = $ports.NdiDiscoveryPort
        DistroName = $distro; LinuxDataPath = $dataPath; KiloLinkImage = $image
    }
}

function Register-MaintenanceEntry {
    if (-not $LauncherMode -or -not (Test-Path -LiteralPath $script:PersistentLauncherPath)) { return }
    # WSL distributions belong to the installing Windows account.
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KiloviewEnvironmentSetup'
    New-Item -Path $key -Force | Out-Null
    $values = @{
        DisplayName = 'Kiloview Server Configuration'; DisplayVersion = $script:ProductVersion
        Publisher = 'John Lightfoot'; DisplayIcon = $script:PersistentLauncherPath
        InstallLocation = $script:StateRoot
        UninstallString = ('"{0}" --uninstall' -f $script:PersistentLauncherPath)
        ModifyPath = ('"{0}" --repair' -f $script:PersistentLauncherPath)
    }
    foreach ($name in $values.Keys) { New-ItemProperty -Path $key -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null }
    $programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'Kiloview'
    New-Item -ItemType Directory -Path $programs -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $programs 'Kiloview Environment Setup.lnk'))
    $shortcut.TargetPath = $script:PersistentLauncherPath
    $shortcut.Save()
}

function Remove-MaintenanceEntry {
    Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KiloviewEnvironmentSetup' -Recurse -Force -ErrorAction SilentlyContinue
    $programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'Kiloview'
    Remove-Item -LiteralPath (Join-Path $programs 'Kiloview Environment Setup.lnk') -Force -ErrorAction SilentlyContinue
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
