function Test-WslRuntimeInstalled {
    # System32\wsl.exe also exists on a clean PC. Calling that stub, even for
    # --list/--status, can launch a detached interactive installation prompt.
    # Require passive evidence of the separately installed runtime first.
    $serviceKey='HKLM:\SYSTEM\CurrentControlSet\Services\WslService'
    if (Test-Path -LiteralPath $serviceKey) {
        $image=[Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath $serviceKey -Name ImagePath -ErrorAction Stop).ImagePath)
        if ($image -match '^"?(.+?\.exe)"?(?:\s|$)' -and (Split-Path -Leaf $Matches[1]) -ieq 'wslservice.exe' -and
            (Test-Path -LiteralPath $Matches[1] -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Matches[1]) 'wsl.exe') -PathType Leaf)) { return $true }
    }
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($package in @(Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction Stop)) {
            if ($package.InstallLocation -and (Test-Path -LiteralPath (Join-Path $package.InstallLocation 'wsl.exe') -PathType Leaf)) { return $true }
        }
    }
    return $false
}

function New-WslBootstrapHost {
    $directory=New-OwnedOperationDirectory
    $path=Join-Path $directory 'WslBootstrapHost.exe'
    $protocol=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__LIFECYCLE_PROTOCOL_BASE64__'))
    $hostSource=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__WSL_BOOTSTRAP_HOST_BASE64__'))
    $provider=New-Object Microsoft.CSharp.CSharpCodeProvider
    try {
        $parameters=New-Object CodeDom.Compiler.CompilerParameters
        $parameters.GenerateExecutable=$true;$parameters.GenerateInMemory=$false;$parameters.OutputAssembly=$path
        $parameters.CompilerOptions='/optimize+ /platform:anycpu'
        $parameters.ReferencedAssemblies.AddRange([string[]]@('System.dll','System.Core.dll','System.Web.Extensions.dll'))
        $compiled=$provider.CompileAssemblyFromSource($parameters,[string[]]@($protocol,$hostSource))
        if($compiled.Errors.HasErrors){throw ('WSL bootstrap supervisor compilation failed: '+($compiled.Errors|Out-String))}
    } finally {$provider.Dispose()}
    [KiloLink.Lifecycle.SafePath]::Check($path)
    return $path
}

