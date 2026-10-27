#Requires -Version 5.1
# Real harmless native processes under PS5.1. Never runs real WSL or a distro.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run readiness regressions in Windows PowerShell 5.1.'}
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-wsl-readiness-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Import-Functions([string]$Path){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) ('Source parse failed: '+$Path)
    [scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object {$_.Extent.Text})) -join "`n")
}
$core=Import-Functions (Join-Path $root 'src\Provisioner\10-Core.ps1')
$wsl=Import-Functions (Join-Path $root 'src\Provisioner\20-Wsl.ps1')
$linux=Import-Functions (Join-Path $root 'src\Provisioner\40-Linux.ps1')
$lifecycleFunctions=Import-Functions (Join-Path $root 'src\Provisioner\12-Lifecycle.ps1')
Add-Type -Path (Join-Path $root 'launcher\LifecycleProtocol.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$bin=Join-Path $testRoot 'harmless path';New-Item -ItemType Directory -Path $bin|Out-Null
$fixture=Join-Path $bin 'wsl.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ("/out:$fixture") (Join-Path $PSScriptRoot 'WslReadiness.Fixture.cs')
Assert-True ($LASTEXITCODE -eq 0) 'Fixture compilation failed.'
$priorPath=$env:PATH;$priorMode=$env:KILOVIEW_READINESS_MODE;$priorDirectory=$env:KILOVIEW_READINESS_DIRECTORY
$env:PATH=$bin+';'+$priorPath
Assert-True ((@(Get-Command wsl.exe -CommandType Application))[0].Source -ieq $fixture) 'First command is not the harmless fixture; refusing execution.'
function Get-Starts {
    @(Get-ChildItem -LiteralPath $env:KILOVIEW_READINESS_DIRECTORY -Filter 'started-*.json'|ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json})
}
function Assert-ProcessesStopped {
    foreach($started in @(Get-Starts)){
        $process=Get-Process -Id $started.processId -ErrorAction SilentlyContinue
        Assert-True (-not $process -or $process.StartTime.ToUniversalTime() -ne [datetime]$started.startedUtc) ('Owned CLI still running: '+$started.processId)
    }
}
function Reset-Fixture([string]$Label,[string]$Mode='success'){
    $directory=Join-Path $testRoot $Label
    New-Item -ItemType Directory -Path $directory|Out-Null
    $env:KILOVIEW_READINESS_DIRECTORY=$directory;$env:KILOVIEW_READINESS_MODE=$Mode
    $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:LifecycleRecoveryRequired=$false
    $script:Lifecycle=$null;$script:ActiveJournal=$null;$script:ProgressActive=$false
    $script:ProgressPercent=0;$script:LifecycleStage='WSL launch';$script:InstallerLogPath=Join-Path $directory 'fixture.log'
    $script:OperationMessage='Waiting for fixture';$script:OperationOutcome='Running';$script:LifecycleEffects=@();$script:LifecycleComponents=@()
    $script:NativeTimeoutSeconds=10;$script:NativeStallSeconds=10
    $script:Pulses=0;$script:Logs=New-Object 'Collections.Generic.List[string]'
}
function Test-Case([string]$Name,[scriptblock]$Body){
    $caseClock=[Diagnostics.Stopwatch]::StartNew()
    try{& $Body;$results.Add(@{Name=$Name;Passed=$true;elapsedMilliseconds=$caseClock.ElapsedMilliseconds});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message;elapsedMilliseconds=$caseClock.ElapsedMilliseconds});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
    finally{
        # Test emergency cleanup is limited to this fixture's exact PID/start/path.
        foreach($started in @(Get-Starts)){
            $process=Get-Process -Id $started.processId -ErrorAction SilentlyContinue
            if($process -and $process.StartTime.ToUniversalTime() -eq [datetime]$started.startedUtc -and $process.Path -ieq $fixture){$process.Kill();[void]$process.WaitForExit(5000)}
        }
    }
}
$mocks={
    function Initialize-LifecycleProtocol { }
    function Update-SuiteProgressPulse {$script:Pulses++}
    function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
}
try{
    foreach($mode in @('success','failure')){
        Test-Case "Actual CLI $mode retains normalized output, exit and arguments" {
            . $core;. $wsl;. $mocks
            Reset-Fixture $mode $mode
            $probe=Get-WslDistroLaunchProbe 'Fixture Distro' -TimeoutSeconds 2
            $starts=@(Get-Starts)
            Assert-True ($starts.Count -eq 1 -and $starts[0].file -ieq $fixture -and ($starts[0].arguments -join '|') -ceq '-d|Fixture Distro|-u|root|--cd|/|--|true') 'Probe command/ownership changed.'
            Assert-True ($probe.Success -eq ($mode -eq 'success') -and -not $probe.TimedOut -and $probe.ExitCode -eq $(if($mode -eq 'success'){0}else{23})) 'Exit code and timeout were conflated.'
            Assert-True ($probe.Output.Count -eq 2 -and $probe.Output -contains 'launch detail' -and $probe.Output -contains 'diagnostic detail') 'Native stdout/stderr normalization failed.'
            Assert-True ($script:Pulses -gt 0 -and -not $script:LifecycleErrorCode) 'Progress or successful error state regressed.'
            Assert-ProcessesStopped
        }
    }
    foreach($mode in @('silent','chatty-hang')){
        Test-Case "Actual $mode CLI is stopped on its deadline with distinct timeout" {
            . $core;. $wsl;. $mocks
            Reset-Fixture $mode $mode
            $script:LifecycleErrorCode='prior-diagnostic'
            $elapsed=[Diagnostics.Stopwatch]::StartNew()
            $probe=Get-WslDistroLaunchProbe 'Fixture' -TimeoutSeconds 0.8
            Assert-True ($elapsed.Elapsed.TotalSeconds -lt 3 -and -not $probe.Success -and $probe.TimedOut -and $null -eq $probe.ExitCode) 'A hung probe escaped its deadline or became a native exit.'
            Assert-True (@(Get-Starts).Count -eq 1 -and $script:Pulses -ge 3) 'Real child or heartbeat loop was not exercised.'
            Assert-True ($script:LifecycleErrorCode -eq 'prior-diagnostic' -and -not $script:LifecycleRecoveryRequired) 'A transient read-only timeout polluted operation state.'
            if($mode -eq 'chatty-hang'){Assert-True ($probe.Output -contains 'still starting') 'Pre-timeout native output was lost.'}
            Assert-ProcessesStopped
        }
    }
    Test-Case 'Ready wrapper can recover after a stopped timeout without a stale operation error' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'recover' 'silent'
        $probe=$null
        Assert-True (-not(Test-WslDistroReady 'Fixture' -TimeoutSeconds 0.6 -ProbeResult ([ref]$probe)) -and $probe.TimedOut) 'Wrapper missed timeout.'
        $env:KILOVIEW_READINESS_MODE='success'
        Assert-True (Test-WslDistroReady 'Fixture' -TimeoutSeconds 2 -ProbeResult ([ref]$probe)) 'Healthy retry did not recover.'
        Assert-True (-not $probe.TimedOut -and -not $script:LifecycleErrorCode -and @(Get-Starts).Count -eq 2) 'Retry retained stale timeout state.'
        Assert-ProcessesStopped
    }
    Test-Case 'Owned timeout cleanup leaves a separate same-named fixture running' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'scoped-cleanup' 'silent'
        $otherDirectory=Join-Path $testRoot 'separate-process';New-Item -ItemType Directory -Path $otherDirectory|Out-Null
        $start=[Diagnostics.ProcessStartInfo]::new($fixture)
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $start.EnvironmentVariables['KILOVIEW_READINESS_DIRECTORY']=$otherDirectory
        $start.EnvironmentVariables['KILOVIEW_READINESS_MODE']='silent'
        $other=[Diagnostics.Process]::Start($start)
        try{
            $probe=Get-WslDistroLaunchProbe 'Fixture' -TimeoutSeconds 0.8
            Assert-True ($probe.TimedOut -and -not $other.HasExited) 'Cleanup affected another process with the same name.'
            Assert-ProcessesStopped
        }finally{if(-not $other.HasExited){$other.Kill();[void]$other.WaitForExit(5000)};$other.Dispose()}
    }
    Test-Case 'Readiness wait returns the actual successful result without another retry' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'wait-success'
        $last=$null;$elapsed=[Diagnostics.Stopwatch]::StartNew()
        Assert-True (Wait-WslDistroReady 'Fixture' -TimeoutSeconds 2 -LastProbe ([ref]$last)) 'Successful CLI did not complete the wait.'
        Assert-True ($last.Success -and $last.ExitCode -eq 0 -and -not $last.TimedOut -and @(Get-Starts).Count -eq 1 -and $elapsed.Elapsed.TotalSeconds -lt 2) 'Success used the full wait budget or lost the observed result.'
        Assert-ProcessesStopped
    }
    Test-Case 'Retry and silent second launch share one remaining wait budget' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'remaining-budget' 'fail-then-hang'
        $last=$null;$elapsed=[Diagnostics.Stopwatch]::StartNew()
        $ready=Wait-WslDistroReady 'Fixture' -TimeoutSeconds 4.3 -LastProbe ([ref]$last)
        Assert-True (-not $ready -and $last.TimedOut -and $null -eq $last.ExitCode) 'Wait lost the last timeout result.'
        Assert-True ($elapsed.Elapsed.TotalSeconds -ge 4.2 -and $elapsed.Elapsed.TotalSeconds -lt 5.8) ('Wait reset its budget: '+$elapsed.Elapsed.TotalSeconds)
        Assert-True (@(Get-Starts).Count -eq 2 -and $script:Pulses -ge 10) 'Retry budget/progress path was not exercised.'
        Assert-ProcessesStopped
    }
    Test-Case 'Repeated failure retains the last real exit without a post-deadline diagnostic' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'last-failure' 'failure'
        $last=$null;$elapsed=[Diagnostics.Stopwatch]::StartNew()
        Assert-True (-not(Wait-WslDistroReady 'Fixture' -TimeoutSeconds 0.9 -LastProbe ([ref]$last))) 'Nonzero CLI became ready.'
        Assert-True ($elapsed.Elapsed.TotalSeconds -lt 2 -and $last.ExitCode -eq 23 -and -not $last.TimedOut -and $last.Output -contains 'diagnostic detail') 'Final exit/output was replaced by a synthetic timeout.'
        Assert-True (@(Get-Starts).Count -eq 1) 'A diagnostic process started after the deadline.'
        Assert-ProcessesStopped
    }
    Test-Case 'Expired budget starts no probe and replaces a stale last result' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'expired'
        $last=[pscustomobject]@{Success=$true;Output=@('stale')}
        Assert-True (-not(Wait-WslDistroReady 'Fixture' -TimeoutSeconds 0 -LastProbe ([ref]$last))) 'Expired wait succeeded.'
        $probe=Get-WslDistroLaunchProbe 'Fixture' -TimeoutSeconds 0
        Assert-True ($last.TimedOut -and $probe.TimedOut -and @(Get-Starts).Count -eq 0 -and $script:Pulses -eq 0) 'Expired budget started native work or reused old success.'
    }
    Test-Case 'Actual heartbeat persistence failure stops the owned CLI and preserves its cause' {
        . $core;. $wsl;. $lifecycleFunctions
        function Initialize-LifecycleProtocol { }
        function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
        Reset-Fixture 'persistence' 'silent'
        $operation=Join-Path $env:KILOVIEW_READINESS_DIRECTORY ([guid]::NewGuid().ToString('D'))
        New-Item -ItemType Directory -Path $operation|Out-Null
        $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
        foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
        Set-Acl -LiteralPath $operation -AclObject $acl
        $requestPath=Join-Path $operation 'request.json'
        $request=@{schemaVersion=1;operationId=[IO.Path]::GetFileName($operation);productId='environment';action='install';resultPath=(Join-Path $operation 'result.json');role='server';preserveData=$true}
        [IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
        $script:Lifecycle=[KiloLink.Lifecycle.Request]::Load($requestPath)
        $script:Lifecycle.Write('running','Before fixture','WSL launch','','','{}')
        $beforeHash=(Get-FileHash -LiteralPath $script:Lifecycle.ResultPath).Hash
        [IO.File]::SetAttributes($script:Lifecycle.ResultPath,[IO.FileAttributes]::ReadOnly)
        $script:LifecycleLastHeartbeat=[datetime]::UtcNow.AddSeconds(-4.3)
        $failure=$null;$elapsed=[Diagnostics.Stopwatch]::StartNew()
        try{try{Get-WslDistroLaunchProbe 'Fixture' -TimeoutSeconds 4|Out-Null}catch{$failure=$_.Exception.Message}}
        finally{[IO.File]::SetAttributes($script:Lifecycle.ResultPath,[IO.FileAttributes]::Normal)}
        Assert-True ($failure -match 'Result persistence failed' -and $script:LifecycleErrorCode -eq 'lifecycle-result-write-failed') 'Actual atomic-write failure became a retryable launch failure/timeout.'
        Assert-True ((Get-FileHash -LiteralPath $script:Lifecycle.ResultPath).Hash -eq $beforeHash) 'Failed heartbeat changed the prior correlated result.'
        Assert-True ($elapsed.Elapsed.TotalSeconds -lt 3 -and @(Get-Starts).Count -eq 1) 'Persistence failure did not stop promptly after starting the fixture.'
        Assert-ProcessesStopped
    }
    Test-Case 'Non-native TimeoutException from progress propagates and cleans up' {
        . $core;. $wsl;. $mocks
        Reset-Fixture 'producer-timeout' 'silent'
        function Update-SuiteProgressPulse {if(@(Get-Starts).Count){throw [TimeoutException]::new('Progress storage timeout')};$script:Pulses++}
        $failure=$null
        try{Get-WslDistroLaunchProbe 'Fixture' -TimeoutSeconds 3|Out-Null}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'Progress storage timeout' -and @(Get-Starts).Count -eq 1) 'A producer timeout became an ordinary probe timeout.'
        Assert-ProcessesStopped
    }
    foreach($phase in @('initial-launch','final-readiness')){
        Test-Case "Ensure-Ubuntu $phase failure uses the wait result without another CLI" {
            . $core;. $wsl;. $linux;. $mocks
            Reset-Fixture $phase $(if($phase -eq 'initial-launch'){'failure'}else{'success'})
            function Get-UbuntuDistro {'Fixture'}
            function Save-Config { }
            function Write-Step { }
            function Set-SuiteProgress { }
            function Get-WslDistroVersion {2}
            function Wait-WslDistroReady {param($Distro,$TimeoutSeconds,[ref]$LastProbe);$LastProbe.Value=[pscustomobject]@{Success=$false;ExitCode=$null;TimedOut=$true;Output=@('retained wait diagnostic')};$false}
            $failure=$null
            try{Ensure-Ubuntu ([pscustomobject]@{DistroName='Fixture'})|Out-Null}catch{$failure=$_.Exception.Message}
            Assert-True ($failure -match 'retained wait diagnostic' -and $failure -match 'time limit' -and $script:LifecycleErrorCode -eq 'wsl-distro-readiness-timeout') 'Caller lost the retained timeout diagnostic.'
            Assert-True (@(Get-Starts).Count -eq 1) 'Caller started an extra final launch probe.'
            Assert-ProcessesStopped
        }
    }
    Test-Case 'Initial timeout with virtualization text remains retryable and can recover' {
        . $core;. $wsl;. $linux;. $mocks
        Reset-Fixture 'timeout-classification'
        function Get-UbuntuDistro {'Fixture'}
        function Save-Config { }
        function Write-Step { }
        function Set-SuiteProgress { }
        function Get-WslDistroVersion {2}
        $script:LaunchCalls=0;$script:WaitCalls=0
        function Get-WslDistroLaunchProbe {$script:LaunchCalls++;[pscustomobject]@{Success=$false;ExitCode=$null;TimedOut=$true;Output=@('nested virtualization is still initializing')}}
        function Wait-WslDistroReady {param($Distro,$TimeoutSeconds,[ref]$LastProbe);$script:WaitCalls++;$LastProbe.Value=[pscustomobject]@{Success=$true;ExitCode=0;TimedOut=$false;Output=@()};$true}
        Assert-True ((Ensure-Ubuntu ([pscustomobject]@{DistroName='Fixture'})) -eq 'Fixture') 'Timeout output was mistaken for a definitive virtualization failure.'
        Assert-True ($script:LaunchCalls -eq 1 -and $script:WaitCalls -eq 2 -and -not $script:LifecycleErrorCode) 'Successful recovery retained a transient failure or repeated the standalone probe.'
    }
    Test-Case 'Systemd restart failure uses retained diagnostics without any launch after the wait' {
        . $core;. $wsl;. $linux;. $mocks
        Reset-Fixture 'systemd'
        function Write-Step { }
        function Set-SuiteProgress { }
        function Invoke-WslScript {'KILOLINK_SYSTEMD_RESTART_REQUIRED'}
        $script:Terminations=0
        function Invoke-Native {param($FilePath,$Arguments);Assert-True (($Arguments -join '|') -ceq '--terminate|Fixture') 'Unexpected mutation.';$script:Terminations++}
        function Wait-WslDistroReady {param($Distro,$TimeoutSeconds,[ref]$LastProbe);$LastProbe.Value=[pscustomobject]@{Success=$false;ExitCode=23;TimedOut=$false;Output=@('retained systemd diagnostic')};$false}
        $failure=$null
        try{Ensure-Docker 'Fixture'}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'did not restart with systemd' -and $failure -match 'retained systemd diagnostic' -and $script:Terminations -eq 1) 'Systemd caller lost the wait result.'
        Assert-True (@(Get-Starts).Count -eq 0) 'Systemd failure launched a diagnostic after the wait.'
    }
}finally{$env:PATH=$priorPath;$env:KILOVIEW_READINESS_MODE=$priorMode;$env:KILOVIEW_READINESS_DIRECTORY=$priorDirectory}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} WSL readiness checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
exit 0
