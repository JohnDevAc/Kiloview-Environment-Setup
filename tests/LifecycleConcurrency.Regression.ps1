#Requires -Version 5.1
# Independent native writers/readers and abandoned-lock recovery, confined to temp files.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-concurrency-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object Collections.Generic.List[object]
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}}
$exe=Join-Path $testRoot 'ConcurrencyFixture.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ("/out:$exe") (Join-Path $root 'launcher\LifecycleProtocol.cs') (Join-Path $PSScriptRoot 'LifecycleConcurrency.Fixture.cs')
Assert-True ($LASTEXITCODE -eq 0) 'Concurrency fixture did not compile.'
[void][Reflection.Assembly]::LoadFile($exe)
function New-Request {
    param([string]$Suffix='')
    $operationId=[guid]::NewGuid().ToString('D')
    $directory=Join-Path $testRoot ($operationId+$Suffix);New-Item -ItemType Directory -Path $directory|Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    Set-Acl -LiteralPath $directory -AclObject $acl
    $requestPath=Join-Path $directory 'request.json'
    [IO.File]::WriteAllText($requestPath,(@{schemaVersion=1;operationId=$operationId;productId='environment';action='install';resultPath=(Join-Path $directory 'result.json')}|ConvertTo-Json))
    $request=[KiloLink.Lifecycle.Request]::Load($requestPath);$request.Write('running','Original complete snapshot','','','','{}');return $request
}
function Start-Actor([string]$Mode,$Request,[string]$Name){
    $report=Join-Path $Request.DirectoryPath ($Name+'.json')
    $process=Start-Process -FilePath $exe -ArgumentList ('"'+$Mode+'" "'+$Request.RequestPath+'" "'+$report+'"') -WindowStyle Hidden -PassThru
    [pscustomobject]@{Process=$process;Report=$report}
}
function Wait-Ready($Actor){$deadline=[datetime]::UtcNow.AddSeconds(5);while(-not(Test-Path -LiteralPath ($Actor.Report+'.ready')) -and [datetime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 10};Assert-True (Test-Path -LiteralPath ($Actor.Report+'.ready')) 'Writer did not acquire fixture gate.'}
Test-Case 'Four native writers and three cooperative readers retain complete correlated snapshots' {
    $request=New-Request;$readers=@();$writers=@()
    try {
        foreach($mode in @('reader','poller','poller')){$readers+=Start-Actor $mode $request ('reader-'+$readers.Count)}
        foreach($index in 1..4){$writers+=Start-Actor 'writer' $request ('writer-'+$index)}
        foreach($actor in $writers){Assert-True ($actor.Process.WaitForExit(25000) -and $actor.Process.ExitCode -eq 0) ('Concurrent writer failed: '+$actor.Report)}
        $request.Write('failed','Original metadata failure','ndi-metadata','ndi-metadata-unavailable','Check vendor access','{"partialEffects":["Fixture evidence retained"]}')
        Start-Sleep -Milliseconds 100
    } finally {
        [IO.File]::WriteAllText((Join-Path $request.DirectoryPath 'stop.signal'),'stop owned readers')
        foreach($actor in @($writers)+@($readers)){Assert-True ($actor.Process.WaitForExit(30000)) 'Owned fixture process did not exit';$actor.Process.Dispose()}
    }
    foreach($actor in @($writers)+@($readers)){$report=Get-Content -LiteralPath $actor.Report -Raw|ConvertFrom-Json;Assert-True ($report.errors.Count -eq 0 -and $report.count -gt 0) ('Incomplete snapshot or actor failure: '+$actor.Report)}
    $final=$request.ReadResult();Assert-True ($final.outcome -eq 'failed' -and $final.errorCode -eq 'ndi-metadata-unavailable' -and $final.partialEffects[0] -eq 'Fixture evidence retained') 'Original terminal cause was lost.'
    Assert-True (@(Get-ChildItem -LiteralPath $request.DirectoryPath -Filter '*.tmp').Count -eq 0) 'Staged file leaked.'
}
foreach($mode in @('hold','timeout','abandon')){
    Test-Case "Writer gate has bounded ownership and recovery: $mode" {
        $request=New-Request;$actor=Start-Actor $mode $request $mode;Wait-Ready $actor
        $watch=[Diagnostics.Stopwatch]::StartNew();$failure=$null
        try {try{$request.Write('failed','New terminal snapshot','preflight','fixture-code','','{}')}catch{$failure=$_.Exception.Message}}
        finally {Assert-True ($actor.Process.WaitForExit(10000)) 'Gate owner did not exit';$actor.Process.Dispose()}
        if($mode -eq 'timeout'){
            Assert-True ($failure -match 'Another writer.*five seconds' -and $watch.Elapsed.TotalSeconds -lt 9) 'Gate contention was hidden or unbounded.'
            Assert-True ($request.ReadResult().outcome -eq 'running') 'Timed-out writer changed the prior result.'
            $request.Write('failed','Retry after owner exit','preflight','fixture-code','','{}')
        }else{Assert-True (-not $failure) $failure}
        Assert-True ($request.ReadResult().errorCode -eq 'fixture-code') 'Write after gate release/abandonment failed.'
    }
}
Test-Case 'Same-directory rename preserves a stricter result access ACL' {
    $request=New-Request
    $security=[IO.File]::GetAccessControl($request.ResultPath)
    $security.SetAccessRuleProtection($true,$true)
    [IO.File]::SetAccessControl($request.ResultPath,$security)
    $before=[IO.File]::GetAccessControl($request.ResultPath).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    $request.Write('failed','Preserve protected access rules','','','','{}')
    $after=[IO.File]::GetAccessControl($request.ResultPath).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    Assert-True ($before -eq $after) 'Replacement weakened or changed the result access ACL.'
}
Test-Case 'Atomic replacement rejects staged files outside the target directory' {
    $request=New-Request;$staged=Join-Path $testRoot 'foreign-stage.tmp';[IO.File]::WriteAllText($staged,'wrong directory')
    $failure=$null;try{[KiloLink.Lifecycle.AtomicFile]::Commit($staged,$request.ResultPath,$null)}catch{$failure=$_.Exception.Message}
    Assert-True ($failure -match 'destination directory' -and $request.ReadResult().outcome -eq 'running' -and (Test-Path -LiteralPath $staged)) 'Cross-directory commit changed files.'
}
Test-Case 'Native rename preserves Unicode paths and repeated result correlation' {
    $request=New-Request (' space '+[char]0xE9+[char]0x65E5+[char]0xD83D+[char]0xDE80)
    foreach($index in 1..25){$request.Write('running',('Unicode snapshot '+$index),'fixture','','','{}')}
    $result=$request.ReadResult()
    Assert-True ($result.operationId -eq $request.OperationId -and $result.message -eq 'Unicode snapshot 25') 'Unicode replacement changed the filename or correlation.'
    Assert-True (@(Get-ChildItem -LiteralPath $request.DirectoryPath -File).Count -eq 2) 'Unicode rename left an unexpected file.'
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} concurrency checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
