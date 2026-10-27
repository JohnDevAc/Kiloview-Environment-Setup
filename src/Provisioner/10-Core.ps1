function Set-OperationOutcome {
    param(
        [ValidateSet('Idle', 'Running', 'Completed', 'NoChange', 'Cancelled', 'RestartRequired', 'Failed', 'Partial', 'Blocked')]
        [string]$Outcome,
        [string]$Message
    )
    $script:OperationOutcome = $Outcome
    $script:OperationMessage = $Message
    if ($Outcome -in @('Failed','Partial','Blocked')) { $script:OperationFailed = $true }
    if ($Outcome -in @('Completed','NoChange')) { $script:OperationFailed = $false }
    if ($Outcome -eq 'Running' -and $script:ActiveJournal -and $script:ActiveJournal.outcome -ne 'Running') { $script:ActiveJournal = $null }
    if ($script:ActiveJournal) {
        $script:ActiveJournal.outcome = $Outcome
        $script:ActiveJournal['recoveryRequired']=$script:LifecycleRecoveryRequired
        Save-DeploymentJournal
    }
    if($script:Lifecycle -and $Outcome -notin @('Idle','Running')){
        try{$script:LifecycleComponents=@(Get-ObservedComponents)}catch{Write-InstallerLog ('Final component inspection failed: '+$_.Exception.Message)}
    }
    Write-LauncherEvent -Type 'outcome' -Data @{ outcome = $Outcome; message = $Message }
    Write-LifecycleResult (Get-LifecycleResultOutcome $Outcome) $Message
    if ($Outcome -notin @('Idle','Running') -and $script:ProgressActive) {
        $finalPercent = if ($Outcome -in @('Completed','NoChange')) { 100 } else { $script:ProgressPercent }
        Set-SuiteProgress -Percent $finalPercent -Status $Message
    }
}

function Get-InstallerExitCode {
    if ($script:OperationOutcome -eq 'RestartRequired') { return 3010 }
    if ($script:LifecycleErrorCode -eq 'operation-conflict') { return 1618 }
    if ($script:OperationOutcome -eq 'Cancelled') { if ($script:LifecycleEffects.Count) { return 1 }; return 1602 }
    if ($script:OperationFailed -or $script:OperationOutcome -eq 'Running') { return 1 }
    return 0
}