function Get-WslBootstrapReceipt($Pending) {
    $path=[string](Get-PropertyValue $Pending 'bootstrapResult' '')
    if (-not $path -or -not(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    Initialize-LifecycleProtocol
    [KiloLink.Lifecycle.SafePath]::Check($path)
    $receipt=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($receipt.schemaVersion -ne 1 -or $receipt.jobName -cne $Pending.jobName){throw 'WSL bootstrap ownership receipt does not match its pending operation.'}
    return $receipt
}

function Invoke-WslRuntimeBootstrap {
    param([int]$TimeoutSeconds=$script:NativeTimeoutSeconds)
    Initialize-LifecycleProtocol
    $hostPath=New-WslBootstrapHost
    if(-not(Test-Path -LiteralPath $hostPath -PathType Leaf)){throw 'The WSL bootstrap supervisor is missing; no process was started.'}
    $jobName='Global\KiloviewWslBootstrap_'+[guid]::NewGuid().ToString('N')
    $pendingPath=Join-Path $script:StateRoot 'pending-process.json'
    $resultPath=Join-Path (Split-Path -Parent $hostPath) 'bootstrap-result.json'
    $pending=@{processId=0;startedUtc=$null;jobName=$jobName;filePath=$hostPath;bootstrapResult=$resultPath;reason='WSL runtime console bootstrap';action=$Action;
        operationId=$(if($script:Lifecycle){$script:Lifecycle.OperationId}else{$null})}
    # Durable ownership exists before Windows can start a mutating child.
    Write-StateJson $pendingPath $pending
    $process=$null
    try {
        $process=New-Object KiloLink.Lifecycle.NativeProcess($hostPath,[string[]]@($jobName,$resultPath))
        $pending.processId=$process.Id;$pending.startedUtc=$process.StartedUtc.ToString('o')
        Write-StateJson $pendingPath $pending
        Write-InstallerLog "WSL bootstrap started as process $($process.Id); tracked job $jobName."
        while (-not $process.HasExited) {
            foreach($line in $process.Drain()){Write-InstallerLog $line}
            Update-SuiteProgressPulse
            if (([datetime]::UtcNow-$process.StartedUtc).TotalSeconds -gt $TimeoutSeconds) {
                $script:LifecycleErrorCode='command-timeout'
                throw 'WSL runtime installation exceeded its deadline; its tracked process tree may still be running.'
            }
            Start-Sleep -Milliseconds 200
        }
        $code=$process.ExitCode
        foreach($line in $process.Drain()){Write-InstallerLog $line}
        $receipt=Get-WslBootstrapReceipt ([pscustomobject]$pending)
        if(-not $receipt -or $receipt.phase -ne 'completed' -or [KiloLink.Lifecycle.ConsoleBootstrapProcess]::IsJobActive($jobName)){
            throw 'WSL bootstrap exited without confirming that its tracked process tree finished.'
        }
        Write-InstallerLog "WSL bootstrap supervisor and its tracked descendants exited; exit code $code."
        Remove-Item -LiteralPath $pendingPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $pendingPath) { throw 'WSL bootstrap ownership record could not be cleared.' }
        if ($code -notin @(0,3010) -or $receipt.error) { throw "WSL runtime console bootstrap failed with exit code $code. $($receipt.error)" }
        return $code
    } catch {
        if (Test-Path -LiteralPath $pendingPath) {
            # A constructor can fail after Windows started the supervisor. A
            # missing wrapper instance is not proof that no child exists.
            $script:LifecycleRecoveryRequired=$true
            if (-not $script:LifecycleErrorCode) { $script:LifecycleErrorCode='wsl-runtime-install-incomplete' }
            $script:LifecycleNextAction='WSL installation may still be running. Wait for its tracked process tree to finish, then use Verify before retrying. Do not start another installation or restart Windows while it is active.'
        }
        throw
    } finally {
        # No forced termination of Windows servicing. The named job and pending
        # record survive an active child and keep subsequent operations blocked.
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Write-WslProbeFailure {
    param([string]$Probe,[string]$Message)
    if (-not (Get-Variable WslProbeFailures -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) { $script:WslProbeFailures=@{} }
    $messageText=($Message -replace '[\r\n]+',' ').Trim()
    if($messageText.Length -gt 1024){$messageText=$messageText.Substring(0,1024)}
    $now=[datetime]::UtcNow
    $previous=$script:WslProbeFailures[$Probe]
    if(-not $previous -or $previous.message -cne $messageText -or ($now-$previous.loggedUtc).TotalSeconds -ge 30){
        Write-InstallerLog "WSL $Probe probe: $messageText"
        $script:WslProbeFailures[$Probe]=@{message=$messageText;loggedUtc=$now}
    }
}

function Get-WslDistroNames {
    if (-not (Test-WslRuntimeInstalled)) { return @() }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return @()
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # A clean Windows installation has wsl.exe present even when the WSL
        # platform is not installed. Its expected diagnostic on stderr must not
        # terminate the installer menu while $ErrorActionPreference is Stop.
        $ErrorActionPreference = 'Continue'
        $output = Invoke-Native wsl.exe @('--list','--quiet') -Capture -IgnoreExitCode -ReadOnly -TimeoutSeconds 30 -StallSeconds 30
        $code = $LASTEXITCODE
    } catch {
        Write-WslProbeFailure 'distribution' "Unavailable: $($_.Exception.Message)"
        return @()
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($code -ne 0) {
        Write-WslProbeFailure 'distribution' "Exited with code $code."
        return @()
    }
    return @($output | ForEach-Object { ([string]$_ -replace [char]0, '').Trim() } | Where-Object { $_ })
}

function Test-WslRuntime {
    if (-not (Test-WslRuntimeInstalled)) { return $false }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        Invoke-Native wsl.exe @('--status') -IgnoreExitCode -ReadOnly -TimeoutSeconds 30 -StallSeconds 30 | Out-Null
        $code=$LASTEXITCODE
        if($code -ne 0){Write-WslProbeFailure 'runtime status' "Exited with code $code.";return $false}
        return $true
    } catch {
        Write-WslProbeFailure 'runtime status' "Unavailable: $($_.Exception.Message)"
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
        return Get-Content -Encoding UTF8 -Raw -LiteralPath $script:ResumeStatePath | ConvertFrom-Json
    } catch {
        Write-InstallerLog "Resume state could not be read: $($_.Exception.Message)"
        return $null
    }
}

function Remove-ResumeTask {
    Remove-OwnedTask $script:ResumeTaskName
}

function Clear-ResumeContinuation {
    Remove-ResumeTask
    Remove-OwnedFile $script:ResumeStatePath
}

function Get-ExactResumeTask {
    $lookupErrors = @()
    $tasks = @(Get-ScheduledTask -TaskName $script:ResumeTaskName -TaskPath '\' -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
    if (@($lookupErrors | Where-Object { $_.CategoryInfo.Category -ne 'ObjectNotFound' }).Count) {
        throw "The restart continuation task could not be inspected: $($lookupErrors[0])"
    }
    if ($tasks.Count -gt 1) { throw 'The restart continuation task identity is ambiguous.' }
    if ($tasks.Count) { return $tasks[0] }
    return $null
}

function Complete-FailedResumeContinuation {
    # Called while the entry point still owns the operation mutex, after its
    # terminal result. A pending/unconfirmed child retains its recovery owner.
    if ($Action -ne 'Resume' -or $script:OperationOutcome -notin @('Failed','Partial') -or
        $script:LifecycleRecoveryRequired -or $script:LifecycleErrorCode -eq 'lifecycle-result-write-failed' -or
        (Test-Path -LiteralPath (Join-Path $script:StateRoot 'pending-process.json'))) { return }
    $originalMessage = $script:OperationMessage
    try {
        $continuation = Get-ResumeState
        if (-not $continuation) { return }
        $outcome = Get-LifecycleResultOutcome $script:OperationOutcome
        if ($script:Lifecycle) {
            $result = $script:Lifecycle.ReadResult()
            if (-not $result -or $result['outcome'] -notin @('failed','partial')) { return }
            if ((Get-PropertyValue $continuation 'OperationId' '') -ne $script:Lifecycle.OperationId -or
                (Get-PropertyValue $continuation 'LifecycleRequestPath' '') -ine $script:Lifecycle.RequestPath) {
                throw 'Restart continuation belongs to a different operation; its task was not changed.'
            }
            $outcome = $result['outcome']
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ((Get-PropertyValue $continuation 'User' '') -ine $identity.Name) { throw 'Restart continuation belongs to a different Windows user.' }
        $task = Get-ExactResumeTask
        if ($task) {
            $actions = @($task.Actions)
            $expectedArguments = '--resume'
            $request = Get-PropertyValue $continuation 'LifecycleRequestPath' ''
            if ($request) { $expectedArguments += ' --lifecycle-request "' + $request + '"' }
            $taskOwner = if ($task.Principal.UserId -match '^S-1-') {
                [Security.Principal.SecurityIdentifier]::new($task.Principal.UserId)
            } else {
                [Security.Principal.NTAccount]::new($task.Principal.UserId).Translate([Security.Principal.SecurityIdentifier])
            }
            if ($actions.Count -ne 1 -or $actions[0].Execute -ine $script:PersistentLauncherPath -or
                $actions[0].Arguments -cne $expectedArguments -or
                $taskOwner.Value -ne $identity.User.Value) {
                throw 'Restart continuation task no longer matches this operation and user; it was not changed.'
            }
            Unregister-ScheduledTask -TaskName $script:ResumeTaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
            if (Get-ExactResumeTask) { throw 'Windows still reports the restart continuation task after removal.' }
        }
        # Retain original request/configuration/restart counters for an explicit
        # reviewed retry. A later required reboot registers a fresh trigger.
        $continuation | Add-Member NoteProperty AutomaticContinuationStopped $true -Force
        $continuation | Add-Member NoteProperty TerminalOutcome $outcome -Force
        $continuation | Add-Member NoteProperty StoppedAtUtc ([datetime]::UtcNow.ToString('o')) -Force
        Write-StateJson $script:ResumeStatePath $continuation
        Write-InstallerLog 'Automatic restart continuation removed after terminal failure. Request, configuration and recovery records were retained for explicit retry.'
    } catch {
        $failure = $_.Exception.Message
        $script:LifecycleRecoveryRequired = $true
        if (-not $script:LifecycleErrorCode) { $script:LifecycleErrorCode = 'resume-continuation-stop-failed' }
        $guidance = "Automatic restart continuation could not be confirmed stopped. Inspect the '$script:ResumeTaskName' task before signing in again or retrying. $failure"
        $script:LifecycleNextAction = (@($script:LifecycleNextAction,$guidance) | Where-Object { $_ }) -join ' '
        if ($script:ActiveJournal) { $script:ActiveJournal['resumeContinuationFailure'] = $failure }
        Set-OperationOutcome $script:OperationOutcome ($originalMessage + ' ' + $guidance)
    }
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
        $resumeArguments='--resume'
        if($script:Lifecycle){$resumeArguments+=' --lifecycle-request "'+$script:Lifecycle.RequestPath+'"'}
        $taskAction = New-ScheduledTaskAction -Execute $script:PersistentLauncherPath -Argument $resumeArguments
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
        if($script:Lifecycle){$arguments+=' -LifecycleRequestPath "'+$script:Lifecycle.RequestPath+'"'}
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

    $resumeState=[pscustomobject]@{
        SchemaVersion = 1
        Attempt = $attempt
        Reason = $Reason
        RegisteredAt = (Get-Date).ToString('o')
        User = $identity
        Action = if ($Action -eq 'Resume') { Get-PropertyValue $oldState 'Action' 'Repair' } elseif ($Action -in @('Setup','InstallClient','Update','MaintainRuntime')) { $Action } else { 'Repair' }
        LifecycleRequestPath=$(if($script:Lifecycle){$script:Lifecycle.RequestPath}else{$null})
        OperationId=$(if($script:Lifecycle){$script:Lifecycle.OperationId}else{$null})
        ConfigurationPath=$(Get-Variable ConfigurationPath -ValueOnly -ErrorAction SilentlyContinue)
    }
    Write-StateJson $script:ResumeStatePath $resumeState
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
    param([string]$Distro, [double]$TimeoutSeconds=30, [ref]$ProbeResult)
    $probe=Get-WslDistroLaunchProbe -Distro $Distro -TimeoutSeconds $TimeoutSeconds
    if($ProbeResult){$ProbeResult.Value=$probe}
    return $probe.Success
}

function Get-WslDistroLaunchProbe {
    param([string]$Distro, [double]$TimeoutSeconds=30)
    if (-not $Distro) { throw 'A distribution name is required for the WSL launch probe.' }
    if ($TimeoutSeconds -le 0) {
        return [pscustomobject]@{Success=$false;ExitCode=$null;TimedOut=$true;Output=@('The WSL launch deadline expired before another probe could start.')}
    }
    $previousErrorCode=$script:LifecycleErrorCode
    $timedOut=$false
    try {
        $output=@(Invoke-Native wsl.exe @('-d',$Distro,'-u','root','--cd','/','--','true') -Capture -IgnoreExitCode -ReadOnly -TimeoutSeconds $TimeoutSeconds -StallSeconds $TimeoutSeconds)
        $code = $LASTEXITCODE
    } catch [TimeoutException] {
        # Only a native deadline is a retryable probe result. In particular,
        # heartbeat/result persistence failures must escape after CLI cleanup.
        if (-not $_.Exception.Data['NativeCommandTimeout']) { throw }
        $output=@($_.Exception.Data['NativeOutput']) + "The WSL launch probe exceeded its $TimeoutSeconds-second time limit; its owned CLI was stopped."
        $code=$null
        $timedOut=$true
        # A later successful retry must not retain this transient timeout as
        # the operation's error. Terminal wait failure is assigned by its caller.
        $script:LifecycleErrorCode=$previousErrorCode
    }
    $output=@($output | ForEach-Object {([string]$_ -replace [char]0,'').Trim()} | Where-Object {$_})
    foreach ($line in $output) { Write-InstallerLog "WSL launch probe: $line" }
    return [pscustomobject]@{
        Success = -not $timedOut -and $code -eq 0
        ExitCode = $code
        TimedOut = $timedOut
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
    param([string]$Distro, [string[]]$Output, [switch]$TimedOut)
    $diagnostic = @($Output | Where-Object { $_ }) -join ' '
    if ($TimedOut) { return "The WSL launch probe for '$Distro' exceeded its time limit. $diagnostic" }
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
    param([string]$Distro, [double]$TimeoutSeconds = 180, [ref]$LastProbe)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $probe=[pscustomobject]@{Success=$false;ExitCode=$null;TimedOut=$true;Output=@('The WSL readiness deadline expired before another probe could start.')}
    if($LastProbe){$LastProbe.Value=$probe}
    while (($remaining=$TimeoutSeconds-$clock.Elapsed.TotalSeconds) -gt 0) {
        # Each native call shares the overall wait budget. A slow launch cannot
        # bypass the polling deadline or start an extra diagnostic afterward.
        $ready=Test-WslDistroReady -Distro $Distro -TimeoutSeconds ([Math]::Min(30,$remaining)) -ProbeResult ([ref]$probe)
        if($LastProbe){$LastProbe.Value=$probe}
        if ($ready) {
            return $true
        }
        $nextProbeAt=[Math]::Min($TimeoutSeconds,$clock.Elapsed.TotalSeconds+3)
        while($clock.Elapsed.TotalSeconds -lt $nextProbeAt) {
            Update-SuiteProgressPulse
            $sleepMilliseconds=[Math]::Min(250,[Math]::Ceiling(($nextProbeAt-$clock.Elapsed.TotalSeconds)*1000))
            if($sleepMilliseconds -gt 0){Start-Sleep -Milliseconds ([int]$sleepMilliseconds)}
        }
    }
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
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    # PowerShell here-strings use Windows CRLF endings. Bash treats the trailing
    # carriage return as part of tokens such as "pipefail", so normalize every
    # generated Linux script before it crosses the WSL boundary.
    $normalizedContent = ([string]$Content).Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8 = New-Object Text.UTF8Encoding($false)
    $base64 = [Convert]::ToBase64String($utf8.GetBytes($normalizedContent))
    $command = "printf '%s' '$base64' | base64 -d > /tmp/kilolink-suite.sh && chmod 700 /tmp/kilolink-suite.sh && bash /tmp/kilolink-suite.sh"
    return Invoke-Wsl $Distro $command -Capture:$Capture -IgnoreExitCode:$IgnoreExitCode
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
