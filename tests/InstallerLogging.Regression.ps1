#Requires -Version 5.1
# Real file sharing, transcript and harmless native ownership tests. No WSL/install.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run installer logging tests with Windows PowerShell 5.1.'}
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-installer-logging-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Import-Functions([string]$Path){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) ('Invalid source '+$Path)
    [scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object {$_.Extent.Text})) -join "`n")
}
$core=Import-Functions (Join-Path $root 'src\Provisioner\10-Core.ps1')
$lifecycleFunctions=Import-Functions (Join-Path $root 'src\Provisioner\12-Lifecycle.ps1')
$stateFunctions=Import-Functions (Join-Path $root 'src\Provisioner\15-DeploymentModel.ps1')
Add-Type -Path (Join-Path $root 'launcher\LifecycleProtocol.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$fixture=Join-Path $testRoot 'harmless-maintenance.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ("/out:$fixture") (Join-Path $PSScriptRoot 'InstallerLogging.Fixture.cs')
Assert-True ($LASTEXITCODE -eq 0) 'Fixture compile failed.'
[void][Reflection.Assembly]::LoadFile($fixture)
function Reset-Fixture([string]$Name){
    $script:StateRoot=Join-Path $testRoot $Name;New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
    $script:InstallerLogPath=Join-Path $script:StateRoot 'installer.log'
    [IO.File]::WriteAllText($script:InstallerLogPath,"existing line`r`n",[Text.UTF8Encoding]::new($true))
    $script:InstallerLogFailure=$null;$script:Lifecycle=$null;$script:ActiveJournal=$null;$script:ProgressActive=$false
    $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:LifecycleRecoveryRequired=$false
    $script:NativeTimeoutSeconds=10;$script:NativeStallSeconds=10
    $script:LifecycleStage='Linux runtime updates';$script:OperationMessage='Fixture maintenance';$script:LifecycleEffects=@();$script:LifecycleComponents=@()
    $script:Action='MaintainRuntime'
}
function New-FixtureRequest {
    $directory=Join-Path $script:StateRoot ([guid]::NewGuid().ToString('D'));New-Item -ItemType Directory -Path $directory|Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    Set-Acl -LiteralPath $directory -AclObject $acl
    $path=Join-Path $directory 'request.json'
    [IO.File]::WriteAllText($path,(@{schemaVersion=1;operationId=[IO.Path]::GetFileName($directory);productId='environment';action='maintain-runtime';role='server';preserveData=$true;resultPath=(Join-Path $directory 'result.json')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [KiloLink.Lifecycle.Request]::Load($path)
}
function Test-Case([string]$Name,[scriptblock]$Body){
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try{& $Body;$results.Add(@{Name=$Name;Passed=$true;elapsedMilliseconds=$clock.ElapsedMilliseconds});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message;elapsedMilliseconds=$clock.ElapsedMilliseconds});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
    finally{
        $startedPath=Join-Path $script:StateRoot 'started.json'
        if(Test-Path -LiteralPath $startedPath){
            $started=Get-Content -LiteralPath $startedPath -Raw|ConvertFrom-Json
            $process=Get-Process -Id $started.processId -ErrorAction SilentlyContinue
            # Harmless child ends naturally. A test failure never kills servicing.
            if($process -and $process.Path -ieq $fixture -and $process.StartTime.ToUniversalTime() -eq [datetime]$started.startedUtc){Assert-True ($process.WaitForExit(6000)) 'Harmless fixture failed to end naturally.'}
        }
    }
}
$pulseMock={function Initialize-LifecycleProtocol { };function Update-SuiteProgressPulse { }}
Test-Case 'Cooperative ReadWrite/Delete reader permits exact UTF-8 diagnostic appends' {
    . $core;. $pulseMock
    Reset-Fixture 'cooperative-reader'
    $reader=[InstallerLogReader]::new($script:InstallerLogPath,$true,0)
    try{Write-InstallerLog ("Unicode "+[char]0x65e5+[char]0+" detail");Write-InstallerLog 'second line'}finally{$reader.Dispose()}
    $content=[IO.File]::ReadAllText($script:InstallerLogPath)
    Assert-True ($content.StartsWith("existing line`r`n") -and $content.Contains(('Unicode '+[char]0x65e5+' detail')) -and $content.Contains('second line') -and -not $content.Contains([string][char]0)) 'Reader changed or blocked complete normalized lines.'
    Assert-True (-not $script:InstallerLogFailure) 'A fully cooperative reader triggered fallback.'
}
Test-Case 'Short exclusive reader is retried within the log bound' {
    . $core;. $pulseMock
    Reset-Fixture 'short-lock'
    $reader=[InstallerLogReader]::new($script:InstallerLogPath,$false,120)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    try{Write-InstallerLog 'after temporary lock'}finally{$reader.Dispose()}
    Assert-True ($clock.ElapsedMilliseconds -lt 1000 -and [IO.File]::ReadAllText($script:InstallerLogPath).Contains('after temporary lock') -and -not $script:InstallerLogFailure) 'Transient sharing conflict was not bounded/recovered.'
}
foreach($unavailable in @('locked','read-only')){
    Test-Case "Unavailable $unavailable log cannot mask real native exit or lose fallback diagnostics" {
        . $core;. $pulseMock
        Reset-Fixture $unavailable
        $transcript=Join-Path $script:StateRoot 'fallback-transcript.txt';$reader=$null
        if($unavailable -eq 'locked'){$reader=[InstallerLogReader]::new($script:InstallerLogPath,$false,0)}
        else{[IO.File]::SetAttributes($script:InstallerLogPath,[IO.FileAttributes]::ReadOnly)}
        $failure=$null;$clock=[Diagnostics.Stopwatch]::StartNew()
        Start-Transcript -LiteralPath $transcript|Out-Null
        try{
            try{Invoke-Native $fixture @($script:StateRoot,'failure') -TimeoutSeconds 5 -StallSeconds 5}catch{$failure=$_.Exception.Message}
        }finally{Stop-Transcript|Out-Null;if($reader){$reader.Dispose()};[IO.File]::SetAttributes($script:InstallerLogPath,[IO.FileAttributes]::Normal)}
        Assert-True ($failure -match 'Command failed with exit code 23' -and $failure -match 'native diagnostic' -and $global:LASTEXITCODE -eq 23) 'Logging replaced the real native error.'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 3 -and -not $script:LifecycleRecoveryRequired -and -not(Test-Path (Join-Path $script:StateRoot 'pending-process.json'))) 'Confirmed native exit became unobserved or stalled on diagnostics.'
        $fallback=[IO.File]::ReadAllText($transcript)
        Assert-True ($fallback.Contains('Could not append the diagnostic log') -and $fallback.Contains('native stdout') -and $fallback.Contains('native diagnostic')) 'Unavailable file lost the warning/native output fallback.'
    }
}
Test-Case 'Unavailable log does not abort successful native maintenance' {
    . $core;. $pulseMock
    Reset-Fixture 'successful-maintenance'
    $reader=[InstallerLogReader]::new($script:InstallerLogPath,$false,0)
    try{Invoke-Native $fixture @($script:StateRoot,'success') -TimeoutSeconds 5 -StallSeconds 5}finally{$reader.Dispose()}
    Assert-True ($global:LASTEXITCODE -eq 0 -and -not $script:LifecycleRecoveryRequired -and (Test-Path (Join-Path $script:StateRoot 'completed.txt'))) 'Diagnostic unavailability aborted native success.'
}
Test-Case 'Diagnostic appending recovers during continued output after a persistent lock clears' {
    . $core;. $pulseMock
    Reset-Fixture 'log-recovery'
    $reader=[InstallerLogReader]::new($script:InstallerLogPath,$false,0)
    try{Write-InstallerLog 'fallback before release'}finally{$reader.Dispose()}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.ElapsedMilliseconds -lt 1400){Write-InstallerLog 'continued output';Start-Sleep -Milliseconds 80}
    Write-InstallerLog 'log restored'
    $content=[IO.File]::ReadAllText($script:InstallerLogPath)
    Assert-True ($content.Contains('continued output') -and $content.Contains('log restored')) 'Repeated fallback output postponed retries indefinitely.'
}
foreach($mode in @('producer','persistence','timeout','pending-write-failure')){
    Test-Case "Unobserved mutating CLI retains ownership and original $mode error without termination" {
        . $core;. $stateFunctions;. $lifecycleFunctions
        Reset-Fixture $mode
        $request=$null;$beforeHash=$null
        if($mode -eq 'persistence'){
            $script:Lifecycle=New-FixtureRequest;$request=$script:Lifecycle
            $request.Write('running','Before mutation','Linux runtime updates','','','{}')
            $beforeHash=(Get-FileHash -LiteralPath $request.ResultPath).Hash
            [IO.File]::SetAttributes($request.ResultPath,[IO.FileAttributes]::ReadOnly)
            $script:LifecycleLastHeartbeat=[datetime]::UtcNow.AddSeconds(-4.3)
        }elseif($mode -eq 'timeout'){. $pulseMock}
        else{
            function Update-SuiteProgressPulse {if(Test-Path -LiteralPath (Join-Path $script:StateRoot 'started.json')){throw 'Original producer failure'}}
        }
        if($mode -eq 'pending-write-failure'){
            $script:OriginalStateWriter=(Get-Command Write-StateJson).ScriptBlock
            function Write-StateJson {param($Path,$Value);if([IO.Path]::GetFileName($Path) -eq 'pending-process.json'){throw 'Pending storage unavailable'};& $script:OriginalStateWriter $Path $Value}
            $script:ActiveJournal=[ordered]@{operationId=[guid]::NewGuid().ToString('D');outcome='Running';updatedUtc='';mutationStarted=$true}
        }
        $failure=$null
        try{try{Invoke-Native $fixture @($script:StateRoot,'hold') -TimeoutSeconds $(if($mode -eq 'timeout'){0.5}else{5}) -StallSeconds 5}catch{$failure=$_.Exception.Message}}
        finally{if($request){[IO.File]::SetAttributes($request.ResultPath,[IO.FileAttributes]::Normal)}}
        $started=Get-Content -LiteralPath (Join-Path $script:StateRoot 'started.json') -Raw|ConvertFrom-Json
        $process=Get-Process -Id $started.processId -ErrorAction Stop
        Assert-True (-not $process.HasExited -and $script:LifecycleRecoveryRequired -and $script:LifecycleNextAction -match 'Wait.*Verify') 'The unconfirmed mutating child was killed or released for retry.'
        if($mode -eq 'persistence'){
            Assert-True ($failure -match 'Result persistence failed' -and $script:LifecycleErrorCode -eq 'lifecycle-result-write-failed' -and (Get-FileHash -LiteralPath $request.ResultPath).Hash -eq $beforeHash) 'Persistence cause or prior durable result was lost.'
        }elseif($mode -eq 'timeout'){
            Assert-True ($failure -match 'time limit' -and $script:LifecycleErrorCode -eq 'command-timeout') 'Command deadline lost its cause.'
        }else{
            Assert-True ($failure -eq 'Original producer failure' -and $script:LifecycleErrorCode -eq 'native-command-observation-failed') 'Pending observation replaced the producer cause.'
        }
        if($mode -eq 'pending-write-failure'){
            Assert-True ($script:LifecycleNextAction -match 'Pending storage unavailable') 'Failed ownership persistence was hidden.'
            $script:LauncherMode=$false
            Set-OperationOutcome 'Failed' $failure
            Assert-True (-not(Test-Path (Join-Path $script:StateRoot 'pending-process.json'))) 'Pending-file failure was not exercised.'
            $journal=Get-Content -LiteralPath (Join-Path $script:StateRoot 'last-operation.json') -Raw|ConvertFrom-Json
            Assert-True ($journal.recoveryRequired -and $journal.pendingNativeProcess.processId -eq $started.processId) 'The journal lost fallback ownership.'
            $script:Action='Verify';$blocked=$null
            try{Assert-NoPendingNativeProcess}catch{$blocked=$_.Exception.Message}
            Assert-True ($blocked -match 'still running') 'Missing pending file bypassed journal-owned recovery.'
        }else{
            $pending=Get-Content -LiteralPath (Join-Path $script:StateRoot 'pending-process.json') -Raw|ConvertFrom-Json
            Assert-True ($pending.processId -eq $started.processId -and $pending.startedUtc -eq $started.startedUtc -and $pending.filePath -ieq $fixture -and $pending.action -eq 'MaintainRuntime') 'Durable pending identity differs from the real command.'
            $script:Action='Verify';$blocked=$null
            try{Assert-NoPendingNativeProcess}catch{$blocked=$_.Exception.Message}
            Assert-True ($blocked -match 'still running') 'Verify allowed a still-active mutating command.'
        }
        Assert-True ($process.WaitForExit(6000) -and (Test-Path (Join-Path $script:StateRoot 'completed.txt'))) 'Mutating fixture was terminated instead of completing naturally.'
    }
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} installer logging checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
exit 0