function Write-LauncherEvent {
    param([string]$Type, [hashtable]$Data = @{})
    if (-not $LauncherMode) { return }
    $payload = [ordered]@{ type = $Type }
    if ($script:Lifecycle) { $payload['operationId']=$script:Lifecycle.OperationId }
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
    # wsl.exe can emit UTF-16 text through a native pipeline. Strip embedded
    # NUL characters so diagnostics remain readable in Notepad and on screen.
    $cleanMessage = ([string]$Message -replace [char]0, '').TrimEnd()
    $line = '{0} {1}' -f (Get-Date).ToString('o'), $cleanMessage
    $previous=Get-Variable InstallerLogFailure -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $now=[datetime]::UtcNow
    $failure=$null
    $deferRetry=$previous -and $previous.path -eq $script:InstallerLogPath -and $now -lt $previous.retryAfterUtc
    if($deferRetry){$failure=$previous.message}
    else {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do {
            $stream=$null;$writer=$null
            try {
                if (-not (Test-Path -LiteralPath $script:StateRoot)) { return }
                # PS5.1 Add-Content can reject even a ReadWrite|Delete reader.
                # Diagnostics must coexist with readers and never abort servicing.
                $stream=[IO.FileStream]::new($script:InstallerLogPath,[IO.FileMode]::Append,[IO.FileAccess]::Write,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
                $writer.WriteLine($line);$writer.Flush()
                return
            } catch {
                $errorDetails=$_.Exception.GetBaseException()
                $failure=$errorDetails.Message
                $retry=($errorDetails.HResult -band 0xffff) -in @(32,33) -and $clock.ElapsedMilliseconds -lt 250
            } finally {
                if($writer){try{$writer.Dispose()}catch{}}
                elseif($stream){try{$stream.Dispose()}catch{}}
            }
            if($retry){Start-Sleep -Milliseconds 50}
        } while($retry)
    }
    # Avoid a fresh retry delay for every native output line during a persistent
    # lock. Keep fallback output in the host/transcript without changing outcome.
    $warn=-not $previous -or $previous.path -ne $script:InstallerLogPath -or $previous.message -ne $failure -or ($now-$previous.warnedUtc).TotalSeconds -ge 30
    $script:InstallerLogFailure=@{path=$script:InstallerLogPath;message=$failure;retryAfterUtc=$(if($deferRetry){$previous.retryAfterUtc}else{[datetime]::UtcNow.AddSeconds(1)});warnedUtc=$(if($warn){$now}else{$previous.warnedUtc})}
    try {
        if($warn){Write-Warning -Message "Could not append the diagnostic log '$($script:InstallerLogPath)': $failure Diagnostic output is being sent to the setup host/transcript." -WarningAction Continue}
        Write-Host $line
    } catch { } # A secondary diagnostic sink must not replace the real error.
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
    # Completion belongs to the operation outcome, never a finished download.
    $maximum = if ($script:OperationOutcome -in @('Completed','NoChange')) { 100 } else { 99 }
    $script:ProgressPercent = [Math]::Min($maximum, [Math]::Max($script:ProgressPercent, [Math]::Max(0, $Percent)))
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
    Write-LifecycleHeartbeat
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
    try { Initialize-Lifecycle } catch { if($script:Lifecycle){Write-LifecycleResult 'blocked' $_.Exception.Message -Stage 'preflight' -ErrorCode 'request-rejected'}; Write-Error $_ -ErrorAction Continue; exit 1 }
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
    if ($LifecycleRequestPath) { $elevationArguments += " -LifecycleRequestPath `"$LifecycleRequestPath`"" }
    if ($Role) { $elevationArguments += " -Role $Role" }
    if ($PurgeData) { $elevationArguments += ' -PurgeData' }
    if ($ForceComponentRepair) { $elevationArguments += ' -ForceComponentRepair' }
    if ($PreferredInterfaceAlias) { $elevationArguments += " -PreferredInterfaceAlias `"$PreferredInterfaceAlias`"" }
    if ($PreferredIpAddress) { $elevationArguments += " -PreferredIpAddress `"$PreferredIpAddress`"" }
    try {
        Write-LifecycleResult 'running' 'Waiting for Windows administrator approval.' -Stage 'waiting-elevation'
        $elevated = Start-Process powershell.exe -ArgumentList $elevationArguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        exit $elevated.ExitCode
    } catch {
        if ((Get-PropertyValue $_.Exception 'NativeErrorCode' 0) -eq 1223) { Set-OperationOutcome 'Cancelled' 'Windows administrator approval was cancelled.'; exit 1602 }
        Set-OperationOutcome 'Failed' $_.Exception.Message
        exit 1
    }
}

function Get-SavedConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return $null
    }
    try {
        return Get-Content -Encoding UTF8 -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json
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
    Add-LifecycleEffect 'Server configuration saved.'
}

function Get-RequestedSuiteConfig {
    param([string]$Path)
    $request = Get-Content -Encoding UTF8 -Raw -LiteralPath $Path | ConvertFrom-Json
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
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KiloviewEnvironmentSetup'
    if(Test-Path -LiteralPath $key){Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop}
    if(Test-Path -LiteralPath $key){throw 'Server role maintenance registration remains after removal.'}
    $programs = Join-Path ([Environment]::GetFolderPath('Programs')) 'Kiloview'
    Remove-OwnedFile (Join-Path $programs 'Kiloview Environment Setup.lnk')
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments=@(), [switch]$IgnoreExitCode, [switch]$Capture,
        [double]$TimeoutSeconds=$script:NativeTimeoutSeconds, [double]$StallSeconds=$script:NativeStallSeconds, [switch]$ReadOnly)
    Initialize-LifecycleProtocol
    # -CommandType Application can return every PATH match even without -All.
    # Preserve command precedence and pass exactly one path to ProcessStartInfo.
    $command=Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $resolvedFile=$command.Source
    if ($resolvedFile -isnot [string] -or -not [IO.Path]::IsPathRooted($resolvedFile) -or -not [IO.File]::Exists($resolvedFile)) {
        throw "The selected native executable is missing or is not a single absolute file path: $FilePath"
    }
    $process=New-Object KiloLink.Lifecycle.NativeProcess($resolvedFile, $Arguments)
    $output=New-Object 'Collections.Generic.List[string]'
    $recent=New-Object 'Collections.Generic.List[string]'
    $exitObserved=$false
    try {
        do {
            foreach($line in $process.Drain()) {
                if($Capture){$output.Add($line)}
                if($line){$recent.Add($line);if($recent.Count -gt 12){$recent.RemoveAt(0)}}
                Write-InstallerLog $line
            }
            Update-SuiteProgressPulse
            if($process.HasExited){break}
            if(([datetime]::UtcNow-$process.StartedUtc).TotalSeconds -gt $TimeoutSeconds -or
                ($StallSeconds -gt 0 -and ([datetime]::UtcNow-$process.LastOutputUtc).TotalSeconds -gt $StallSeconds)) {
                if($ReadOnly){
                    $process.StopProbe()
                    if(-not $process.HasExited){throw 'The owned read-only CLI could not be confirmed stopped after its deadline.'}
                }
                else {
                    $script:LifecycleRecoveryRequired=$true
                    $script:LifecycleNextAction='An unattended command exceeded its deadline and may still be running. Wait for that command, inspect recovery records, then use Verify before retrying.'
                }
                $script:LifecycleErrorCode='command-timeout'
                $failure=[TimeoutException]::new("Command exceeded its time limit: $FilePath. $($script:LifecycleNextAction)")
                $failure.Data['NativeCommandTimeout']=$true
                $failure.Data['NativeOutput']=$output.ToArray()
                throw $failure
            }
            Start-Sleep -Milliseconds 200
        } while($true)
        $code=$process.ExitCode
        $exitObserved=$true
        foreach($line in $process.Drain()){if($Capture){$output.Add($line)};if($line){$recent.Add($line)};Write-InstallerLog $line}
        $global:LASTEXITCODE=$code
        if(-not $IgnoreExitCode -and $code -ne 0){throw ('Command failed with exit code {0}: {1}. {2}' -f $code,$FilePath,(@($recent|Select-Object -Last 6)-join ' '))}
        if($Capture){return $output.ToArray()}
    } catch {
        $originalFailure=$_
        if(-not $ReadOnly -and -not $exitObserved) {
            # A producer/heartbeat failure is not proof that the mutating child
            # finished. Retain its identity without terminating it or servicing.
            $script:LifecycleRecoveryRequired=$true
            if(-not $script:LifecycleErrorCode){$script:LifecycleErrorCode='native-command-observation-failed'}
            $guidance='Native command completion was not observed. Wait for the recorded command, inspect its package/recovery state, then use Verify before retrying. Do not start another operation while it may still be running.'
            $script:LifecycleNextAction=(@($script:LifecycleNextAction,$guidance)|Where-Object {$_}) -join ' '
            $pending=@{
                processId=$process.Id;startedUtc=$process.StartedUtc.ToString('o');filePath=$resolvedFile;
                reason=$(if($script:LifecycleErrorCode -eq 'command-timeout'){'Command exceeded its deadline'}else{'Native command completion was not observed'});
                action=$Action;operationId=$(if($script:Lifecycle){$script:Lifecycle.OperationId}else{$null})}
            if($script:ActiveJournal){$script:ActiveJournal['pendingNativeProcess']=$pending}
            try {
                Write-StateJson (Join-Path $script:StateRoot 'pending-process.json') $pending
            } catch {
                $recordFailure=$_.Exception.Message
                $script:LifecycleNextAction+=' The pending command record could not be saved: '+$recordFailure
                Write-InstallerLog ("Original command error: $($originalFailure.Exception.Message) Pending ownership write failed: $recordFailure")
            }
        }
        throw $originalFailure
    } finally {
        # A heartbeat/result-write error must not abandon a read-only probe.
        # Mutating commands retain the existing recovery/ownership behavior.
        try { if ($ReadOnly -and -not $process.HasExited) { $process.StopProbe() } }
        finally { $process.Dispose() }
    }
}
