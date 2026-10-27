#Requires -Version 5.1
# Current-source tests only; no generated engine, frozen package or live state changes.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-persistence-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object Collections.Generic.List[object]
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'launcher\LifecycleProtocol.cs'))) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public sealed class LifecycleTestReader : IDisposable {
    private FileStream stream;
    private Timer timer;
    public LifecycleTestReader(string path,int releaseAfterMs,bool shareDelete) {
        stream=new FileStream(path,FileMode.Open,FileAccess.Read,shareDelete?FileShare.ReadWrite|FileShare.Delete:FileShare.Read);
        if(releaseAfterMs>0){timer=new Timer(delegate{Dispose();},null,releaseAfterMs,Timeout.Infinite);}
    }
    public void Dispose(){FileStream value=Interlocked.Exchange(ref stream,null);if(value!=null){value.Dispose();}Timer tick=Interlocked.Exchange(ref timer,null);if(tick!=null){tick.Dispose();}}
}
'@
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function New-Request {
    $directory=Join-Path $testRoot ([guid]::NewGuid().ToString('D'))
    New-Item -ItemType Directory -Path $directory|Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    Set-Acl -LiteralPath $directory -AclObject $acl
    $path=Join-Path $directory 'request.json'
    $data=@{schemaVersion=1;operationId=[IO.Path]::GetFileName($directory);productId='environment';action='install';resultPath=(Join-Path $directory 'result.json');role='client';preserveData=$true}
    [IO.File]::WriteAllText($path,($data|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [KiloLink.Lifecycle.Request]::Load($path)
}
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
}
Test-Case 'Transient no-delete-sharing reader permits a later atomic partial result' {
    $request=New-Request
    $request.Write('running','Before cancellation','PC Agent','','','{}')
    $reader=[LifecycleTestReader]::new($request.ResultPath,450,$false)
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    try{$request.Write('partial','Agent cancelled; NDI retained','PC Agent','pc-agent-incomplete','Run Client setup again.','{"partialEffects":["NDI retained"]}')}finally{$reader.Dispose()}
    $result=$request.ReadResult()
    Assert-True ($elapsed.ElapsedMilliseconds -ge 250 -and $elapsed.ElapsedMilliseconds -lt 5000) 'Transient lock was not retried within its deadline.'
    Assert-True ($result.outcome -eq 'partial' -and $result.operationId -eq $request.OperationId -and $result.errorCode -eq 'pc-agent-incomplete' -and $result.partialEffects[0] -eq 'NDI retained') 'Cancellation/effect evidence was lost.'
    Assert-True (@(Get-ChildItem -LiteralPath $request.DirectoryPath -Filter '*.tmp').Count -eq 0) 'Atomic result temporary file leaked.'
}
Test-Case 'Delete-sharing result reader does not delay an atomic replacement' {
    $request=New-Request;$request.Write('running','Old snapshot','','','','{}')
    $reader=[LifecycleTestReader]::new($request.ResultPath,0,$true)
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    try{$request.Write('cancelled','New snapshot','','','','{}')}finally{$reader.Dispose()}
    Assert-True ($elapsed.ElapsedMilliseconds -lt 1000 -and $request.ReadResult().outcome -eq 'cancelled') 'Cooperative reader blocked atomic replacement.'
}
Test-Case 'Persistent sharing conflict times out, retains the previous result and permits later retry' {
    $request=New-Request;$request.Write('running','Still verifiable','','','','{}')
    $before=(Get-FileHash -LiteralPath $request.ResultPath).Hash
    $reader=[LifecycleTestReader]::new($request.ResultPath,0,$false)
    $elapsed=[Diagnostics.Stopwatch]::StartNew();$failure=$null
    try{try{$request.Write('partial','Agent cancelled','','pc-agent-incomplete','Retry Client','{}')}catch{$failure=$_.Exception.Message}}
    finally{$reader.Dispose()}
    Assert-True ($failure -match 'five seconds|previous file was retained' -and $elapsed.ElapsedMilliseconds -ge 4900 -and $elapsed.ElapsedMilliseconds -lt 8000) 'Persistent contention was hidden or unbounded.'
    Assert-True ((Get-FileHash -LiteralPath $request.ResultPath).Hash -eq $before) 'Persistent contention corrupted/deleted the last result.'
    Assert-True (@(Get-ChildItem -LiteralPath $request.DirectoryPath -Filter '*.tmp').Count -eq 0) 'Failed write leaked its stage file.'
    $request.Write('partial','Agent cancelled','','pc-agent-incomplete','Retry Client','{}')
    Assert-True ($request.ReadResult().outcome -eq 'partial') 'Retry after releasing the reader failed.'
}
Test-Case 'Nontransient read-only destination fails promptly and preserves content' {
    $request=New-Request;$request.Write('running','Old','','','','{}')
    $before=(Get-FileHash -LiteralPath $request.ResultPath).Hash
    [IO.File]::SetAttributes($request.ResultPath,[IO.FileAttributes]::ReadOnly)
    $elapsed=[Diagnostics.Stopwatch]::StartNew();$failure=$null
    try{try{$request.Write('succeeded','Must fail','','','','{}')}catch{$failure=$_.Exception.Message}}
    finally{[IO.File]::SetAttributes($request.ResultPath,[IO.FileAttributes]::Normal)}
    Assert-True ($failure -and $elapsed.ElapsedMilliseconds -lt 1000) 'Permanent permission failure was retried or hidden.'
    Assert-True ((Get-FileHash -LiteralPath $request.ResultPath).Hash -eq $before) 'Permission failure changed the existing result.'
}
Test-Case 'Atomic retry revalidates the destination before a second replacement attempt' {
    $request=New-Request;$request.Write('running','Old','','','','{}')
    $temporary=Join-Path $request.DirectoryPath 'retry.tmp';[IO.File]::WriteAllText($temporary,'replacement')
    $reader=[LifecycleTestReader]::new($request.ResultPath,0,$false)
    $script:ValidationCount=0;$failure=$null
    try{try{[KiloLink.Lifecycle.AtomicFile]::Commit($temporary,$request.ResultPath,[Action]{$script:ValidationCount++;if($script:ValidationCount -gt 1){throw 'Validation changed; reject retry'}})}catch{$failure=$_.Exception.Message}}
    finally{$reader.Dispose();Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue}
    Assert-True ($script:ValidationCount -eq 2 -and $failure -match 'Validation changed') 'Retry bypassed validation.'
    Assert-True ($request.ReadResult().outcome -eq 'running') 'Rejected retry replaced the old result.'
}
# Import declarations from the frozen engine for its initialized constants, then
# replace all affected functions with current source. No entry point runs.
$tokens=$null;$errors=$null
$engineAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Install-KiloLinkSuite.ps1'),[ref]$tokens,[ref]$errors)
$declarations=@();$entryFound=$false
foreach($statement in $engineAst.EndBlock.Statements){if($statement.Extent.Text -eq 'Ensure-Administrator'){$entryFound=$true;break};$declarations+=$statement.Extent.Text}
Assert-True $entryFound 'Could not isolate engine declarations.'
$engine=[scriptblock]::Create($declarations -join "`n")
$overrides=@()
foreach($name in @('10-Core.ps1','12-Lifecycle.ps1','15-DeploymentModel.ps1','60-Ownership.ps1')){
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('src\Provisioner\'+$name)),[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Current source failed to parse.'
    $overrides+=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})
}
$current=[scriptblock]::Create($overrides -join "`n")
Test-Case 'Running preflight heartbeat never reverts to the idle no-operation message' {
    . $engine;. $current
    $request=New-Request;$LifecycleRequestPath=$request.RequestPath
    $Action='InstallClient';$Role='client';$PurgeData=$false;$ConfirmRemoval=$false
    $script:StateRoot=Join-Path $request.DirectoryPath 'state'
    $script:InstallerLogPath=Join-Path $script:StateRoot 'installer.log'
    function Write-LauncherEvent { }
    Initialize-Lifecycle
    $initial=$script:Lifecycle.ReadResult()
    Assert-True ($initial.outcome -eq 'running' -and $initial.stage -eq 'preflight') 'Preflight did not publish its running state.'
    $script:LifecycleLastHeartbeat=[datetime]::UtcNow.AddSeconds(-6)
    Update-SuiteProgressPulse
    $heartbeat=$script:Lifecycle.ReadResult()
    Assert-True ($heartbeat.outcome -eq 'running' -and $heartbeat.stage -eq 'preflight' -and $heartbeat.message -eq 'Checking requirements.') 'Running heartbeat reverted to an idle/completion message.'
    Assert-True ($heartbeat.operationId -eq $request.OperationId -and -not $heartbeat.safeToCancel -and $heartbeat.partialEffects.Count -eq 0) 'Status-text correction changed request correlation, cancellation or effect semantics.'
}
foreach($terminal in @(@{Outcome='NoChange';Expected='no-change';Message='Already current.';Exit=0},@{Outcome='Cancelled';Expected='cancelled';Message='Setup cancelled before changes.';Exit=1602})){
    Test-Case "Preflight text preserves $($terminal.Expected) terminal meaning" {
        . $engine;. $current
        $request=New-Request;$LifecycleRequestPath=$request.RequestPath
        $Action='InstallClient';$Role='client';$PurgeData=$false;$ConfirmRemoval=$false
        $script:StateRoot=Join-Path $request.DirectoryPath 'state'
        $script:InstallerLogPath=Join-Path $script:StateRoot 'installer.log'
        function Write-LauncherEvent { }
        function Get-ObservedComponents { @() }
        Initialize-Lifecycle
        Set-OperationOutcome $terminal.Outcome $terminal.Message
        $result=$script:Lifecycle.ReadResult()
        Assert-True ($result.outcome -eq $terminal.Expected -and $result.message -eq $terminal.Message -and (Get-InstallerExitCode) -eq $terminal.Exit) 'Preflight text replaced a terminal outcome/message/exit code.'
    }
}
$entryAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\Provisioner\99-Entry.ps1'),[ref]$tokens,[ref]$errors)
$outerTry=@($entryAst.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.TryStatementAst]})[0]
$entryCatch=[scriptblock]::Create(($outerTry.CatchClauses[0].Body.Statements|ForEach-Object{$_.Extent.Text}) -join "`n")
foreach($mode in @('transient','persistent')){
    Test-Case "Actual Client Agent cancellation retains its meaning through $mode result contention" {
        . $engine;. $current
        $LauncherMode=$true;$AcceptLicenses=$true;$Action='InstallClient';$backgroundExitCode=0
        $script:Lifecycle=New-Request
        $script:StateRoot=Join-Path $script:Lifecycle.DirectoryPath 'state'
        $script:InstallerLogPath=Join-Path $script:StateRoot 'installer.log'
        $script:FinalReader=$null
        function Write-LauncherEvent { }
        function Get-ObservedComponents {@([pscustomobject]@{productId='ndi-tools';installed=$true},[pscustomobject]@{productId='pc-agent';installed=$false})}
        function Prepare-ClientPackages { }
        function Save-ComponentReceipt { }
        function Install-NdiTools {$script:NdiRestartRequired=$false;Add-LifecycleEffect 'NDI Tools installation verified; retained.'}
        function Install-PcAgent {$script:FinalReader=[LifecycleTestReader]::new($script:Lifecycle.ResultPath,$(if($mode -eq 'transient'){450}else{0}),$false);$false}
        $failure=$null
        try{try{Install-ClientTools}catch{$failure=$_.Exception.Message;. $entryCatch}}
        finally{if($script:FinalReader){$script:FinalReader.Dispose()}}
        $journal=Get-Content -LiteralPath (Join-Path $script:StateRoot 'last-operation.json') -Raw -Encoding UTF8|ConvertFrom-Json
        Assert-True ($journal.outcome -eq 'Cancelled' -and @($journal.steps|Where-Object name -eq 'PC Agent')[0].state -eq 'Incomplete') 'Cancellation was labelled a successful Agent step or changed into Agent failure.'
        if($mode -eq 'transient'){
            $result=$script:Lifecycle.ReadResult()
            Assert-True (-not $failure -and $result.outcome -eq 'partial' -and $result.errorCode -eq 'pc-agent-incomplete' -and $result.nextAction -match 'Client setup' -and (Get-InstallerExitCode) -eq 1) 'Transient polling obscured partial cancellation/retry guidance.'
            Assert-True ($result.partialEffects.Count -eq 1) 'Installed NDI evidence was lost.'
        }else{
            Assert-True ($failure -match "Could not save lifecycle outcome 'partial'.*PC Agent setup was not completed" -and $backgroundExitCode -eq 1) 'Persistent storage failure was masked or misattributed.'
            Assert-True ($journal.resultWriteFailure.operationOutcome -eq 'Cancelled' -and $journal.resultWriteFailure.originalErrorCode -eq 'pc-agent-incomplete' -and $journal.resultWriteFailure.nextAction -match 'journal') 'Durable failure record lost the original cancellation.'
            Assert-True ($script:Lifecycle.ReadResult().outcome -eq 'running') 'Unsaved terminal outcome was claimed as durable.'
        }
    }
}
Test-Case 'Polled owner journal also retries transient atomic replacement contention' {
    . $engine;. $current
    $request=New-Request;$path=Join-Path $request.DirectoryPath 'journal.json'
    Write-StateJson $path @{outcome='Running'}
    $reader=[LifecycleTestReader]::new($path,300,$false)
    try{Write-StateJson $path @{outcome='Cancelled'}}finally{$reader.Dispose()}
    Assert-True ((Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).outcome -eq 'Cancelled') 'Journal contention lost the terminal state.'
}
$passed=@($results|Where-Object{$_.Passed}).Count
Write-Output "$passed/$($results.Count) persistence checks passed. Evidence: $testRoot"
if($passed -ne $results.Count){exit 1}
