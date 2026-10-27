#Requires -Version 5.1
# Real continuation cleanup against isolated state and exact-task mocks.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-resume-continuation-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object Collections.Generic.List[object]
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}}
function Import-SourceFunctions([string]$Path){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Source parse failed.'
    [scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})) -join "`n")
}
$core=Import-SourceFunctions (Join-Path $root 'src\Provisioner\10-Core.ps1')
$wsl=Import-SourceFunctions (Join-Path $root 'src\Provisioner\20-Wsl.ps1')
$operations=Import-SourceFunctions (Join-Path $root 'src\Provisioner\90-Operations.ps1')
foreach($mode in @('partial','failed','already-absent','entry-failure','restart-required','completed','running-result','unconfirmed-worker','pending-record','result-write-failure','wrong-operation','wrong-task','remove-failure','remove-unconfirmed','query-failure')){
    Test-Case "Terminal resume continuation ownership: $mode" {
        . $core;. $wsl;. $operations
        $Action='Resume';$LauncherMode=$true
        $script:StateRoot=Join-Path $testRoot $mode;New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
        $script:ResumeStatePath=Join-Path $script:StateRoot 'resume-state.json'
        $script:PersistentLauncherPath=Join-Path $script:StateRoot 'Maintenance\setup.exe'
        $script:ResumeTaskName='KiloLink Suite Installation Resume'
        $requestPath=Join-Path $script:StateRoot 'request.json';$configPath=Join-Path $script:StateRoot 'configuration.json'
        [IO.File]::WriteAllText($requestPath,'Retained original request');[IO.File]::WriteAllText($configPath,'Retained reviewed configuration')
        $requestHash=(Get-FileHash -LiteralPath $requestPath).Hash;$configHash=(Get-FileHash -LiteralPath $configPath).Hash
        $operationId=[guid]::NewGuid().ToString('D')
        $state=[pscustomobject]@{SchemaVersion=1;Attempt=1;Reason='Original feature restart';User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;Action='Setup';OperationId=$operationId;LifecycleRequestPath=$requestPath;ConfigurationPath=$configPath}
        [IO.File]::WriteAllText($script:ResumeStatePath,($state|ConvertTo-Json))
        $script:Lifecycle=[pscustomobject]@{OperationId=$operationId;RequestPath=$requestPath;Attempt=2}
        $script:Lifecycle|Add-Member ScriptMethod ReadResult {return $script:WireResult}
        $script:WireResult=@{outcome=$(if($mode -eq 'failed'){'failed'}else{'partial'});message='Original WSL failure';errorCode='wsl-runtime-install-failed';stage='Windows prerequisites';attempt=2;recoveryRequired=$false}
        $script:OperationOutcome='Failed';$script:OperationMessage='Original WSL failure';$script:OperationFailed=$true
        $script:LifecycleErrorCode='wsl-runtime-install-failed';$script:LifecycleNextAction='Original retry guidance';$script:LifecycleRecoveryRequired=$false
        $script:ProgressActive=$false;$script:ActiveJournal=[ordered]@{outcome='Failed'}
        $script:TaskPresent=$true;$script:RemovalCount=0;$script:QueryCount=0
        # Task Scheduler can return an unqualified username, as seen in QA8.
        $script:FixtureTask=[pscustomobject]@{Actions=@([pscustomobject]@{Execute=$script:PersistentLauncherPath;Arguments=('--resume --lifecycle-request "'+$requestPath+'"')});Principal=[pscustomobject]@{UserId=$env:USERNAME};Settings=[pscustomobject]@{Enabled=$true};State='Ready'}
        function Write-StateJson($Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8))}
        function Write-InstallerLog { }
        function Write-LauncherEvent { }
        function Save-DeploymentJournal { }
        function Get-ObservedComponents { @() }
        function Get-LifecycleResultOutcome($Outcome){if($mode -eq 'failed'){'failed'}else{'partial'}}
        function Write-LifecycleResult($Outcome,$Message){$script:WireResult=@{outcome=$Outcome;message=$Message;errorCode=$script:LifecycleErrorCode;nextAction=$script:LifecycleNextAction;recoveryRequired=$script:LifecycleRecoveryRequired}}
        function Get-ScheduledTask {
            [CmdletBinding()]param($TaskName,$TaskPath)
            Assert-True ($TaskName -eq $script:ResumeTaskName -and $TaskPath -eq '\') 'Cleanup enumerated unrelated scheduled tasks.'
            $script:QueryCount++
            if($mode -eq 'query-failure'){Write-Error 'Fixture task query denied' -Category PermissionDenied;return}
            if($script:TaskPresent){$script:FixtureTask}
        }
        function Unregister-ScheduledTask {
            [CmdletBinding(SupportsShouldProcess=$true)]param($TaskName,$TaskPath)
            Assert-True ($TaskName -eq $script:ResumeTaskName -and $TaskPath -eq '\') 'Cleanup targeted a foreign task.'
            $script:RemovalCount++
            if($mode -eq 'remove-failure'){throw 'Fixture task removal denied'}
            if($mode -ne 'remove-unconfirmed'){$script:TaskPresent=$false}
        }
        switch($mode){
            'already-absent' {$script:TaskPresent=$false}
            'restart-required' {$script:OperationOutcome='RestartRequired';$script:WireResult.outcome='restart-required'}
            'completed' {$script:OperationOutcome='Completed';$script:WireResult.outcome='succeeded'}
            'running-result' {$script:WireResult.outcome='running'}
            'unconfirmed-worker' {$script:LifecycleRecoveryRequired=$true}
            'pending-record' {[IO.File]::WriteAllText((Join-Path $script:StateRoot 'pending-process.json'),'Unconfirmed fixture worker')}
            'result-write-failure' {$script:LifecycleErrorCode='lifecycle-result-write-failed'}
            'wrong-operation' {$state.OperationId=[guid]::NewGuid().ToString('D');Write-StateJson $script:ResumeStatePath $state}
            'wrong-task' {$script:FixtureTask.Actions[0].Arguments='--resume --lifecycle-request "foreign-request.json"'}
        }
        $before=[IO.File]::ReadAllText($script:ResumeStatePath)
        if($mode -eq 'entry-failure'){
            # Execute the real entry-point try/catch/finally, excluding only its
            # final process exit and using a private fixture mutex name.
            $AcceptLicenses=$true;$LogPath='';$PackageRestartContinuation=$false
            function Ensure-Administrator { }
            function Assert-NoPendingNativeProcess { }
            function Start-DeploymentJournal { }
            function Resume-Suite {throw 'Original WSL failure'}
            $entry=[IO.File]::ReadAllText((Join-Path $root 'src\Provisioner\99-Entry.ps1'))
            $boundary=$entry.IndexOf('if ($backgroundExitCode -ne 0)')
            Assert-True ($boundary -gt 0) 'Entry-point exit boundary missing.'
            $entry=$entry.Substring(0,$boundary).Replace('Global\KiloviewProvisioner',('Local\KiloviewResumeFixture-'+[guid]::NewGuid().ToString('N')))
            . ([scriptblock]::Create($entry))
            . $operations
        }else{Complete-FailedResumeContinuation}
        if($mode -in @('partial','failed','already-absent','entry-failure')){
            Assert-True (-not $script:TaskPresent) 'Next logon can replay a confirmed terminal failure.'
            $retained=Get-ResumeState
            Assert-True ($retained.AutomaticContinuationStopped -and $retained.OperationId -eq $operationId -and $retained.Attempt -eq 1 -and $retained.Action -eq 'Setup') 'Original continuation correlation/configuration was erased.'
            Assert-True (-not $script:LifecycleRecoveryRequired -and $script:WireResult.errorCode -eq 'wsl-runtime-install-failed') 'Successful trigger removal hid the original result or invented recovery.'
            # An explicit invocation may still retry the retained reviewed request.
            function Assert-ServerOwner { }
            function Get-SavedConfig {[pscustomobject]@{DistroName='KiloLink-Ubuntu'}}
            function Start-SuiteProgress { }
            function Stop-SuiteProgress { }
            function Wait-ResumeNetwork { }
            $script:ExplicitRetry=$false
            function Repair-Suite {param([switch]$UseSavedConfiguration,[switch]$LicenseAccepted,[switch]$BringCurrent) $script:ExplicitRetry=$UseSavedConfiguration -and $LicenseAccepted -and $BringCurrent -and $Action -eq 'Setup'}
            Resume-Suite
            Assert-True ($script:ExplicitRetry -and -not $script:TaskPresent) 'Explicit retry was blocked or silently rearmed logon replay.'
        }elseif($mode -in @('wrong-operation','wrong-task','remove-failure','remove-unconfirmed','query-failure')){
            Assert-True ($script:TaskPresent -and $script:LifecycleRecoveryRequired -and $script:WireResult.recoveryRequired) 'Unconfirmed continuation removal was presented as safe.'
            Assert-True ($script:WireResult.message -match 'Original WSL failure' -and $script:WireResult.nextAction -match 'before signing in again' -and $script:WireResult.errorCode -eq 'wsl-runtime-install-failed') 'Cleanup failure hid the original cause or omitted recovery guidance.'
            Assert-True ([IO.File]::ReadAllText($script:ResumeStatePath) -ceq $before) 'Unconfirmed cleanup changed original resume state.'
            if($mode -in @('wrong-operation','wrong-task','query-failure')){Assert-True ($script:RemovalCount -eq 0) 'Cleanup attempted removal without ownership evidence.'}
        }else{
            Assert-True ($script:TaskPresent -and $script:RemovalCount -eq 0 -and $script:QueryCount -eq 0) 'Active/unconfirmed/restart-required/success state lost its trigger.'
            Assert-True ([IO.File]::ReadAllText($script:ResumeStatePath) -ceq $before) 'Preserved continuation state changed.'
            if($mode -eq 'completed'){
                function Remove-OwnedTask($Name){$script:TaskPresent=$false}
                function Remove-OwnedFile($Path){[IO.File]::Delete($Path)}
                Clear-ResumeContinuation
                Assert-True (-not $script:TaskPresent -and -not(Test-Path -LiteralPath $script:ResumeStatePath)) 'Normal successful cleanup no longer works.'
            }
        }
        Assert-True ((Get-FileHash -LiteralPath $requestPath).Hash -eq $requestHash -and (Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Cleanup changed request or configuration bytes.'
        [IO.File]::WriteAllText((Join-Path $script:StateRoot 'observed.json'),(@{taskPresent=$script:TaskPresent;removalCount=$script:RemovalCount;result=$script:WireResult}|ConvertTo-Json -Depth 8))
    }
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} continuation checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
