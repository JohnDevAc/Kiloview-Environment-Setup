#Requires -Version 5.1
# Tests current sources without regenerating/replacing any frozen installer.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-progress-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$originalTemp=$env:TEMP
$originalProgramFiles=$env:ProgramFiles
$env:TEMP=$testRoot
$env:ProgramFiles=Join-Path $testRoot 'program-files'
$results=New-Object Collections.Generic.List[object]
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Import-SourceFunctions([string]$Path){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) 'Source parse failed.'
    $definitions=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})
    [scriptblock]::Create($definitions -join "`n")
}
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
}
$core=Import-SourceFunctions (Join-Path $root 'src\Provisioner\10-Core.ps1')
$packages=Import-SourceFunctions (Join-Path $root 'src\Provisioner\50-Packages.ps1')
$ownership=Import-SourceFunctions (Join-Path $root 'src\Provisioner\60-Ownership.ps1')
$linux=Import-SourceFunctions (Join-Path $root 'src\Provisioner\40-Linux.ps1')
try {
    foreach($mode in @('success','agent-failure','restart')) {
        Test-Case "Actual Client staging/download/install progress: $mode" {
            . $core;. $packages;. $ownership
            $LauncherMode=$true;$PackageDirectory='';$AcceptLicenses=$true;$ForceComponentRepair=$false
            $script:ProgressActive=$false;$script:ProgressPercent=0;$script:OperationOutcome='Idle'
            $script:ActiveJournal=$null;$script:Lifecycle=$null;$script:LifecycleEffects=@();$script:LifecycleRecoveryRequired=$false
            $script:PreparedPcAgentRoot=$null;$script:PreparedPcAgentRelease=$null
            $script:PreparedNdiInstaller=$null;$script:PreparedNdiCheck=$null;$script:PcAgentRestartRequired=$false
            $script:StateRoot=Join-Path $testRoot $mode
            $script:Events=New-Object Collections.Generic.List[object]
            $script:NdiInstalled=$false;$script:AgentInstalled=$false
            $script:FixtureBytes=[Text.Encoding]::UTF8.GetBytes('owned package fixture')
            $hash=[Security.Cryptography.SHA256]::Create()
            try{$script:FixtureHash=([BitConverter]::ToString($hash.ComputeHash($script:FixtureBytes))).Replace('-','')}finally{$hash.Dispose()}
            function Write-LauncherEvent($Type,$Data){$script:Events.Add([pscustomobject]@{Type=$Type;Data=$Data.Clone();Outcome=$script:OperationOutcome})}
            function Write-InstallerLog { }
            function Write-LifecycleResult { }
            function Write-LifecycleHeartbeat { }
            function Get-LifecycleResultOutcome($Outcome){$Outcome}
            function Start-DeploymentJournal { }
            function Invoke-DeploymentStep($Name,[scriptblock]$Body){& $Body}
            function Save-ComponentReceipt { }
            function Add-LifecycleEffect($Text){$script:LifecycleEffects+=,$Text}
            function Save-ResolvedPackage { }
            function Assert-PackageSource { }
            function Start-Sleep { }
            function Get-NdiRegistration {if($script:NdiInstalled){[pscustomobject]@{DisplayVersion='6.3.2'}}}
            function Test-NdiClientToolsReady {$script:NdiInstalled}
            function Get-CurrentNdiToolsUrl {'https://downloads.ndi.tv/Tools/NDI-Tools.exe'}
            function Assert-NdiToolsFilesAvailable { }
            function Get-InstallerSignatureWithProgress {[pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=NDI'}}}
            function Start-QuietInstaller {
                $script:NdiInstalled=$true
                $process=[pscustomobject]@{HasExited=$true;ExitCode=$(if($mode -eq 'restart'){3010}else{0})}
                $process|Add-Member ScriptMethod Dispose { }
                $process
            }
            function Get-PcAgentRelease {[pscustomobject]@{Version='0.7.5';Url='https://github.com/fixture/agent.zip';Hash=$script:FixtureHash;Size=$script:FixtureBytes.Length}}
            function Get-PcAgentBinaryVersion($Path,$Product){if($Path.StartsWith($env:ProgramFiles) -and -not $script:AgentInstalled){return $null};'0.7.5'}
            function Expand-PcAgentPackage($Archive,$Destination){New-Item -ItemType Directory -Path $Destination -Force|Out-Null;[IO.File]::WriteAllText((Join-Path $Destination 'LICENSE.md'),'fixture')}
            function Invoke-OwnedPcAgentSetup {
                Set-SuiteProgress -Percent 90 -Status 'Complete the PC Agent setup window'
                if($mode -eq 'agent-failure'){throw 'Owned Agent fixture failed'}
                $script:AgentInstalled=$true
                $true
            }
            function Test-PcAgentConfigured {$script:AgentInstalled}
            function Start-BitsTransfer($Source,$Destination){
                [IO.File]::WriteAllBytes($Destination,$script:FixtureBytes)
                $script:TransferFrame=0
                $script:TransferTotal=if($Source -match 'agent.zip'){127MB}else{[long](539.1MB)}
                [pscustomobject]@{JobId=[guid]::NewGuid()}
            }
            function Get-BitsTransfer($JobId){
                $fraction=@(0.125,(279.0/539.1),0.98,1.0)[$script:TransferFrame++]
                [pscustomobject]@{JobId=$JobId;BytesTotal=[uint64]$script:TransferTotal;BytesTransferred=[uint64]($fraction*$script:TransferTotal);JobState=$(if($fraction -ge 1){'Transferred'}else{'Transferring'})}
            }
            function Complete-BitsTransfer { }
            function Remove-BitsTransfer { }
            function Invoke-WebRequest {throw 'Unexpected real network fallback'}
            $failure=$null
            try{Install-ClientTools}catch{$failure=$_.Exception.Message;Set-OperationOutcome Failed $failure}
            if($mode -eq 'agent-failure'){Assert-True ($failure -match 'Owned Agent fixture failed') 'Failure was lost.'}
            else{Assert-True (-not $failure) $failure}
            $progress=@($script:Events|Where-Object Type -eq 'progress')
            [IO.File]::WriteAllText((Join-Path $testRoot ($mode+'-events.json')),($script:Events|ConvertTo-Json -Depth 6))
            $downloads=@($progress|Where-Object{$_.Data.status -like 'Downloading NDI Tools:*'})
            Assert-True ($downloads.Count -eq 3) 'Actual bounded BITS sequence did not run.'
            Assert-True (($downloads.Data.percent -join ',') -eq '33,45,59') ('Fraction rounding or cumulative NDI range regressed: '+($downloads.Data.percent -join ','))
            $agentDownloads=@($progress|Where-Object{$_.Data.status -like 'Downloading NDI Configurator PC Agent:*'})
            Assert-True (($agentDownloads.Data.percent -join ',') -eq '6,14,24') 'Agent staging consumed the installation range.'
            $ndiInstall=@($progress|Where-Object{$_.Data.status -eq 'Installing NDI Tools'})
            Assert-True ($ndiInstall.Count -eq 1 -and $ndiInstall[0].Data.percent -eq 70) 'NDI installation reached completion prematurely.'
            Assert-True (@($progress|Where-Object{$_.Data.percent -eq 100 -and $_.Outcome -notin @('Completed','NoChange')}).Count -eq 0) 'Nonterminal work reached 100%.'
            Assert-True (($progress[-1].Data.percent -eq 100) -eq ($mode -eq 'success')) 'Failure/restart was presented as complete.'
        }
    }
    Test-Case 'Running progress rejects oversized values and only terminal success reaches 100' {
        . $core
        $LauncherMode=$true;$script:Lifecycle=$null;$script:ActiveJournal=$null;$script:ProgressActive=$false
        function Write-LauncherEvent { };function Write-InstallerLog { };function Write-LifecycleResult { };function Get-LifecycleResultOutcome($Outcome){$Outcome}
        foreach($outcome in @('Failed','Cancelled','Partial','Blocked','RestartRequired','Completed','NoChange')){
            Set-OperationOutcome Running 'Working'
            Start-SuiteProgress 'Fixture'
            Set-SuiteProgress 150 'Downloading'
            Assert-True ($script:ProgressPercent -eq 99) 'An oversized working value reached completion.'
            Set-OperationOutcome $outcome 'Terminal fixture'
            Stop-SuiteProgress
            Assert-True (($script:ProgressPercent -eq 100) -eq ($outcome -in @('Completed','NoChange'))) "Incorrect final progress for $outcome"
        }
        Set-OperationOutcome Running 'Retry'
        Start-SuiteProgress 'Fixture'
        Set-OperationOutcome Completed 'Reported complete'
        Set-OperationOutcome Failed 'Late failure'
        Stop-SuiteProgress
        Assert-True ($script:ProgressPercent -lt 100) 'A late failure retained a successful progress value.'
    }
    foreach($mode in @('enable-both','enable-second','already-enabled','enable-pending','enable-failure')){
        Test-Case "Windows feature status precedes servicing without percentage inflation: $mode" {
            . $core;. $linux
            $LauncherMode=$true;$Action='Repair'
            $script:ProgressActive=$true;$script:ProgressPercent=11;$script:ProgressActivity='Fixture';$script:OperationOutcome='Running'
            $script:FeatureEvents=New-Object Collections.Generic.List[object]
            $script:FeatureStates=@{'Microsoft-Windows-Subsystem-Linux'='Disabled';'VirtualMachinePlatform'='Disabled'}
            if($mode -eq 'enable-second'){$script:FeatureStates['Microsoft-Windows-Subsystem-Linux']='Enabled'}
            if($mode -in @('already-enabled','enable-pending')){
                foreach($name in @($script:FeatureStates.Keys)){$script:FeatureStates[$name]=if($mode -eq 'already-enabled'){'Enabled'}else{'EnablePending'}}
            }
            $script:EnabledFeatures=@{};$script:RestartRequests=0;$script:EnableCalls=0
            $script:LastFeatureProgress=$null;$script:LastFeatureResult=$null
            function Write-InstallerLog { }
            function Write-LauncherEvent($Type,$Data){
                $script:FeatureEvents.Add([pscustomobject]@{Type=$Type;Data=$Data.Clone()})
                if($Type -eq 'progress'){$script:LastFeatureProgress=$Data.Clone()}
            }
            function Write-LifecycleResult($Outcome,$Message,$Stage){
                $script:LastFeatureResult=@{outcome=$Outcome;message=$Message;stage=$Stage}
                $script:FeatureEvents.Add([pscustomobject]@{Type='result';Data=$script:LastFeatureResult.Clone()})
            }
            function Test-SupportedWindows { }
            function Get-Command { [pscustomobject]@{Name='wsl.exe'} }
            function Test-WslRuntime { $true }
            function Wait-WslRuntime { $true }
            function Invoke-Native { }
            function Request-RestartAndResume { $script:RestartRequests++ }
            function Get-WindowsOptionalFeature([switch]$Online,[string]$FeatureName){
                if($script:EnabledFeatures.ContainsKey($FeatureName)){
                    $label=if($FeatureName -eq 'Microsoft-Windows-Subsystem-Linux'){'Windows Subsystem for Linux'}else{'Virtual Machine Platform'}
                    Assert-True ($script:LastFeatureProgress.status -eq "Verifying $label" -and $script:LastFeatureProgress.percent -eq 12) 'Verification status was absent, premature or advanced the percentage.'
                    Assert-True ($script:LastFeatureResult.message -eq "Verifying $label" -and $script:LastFeatureResult.stage -eq 'Windows prerequisites') 'Verification changed the lifecycle stage or was not reported before the query.'
                }
                $script:FeatureEvents.Add([pscustomobject]@{Type='query';Data=@{feature=$FeatureName;state=$script:FeatureStates[$FeatureName]}})
                [pscustomobject]@{State=$script:FeatureStates[$FeatureName]}
            }
            function Enable-WindowsOptionalFeature([switch]$Online,[string]$FeatureName,[switch]$All,[switch]$NoRestart){
                $script:EnableCalls++
                $label=if($FeatureName -eq 'Microsoft-Windows-Subsystem-Linux'){'Windows Subsystem for Linux'}else{'Virtual Machine Platform'}
                $expected="Enabling $label. This can take several minutes."
                Assert-True ($script:LastFeatureProgress.status -eq $expected -and $script:LastFeatureProgress.percent -eq 12) 'Accurate feature status did not precede servicing at the unchanged percentage.'
                Assert-True ($script:LastFeatureResult.outcome -eq 'running' -and $script:LastFeatureResult.message -eq $expected -and $script:LastFeatureResult.stage -eq 'Windows prerequisites') 'Running result did not precede servicing or changed its parent stage.'
                Assert-True ($Online -and $All -and $NoRestart) 'Feature enable flags changed.'
                $script:FeatureEvents.Add([pscustomobject]@{Type='enable';Data=@{feature=$FeatureName}})
                if($mode -eq 'enable-failure'){throw 'Fixture servicing failure'}
                $script:EnabledFeatures[$FeatureName]=$true;$script:FeatureStates[$FeatureName]='EnablePending'
                $script:FeatureEvents.Add([pscustomobject]@{Type='enable-return';Data=@{feature=$FeatureName}})
                [pscustomobject]@{RestartNeeded=$true}
            }
            $failure=$null;$ready=$null
            try{$ready=Ensure-WslFeatures}catch{$failure=$_.Exception.Message}
            [IO.File]::WriteAllText((Join-Path $testRoot ('windows-features-'+$mode+'-events.json')),($script:FeatureEvents|ConvertTo-Json -Depth 6))
            if($mode -eq 'enable-failure'){
                Assert-True ($failure -eq 'Fixture servicing failure' -and $script:RestartRequests -eq 0) 'Servicing failure or restart behavior changed.'
                Assert-True (@($script:FeatureEvents|Where-Object{$_.Type -eq 'progress' -and $_.Data.status -like 'Verifying *'}).Count -eq 0) 'Failed servicing incorrectly announced verification.'
            }else{
                Assert-True (-not $failure) $failure
                Assert-True (($ready -eq $true) -eq ($mode -eq 'already-enabled')) 'Runtime readiness changed.'
                Assert-True ($script:RestartRequests -eq $(if($mode -eq 'already-enabled'){0}else{1})) 'Restart behavior changed.'
            }
            $expectedCalls=switch($mode){'enable-both'{2}'enable-second'{1}'enable-failure'{1}default{0}}
            Assert-True ($script:EnableCalls -eq $expectedCalls) 'Already-enabled/pending features were serviced again.'
            if($expectedCalls -eq 0){
                Assert-True (@($script:FeatureEvents|Where-Object{$_.Type -eq 'progress' -and $_.Data.status -like 'Enabling *'}).Count -eq 0 -and $null -eq $script:LastFeatureResult) 'An already-enabled/pending feature falsely reported activation.'
            }
        }
    }
    $removalCases=@(
        @{Name='server-preserve';Action='Uninstall';Role='server';Purge=$false;Label='Removing Server role'},
        @{Name='server-purge';Action='Uninstall';Role='server';Purge=$true;Label='Removing Server role'},
        @{Name='client';Action='Uninstall';Role='client';Purge=$false;Label='Removing Client role'},
        @{Name='app-only';Action='RemoveApp';Role='server';Purge=$false;Label='Removing configuration app'}
    )
    $removalEventCases=@{}
    foreach($case in $removalCases){
        Test-Case ('Removal engine reports selected scope before effects: '+$case.Name) {
            . $core
            . (Import-SourceFunctions (Join-Path $root 'src\Provisioner\90-Operations.ps1'))
            . (Import-SourceFunctions (Join-Path $root 'src\Provisioner\92-Removal.ps1'))
            $LauncherMode=$true;$Action=$case.Action;$PurgeData=$case.Purge
            $script:ActiveJournal=$null;$script:Lifecycle=$null;$script:ProgressActive=$false
            $script:OperationOutcome='Idle';$script:LifecycleErrorCode='';$script:LifecycleRecoveryRequired=$false
            $script:StateRoot=Join-Path $testRoot ('removal-'+$case.Name)
            New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
            $script:RemovalEvents=New-Object Collections.Generic.List[object]
            $script:RemovalResults=New-Object Collections.Generic.List[object]
            function Write-LauncherEvent($Type,$Data){$script:RemovalEvents.Add([pscustomobject]@{Type=$Type;Data=$Data.Clone()})}
            function Write-LifecycleResult($Outcome,$Message){$script:RemovalResults.Add([pscustomobject]@{outcome=$Outcome;message=$Message})}
            function Get-LifecycleResultOutcome($Outcome){$Outcome.ToLowerInvariant()}
            function Write-InstallerLog { }
            function Assert-ServerOwner { }
            function Test-ServerOwnershipEvidence {$true}
            function Get-SavedConfig {[pscustomobject]@{DistroName='owned-fixture'}}
            function Get-PropertyValue($Object,$Name,$Default){if($Object.$Name){$Object.$Name}else{$Default}}
            function Start-DeploymentJournal { }
            function Write-Heading { }
            function Add-LifecycleEffect { }
            function Save-ComponentReceipt($Role,[switch]$Remove){
                if($Role -eq 'client'){
                    [IO.File]::WriteAllText((Join-Path $script:StateRoot 'installation-components.json'),'{"roles":["server"]}')
                }
            }
            function Get-UbuntuDistro {'owned-fixture'}
            function Invoke-DeploymentStep {throw 'Owned removal boundary; no services touched'}
            function Write-StateJson { }
            function Get-ConfigurationProducts {@()}
            $failure=$null
            try{
                if($case.Action -eq 'RemoveApp'){Remove-ConfigurationApp}
                elseif($case.Role -eq 'client'){Remove-ClientRole}
                else{Uninstall-Suite -Confirmed}
            }catch{$failure=$_.Exception.Message}
            if($case.Action -eq 'Uninstall' -and $case.Role -eq 'server'){
                Assert-True ($failure -eq 'Owned removal boundary; no services touched') 'Server fixture crossed its owned boundary.'
            }else{Assert-True (-not $failure) $failure}
            $removalEventCases[$case.Name]=$script:RemovalEvents.ToArray()
            [IO.File]::WriteAllText((Join-Path $testRoot ('removal-'+$case.Name+'-events.json')),(@{events=$script:RemovalEvents.ToArray();results=$script:RemovalResults.ToArray()}|ConvertTo-Json -Depth 6))
            $running=@($script:RemovalEvents|Where-Object{$_.Type -eq 'outcome' -and $_.Data.outcome -eq 'Running'})
            Assert-True ($running.Count -eq 1 -and $running[0].Data.message -eq ($case.Label+'.')) 'Initial removal outcome describes the wrong scope or is missing.'
            Assert-True ($script:RemovalResults[0].outcome -eq 'running' -and $script:RemovalResults[0].message -eq ($case.Label+'.')) 'Initial lifecycle result describes the wrong scope.'
            $progress=@($script:RemovalEvents|Where-Object Type -eq 'progress')
            if($case.Action -eq 'Uninstall' -and $case.Role -eq 'server'){
                Assert-True ($progress.Count -gt 0 -and @($progress|Where-Object{$_.Data.activity -ne $case.Label}).Count -eq 0) 'Server progress implies wider suite removal.'
            }
        }
    }
    # Compile current native sources into an owned temp fixture; no build output
    # or frozen candidate is touched, and no launcher/engine entry point is run.
    $fixtureEngine=Join-Path $testRoot 'engine.ps1'
    [IO.File]::WriteAllText($fixtureEngine,'exit 0')
    $fixtureExe=Join-Path $testRoot 'ProgressFixture.exe'
    $compilerArguments=@('/nologo','/target:winexe','/reference:System.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',('/out:'+$fixtureExe))
    foreach($resource in @(@($fixtureEngine,'Install-KiloLinkSuite.ps1'),@((Join-Path $root 'launcher\QuietInstaller.cs'),'QuietInstaller.cs'),@((Join-Path $root 'LICENSE'),'LICENSE'),@((Join-Path $root 'EULA.md'),'EULA.md'),@((Join-Path $root 'THIRD_PARTY_NOTICES.md'),'THIRD_PARTY_NOTICES.md'),@((Join-Path $root 'assets\setup-icon.png'),'setup-icon.png'),@((Join-Path $root 'assets\setup.ico'),'setup.ico'))){$compilerArguments+='/resource:'+$resource[0]+',KiloLink.Setup.'+$resource[1]}
    foreach($source in @('SetupLauncher.cs','SetupWizard.cs','SetupLayout.cs','SetupPackage.cs','LifecycleProtocol.cs','SetupLifecycle.cs')){$compilerArguments+=Join-Path $root ('launcher\'+$source)}
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" @compilerArguments
    Assert-True ($LASTEXITCODE -eq 0) 'Native progress fixture compilation failed.'
    $assembly=[Reflection.Assembly]::LoadFile($fixtureExe)
    $formType=$assembly.GetType('KiloLink.Setup.SetupForm')
    $flags=[Reflection.BindingFlags]'Instance,NonPublic,Public'
    foreach($case in $removalCases){
        Test-Case ('Native removal headline follows reviewed scope and real engine events: '+$case.Name) {
            $form=$formType.GetConstructor($flags,$null,@([bool]),$null).Invoke(@($false))
            try{
                $formType.GetField('selectedAction',$flags).SetValue($form,$case.Action)
                $formType.GetField('clientChoice',$flags).GetValue($form).Checked=$case.Role -eq 'client'
                $formType.GetField('serverChoice',$flags).GetValue($form).Checked=$case.Role -eq 'server'
                $formType.GetField('purgeConfirmed',$flags).SetValue($form,$case.Purge)
                $formType.GetField('installerOperationInProgress',$flags).SetValue($form,$true)
                $label=$formType.GetField('activityLabel',$flags).GetValue($form)
                $status=$formType.GetField('progressStatusLabel',$flags).GetValue($form)
                $handler=$formType.GetMethod('HandleOutputLine',$flags)
                $events=@($removalEventCases[$case.Name]|Where-Object{$_.Type -eq 'progress' -or ($_.Type -eq 'outcome' -and $_.Data.outcome -eq 'Running')})
                Assert-True ($events.Count -gt 0) 'Missing real engine events.'
                foreach($event in $events){
                    $payload=$event.Data.Clone();$payload.type=$event.Type
                    [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@'+($payload|ConvertTo-Json -Compress)))
                    Assert-True ($label.Text -eq $case.Label) 'An engine event replaced the reviewed removal scope.'
                    if($event.Type -eq 'outcome'){Assert-True ($status.Text -eq ($case.Label+'.')) 'Running status lost the selected scope.'}
                }
                $initial=$formType.GetMethod('GetRemovalProgressActivity',$flags).Invoke($form,@())
                Assert-True ($initial -eq $case.Label) 'Initial native headline does not match the reviewed removal.'
                $formType.GetField('selectedAction',$flags).SetValue($form,'Repair')
                Assert-True ($null -eq $formType.GetMethod('GetRemovalProgressActivity',$flags).Invoke($form,@())) 'Removal wording leaked into repair.'
            }finally{$form.Dispose();[Environment]::ExitCode=0}
        }
    }
    foreach($mode in @('success','failure-after-completion','restart','cancelled','no-change')){
        Test-Case "Native progress waits for the worker exit: $mode" {
            $form=$formType.GetConstructor($flags,$null,@([bool]),$null).Invoke(@($false))
            try{
                $busy=$formType.GetField('installerOperationInProgress',$flags)
                $bar=$formType.GetField('progressBar',$flags).GetValue($form)
                $value=$bar.GetType().GetProperty('Value',$flags)
                $handler=$formType.GetMethod('HandleOutputLine',$flags)
                $complete=$formType.GetMethod('ApplyInstallerOutcome',$flags)
                $busy.SetValue($form,$true)
                foreach($status in @('Downloading NDI Tools: 279 MB / 539.1 MB','Verifying the NDI Tools signature','Installing NDI Tools')){
                    [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@'+(@{type='progress';percent=100;status=$status}|ConvertTo-Json -Compress)))
                    Assert-True ($value.GetValue($bar,$null) -lt 100) 'Native UI trusted an early 100% progress event.'
                }
                $outcome=switch($mode){restart{'RestartRequired'}cancelled{'Cancelled'}no-change{'NoChange'}default{'Completed'}}
                [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@'+(@{type='outcome';outcome=$outcome;message='Fixture'}|ConvertTo-Json -Compress)))
                Assert-True ($value.GetValue($bar,$null) -lt 100) 'Outcome event completed the UI before worker exit.'
                $busy.SetValue($form,$false)
                $code=switch($mode){failure-after-completion{1}restart{3010}cancelled{1602}default{0}}
                [void]$complete.Invoke($form,@([int]$code))
                Assert-True (($value.GetValue($bar,$null) -eq 100) -eq ($mode -in @('success','no-change'))) 'Native final progress disagrees with exit/outcome.'
            }finally{$form.Dispose();[Environment]::ExitCode=0}
        }
    }
    foreach($outcome in @('Failed','Cancelled','Partial','Blocked','RestartRequired','Completed','worker-crash')){
        Test-Case "Native terminal event cannot write while the worker owns the result: $outcome" {
            $directory=Join-Path $testRoot ([guid]::NewGuid().ToString('D'));New-Item -ItemType Directory -Path $directory|Out-Null
            $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
            foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
            Set-Acl -LiteralPath $directory -AclObject $acl
            $requestPath=Join-Path $directory 'request.json'
            [IO.File]::WriteAllText($requestPath,(@{schemaVersion=1;operationId=[IO.Path]::GetFileName($directory);productId='environment';action='install';resultPath=(Join-Path $directory 'result.json')}|ConvertTo-Json))
            $requestType=$assembly.GetType('KiloLink.Lifecycle.Request');$hostType=$assembly.GetType('KiloLink.Setup.SetupLauncher');$statics=[Reflection.BindingFlags]'Static,NonPublic,Public'
            $request=$requestType.GetMethod('Load').Invoke($null,@([string]$requestPath))
            $request.Write('running','Worker owns result','ndi-metadata','','','{}')
            $hostType.GetField('LifecycleRequest',$statics).SetValue($null,$request)
            $form=$formType.GetConstructor($flags,$null,@([bool]),$null).Invoke(@($false))
            try{
                $busy=$formType.GetField('installerOperationInProgress',$flags);$busy.SetValue($form,$true)
                $handler=$formType.GetMethod('HandleOutputLine',$flags)
                $eventOutcome=if($outcome -eq 'worker-crash'){'Failed'}else{$outcome}
                [void]$handler.Invoke($form,@('@@KILOVIEW_EVENT@@'+(@{type='outcome';outcome=$eventOutcome;message='Worker is still saving the original result'}|ConvertTo-Json -Compress)))
                [void]$formType.GetMethod('CompleteLifecycle',$flags).Invoke($form,@([int]1))
                Assert-True ($request.ReadResult().outcome -eq 'running') 'Native fallback raced the still-active producer and replaced its result.'
                $wire=switch($outcome){RestartRequired{'restart-required'}Completed{'succeeded'}default{$outcome.ToLowerInvariant()}}
                $code=switch($outcome){RestartRequired{3010}Completed{0}Cancelled{1602}default{1}}
                if($outcome -ne 'worker-crash'){$request.Write($wire,'Original producer result','ndi-metadata','fixture-owner-code','Original retry guidance','{"partialEffects":["Preserved fixture evidence"]}')}
                $busy.SetValue($form,$false)
                [void]$formType.GetMethod('ApplyInstallerOutcome',$flags).Invoke($form,@([int]$code))
                $result=$request.ReadResult()
                if($outcome -eq 'worker-crash'){
                    Assert-True ($result.outcome -eq 'failed' -and $result.errorCode -eq 'missing-terminal-result' -and $result.stage -eq 'worker-exit') 'Native completion did not report a producer that exited without a terminal result.'
                }else{
                    Assert-True ($result.outcome -eq $wire -and $result.errorCode -eq 'fixture-owner-code' -and $result.stage -eq 'ndi-metadata' -and $result.partialEffects[0] -eq 'Preserved fixture evidence') 'Native completion replaced the real producer cause/evidence.'
                }
            }finally{$form.Dispose();$hostType.GetField('LifecycleRequest',$statics).SetValue($null,$null);[Environment]::ExitCode=0}
        }
    }
} finally {$env:TEMP=$originalTemp;$env:ProgramFiles=$originalProgramFiles}
$passed=@($results|Where-Object{$_.Passed}).Count
Write-Output "$passed/$($results.Count) progress checks passed. Evidence: $testRoot"
if($passed -ne $results.Count){exit 1}
