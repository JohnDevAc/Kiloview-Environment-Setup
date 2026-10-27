function Initialize-LifecycleProtocol {
    if (-not ('KiloLink.Lifecycle.Request' -as [type])) {
        $source = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__LIFECYCLE_PROTOCOL_BASE64__'))
        Add-Type -TypeDefinition $source -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
    }
}

function Initialize-Lifecycle {
    if (-not (Get-Variable LifecycleRequestPath -ValueOnly -ErrorAction SilentlyContinue) -or $script:Lifecycle) { return }
    Initialize-LifecycleProtocol
    $script:Lifecycle = [KiloLink.Lifecycle.Request]::Load($LifecycleRequestPath)
    if ($Role -and $script:Lifecycle.Role -and $Role -ne $script:Lifecycle.Role) { throw 'Reviewed role does not match the requested role.' }
    if (-not $Role) { $script:Role=$script:Lifecycle.Role }
    if ($script:Lifecycle.RequestedVersion -and $script:Lifecycle.RequestedVersion -ne $script:ProductVersion) {
        $script:Lifecycle.Write('blocked','This installer does not match requestedVersion.','preflight','version-mismatch','Use the verified requested installer.','{}')
        throw 'Lifecycle requested version differs from this installer.'
    }
    if ($Action -eq 'Menu') {
        $script:Action = switch ($script:Lifecycle.Action) {
            inspect { 'Inspect' } install { if ($Role -eq 'client') { 'InstallClient' } else { 'Setup' } }
            update { if ($Role -eq 'client') { 'InstallClient' } else { 'Update' } }
            repair { if ($Role -eq 'client') { 'InstallClient' } else { 'Repair' } }
            remove-role { 'Uninstall' } remove-app { 'RemoveApp' } uninstall { 'Uninstall' }
            backup { 'Backup' } maintain-runtime { 'MaintainRuntime' }
        }
    }
    $allowed = switch ($script:Lifecycle.Action) {
        inspect { @('Inspect') } install { @('Setup','Install','InstallClient','Resume') }
        update { @('Update','InstallClient','Resume') } repair { @('Repair','InstallClient','Resume') }
        remove-role { @('Uninstall') } remove-app { @('RemoveApp') } uninstall { @('Uninstall') }
        backup { @('Backup') } maintain-runtime { @('MaintainRuntime','Resume') }
    }
    if ($Action -notin $allowed) { throw 'Requested lifecycle action does not match the engine action.' }
    if ($Role -eq 'server' -and $Action -eq 'InstallClient') { throw 'Requested role does not match the engine action.' }
    if ($Role -eq 'client' -and $Action -in @('Setup','Repair','Update','Backup','MaintainRuntime')) { throw 'Requested role does not match the engine action.' }
    if (-not $Role -and $Action -notin @('Inspect','RemoveApp','Resume')) { throw 'Choose Client or Server in the Environment setup window before applying this request.' }
    $script:PreserveData = -not $PurgeData
    if ($PurgeData -and ($script:Lifecycle.PreserveData -or -not $ConfirmRemoval)) { throw 'Data purge requires an explicit non-preserving request and the reviewed removal confirmation.' }
    $script:ForceComponentRepair = $script:Lifecycle.Action -eq 'repair'
    $previous = $script:Lifecycle.ReadResult()
    if($previous -and $previous.ContainsKey('partialEffects')){$script:LifecycleEffects=@($previous['partialEffects'])}
    if ($Action -eq 'Resume' -and $previous) { $script:Lifecycle.ContinueAttempt() }
    # Heartbeats reuse OperationMessage before the action sets its own status.
    $script:OperationMessage='Checking requirements.'
    Write-LifecycleResult 'running' $script:OperationMessage -Stage 'preflight'
}

function Write-LifecycleResult {
    param([string]$Outcome='running',[string]$Message='', [string]$Stage, [string]$ErrorCode, [string]$NextAction, $Components, [hashtable]$Evidence=@{})
    if (-not $script:Lifecycle) { return }
    if ($Stage) { $script:LifecycleStage=$Stage }
    if ($ErrorCode) { $script:LifecycleErrorCode=$ErrorCode }
    if ($NextAction) { $script:LifecycleNextAction=$NextAction }
    if ($null -ne $Components) { $script:LifecycleComponents=@($Components) }
    $extras=@{safeToCancel=$false; partialEffects=@($script:LifecycleEffects); recoveryRequired=[bool]$script:LifecycleRecoveryRequired;
        components=@($script:LifecycleComponents); logPath=$script:InstallerLogPath}
    foreach ($key in $Evidence.Keys) { $extras[$key]=$Evidence[$key] }
    if($Evidence.ContainsKey('nextAction')){$script:LifecycleNextAction=[string]$Evidence['nextAction']}
    if ($script:ActiveJournal) { $extras['journalPath']=Join-Path $script:StateRoot ('Operations\'+$script:ActiveJournal.operationId+'.json') }
    if ($Outcome -eq 'failed' -and $script:LifecycleEffects.Count) { $Outcome='partial' }
    try {
        $script:Lifecycle.Write($Outcome,$Message,$script:LifecycleStage,$script:LifecycleErrorCode,$script:LifecycleNextAction,($extras|ConvertTo-Json -Depth 12 -Compress))
    } catch {
        $failure=$_.Exception.Message
        $intendedErrorCode=$script:LifecycleErrorCode
        $script:LifecycleErrorCode='lifecycle-result-write-failed'
        $script:LifecycleNextAction='Inspect the operation journal, result-write diagnostics and installed components before retrying the intended operation. Do not assume completed steps were rolled back.'
        # Preserve the first intended outcome even if the outer failure handler
        # also cannot save its result. Storage failure must not replace the cause.
        if($script:ActiveJournal -and -not $script:ActiveJournal.Contains('resultWriteFailure')) {
            $script:ActiveJournal['resultWriteFailure']=@{intendedOutcome=$Outcome;operationOutcome=$script:OperationOutcome;originalErrorCode=$intendedErrorCode;message=$Message;error=$failure;nextAction=$script:LifecycleNextAction}
            try{Save-DeploymentJournal}catch{Write-InstallerLog ('Could not record result-write failure in the journal: '+$_.Exception.Message)}
        }
        $detail="Could not save lifecycle outcome '$Outcome': $Message Result persistence failed: $failure $script:LifecycleNextAction"
        Write-InstallerLog $detail
        throw $detail
    }
    $script:LifecycleLastHeartbeat=[datetime]::UtcNow
}

function Write-LifecycleHeartbeat {
    if ($script:Lifecycle -and ([datetime]::UtcNow-$script:LifecycleLastHeartbeat).TotalSeconds -ge 5) {
        Write-LifecycleResult 'running' $script:OperationMessage
    }
}

function Add-LifecycleEffect([string]$Message) {
    if ($Message -notin $script:LifecycleEffects) { $script:LifecycleEffects+= $Message }
    Write-LifecycleResult 'running' $Message
}

function Get-LifecycleResultOutcome([string]$Outcome) {
    switch ($Outcome) {
        Completed { 'succeeded' } NoChange { 'no-change' } Cancelled { if ($script:LifecycleEffects.Count) { 'partial' } else { 'cancelled' } }
        RestartRequired { 'restart-required' } Blocked { 'blocked' } Partial { 'partial' } Failed { if ($script:LifecycleEffects.Count) { 'partial' } else { 'failed' } }
        default { 'running' }
    }
}

function Get-RegisteredManagedDistro {
    # Registry inspection does not launch wsl.exe or start a stopped distribution.
    $root='HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $root)) { return $false }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        $entry=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
        if ((Get-PropertyValue $entry 'DistributionName' '') -eq $script:ManagedDistroName) { return $true }
    }
    return $false
}

function Get-ObservedComponents {
    $items=New-Object 'Collections.Generic.List[object]'
    $app=Join-Path ${env:ProgramFiles} 'Kiloview\Environment Setup\Kiloview-Environment-Setup.exe'
    $msiApp=Test-Path -LiteralPath $app -PathType Leaf
    if(-not $msiApp){
        foreach($candidate in @($script:PersistentLauncherPath,(Join-Path $script:StateRoot 'Launcher\Kiloview-Environment-Setup.exe'))){if(Test-Path -LiteralPath $candidate -PathType Leaf){$app=$candidate;break}}
    }
    $items.Add([pscustomobject]@{productId='environment';installed=(Test-Path -LiteralPath $app -PathType Leaf);configurationAppInstalled=$msiApp;configured=$null;running=$null;healthy=$null;
        version=$(if(Test-Path -LiteralPath $app){(Get-Item -LiteralPath $app).VersionInfo.ProductVersion}else{$null});channel=$null;inspectionVersion=$script:ProductVersion;inspectionChannel=$script:ProductChannel})
    try {
        $registration=Get-NdiRegistration
        $ndiVersion=if($registration){[string](Get-PropertyValue $registration 'DisplayVersion' '')}else{$null}
        $items.Add([pscustomobject]@{productId='ndi-tools';installed=[bool]$registration;configured=$null;running=$null;healthy=$null;version=$ndiVersion;channel='vendor-stable'})
    } catch { $items.Add([pscustomobject]@{productId='ndi-tools';installed=$null;configured=$null;running=$null;healthy=$null;version=$null;error=$_.Exception.Message}) }
    try {
        $service=Get-NdiDiscoveryService
        $exe=Get-NdiDiscoveryExe
        $running=if($service){$service.Status -eq 'Running'}else{$null}
        $healthy=if($running){Test-NdiServerReady ([pscustomobject]@{NdiDiscoveryPort=5959})}elseif($null -ne $running){$false}else{$null}
        $items.Add([pscustomobject]@{productId='ndi-discovery';installed=[bool]$exe;configured=(Test-Path -LiteralPath (Get-DiscoveryConfigPath));running=$running;healthy=$healthy;version=$(if($exe){(Get-Item -LiteralPath $exe).VersionInfo.FileVersion}else{$null})})
    } catch { $items.Add([pscustomobject]@{productId='ndi-discovery';installed=$null;configured=$null;running=$null;healthy=$null;version=$null;error=$_.Exception.Message}) }
    try {
        $registered=Get-RegisteredManagedDistro
        $config=Get-SavedConfig
        $retained=Test-Path -LiteralPath (Join-Path $script:StateRoot 'retained-server.json')
        $items.Add([pscustomobject]@{productId='kilolink';installed=$(if($registered){$null}else{$false});configured=[bool]$config;running=$null;healthy=$null;version=$null;retainedEnvironment=$retained;roleActive=[bool]$config;
            distroRegistered=$registered;inspection='Runtime state was not probed; inspection never starts WSL.'})
    } catch { $items.Add([pscustomobject]@{productId='kilolink';installed=$null;configured=$null;running=$null;healthy=$null;version=$null;error=$_.Exception.Message}) }
    try {
        $agentRoot=Join-Path $env:ProgramFiles 'NDI Configurator\PC Agent'
        $entry=Get-PcAgentLifecycleEntry $agentRoot 'inspect'
        if($entry){
            $owned=Invoke-PcAgentLifecycle $entry 'inspect'
            $component=@($owned.components|Where-Object productId -eq 'pc-agent')
            if($owned.outcome -ne 'succeeded' -or $component.Count -ne 1){throw 'Agent inspection did not return verified component evidence.'}
            $items.Add($component[0])
        } else {
        $agent=Join-Path $agentRoot 'NDI Configurator PC Agent.exe'
        $setup=Join-Path $agentRoot 'NDI Configurator PC Agent Setup.exe'
        $version=Get-PcAgentBinaryVersion $agent 'NDI Configurator PC Agent'
        $setupVersion=Get-PcAgentBinaryVersion $setup 'NDI Configurator PC Agent'
        $installed=[bool]($version -and $setupVersion -and (Compare-PcAgentVersion $version $setupVersion) -eq 0)
        $running=@(Get-Process -ErrorAction Stop|Where-Object { $_.Path -and [string]::Equals($_.Path,$agent,[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        $items.Add([pscustomobject]@{productId='pc-agent';installed=$installed;version=$version;setupVersion=$setupVersion;configured=(Test-PcAgentConfigured);running=$running;healthy=$null;onboarded=$null;channel='stable';inspection='Legacy local evidence; onboarding/health require the Agent-owned lifecycle descriptor.'})
        }
    } catch { $items.Add([pscustomobject]@{productId='pc-agent';installed=$null;configured=$null;running=$null;healthy=$null;version=$null;error=$_.Exception.Message}) }
    return $items.ToArray()
}

function Get-LifecycleInspection {
    $recovery=$false; $active=$null; $safe=$false; $journal=$null
    $mutex=New-Object Threading.Mutex($false,'Global\KiloviewProvisioner')
    $launcherMutex=New-Object Threading.Mutex($false,'Global\KiloviewEnvironmentSetup')
    $owned=$false
    $launcherOwned=$false
    try {
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException] {$owned=$true}
        try{$launcherOwned=$launcherMutex.WaitOne(0)}catch [Threading.AbandonedMutexException] {$launcherOwned=$true}
        $last=Join-Path $script:StateRoot 'last-operation.json'
        if(Test-Path -LiteralPath $last){try{$journal=Get-Content -Encoding UTF8 -LiteralPath $last -Raw|ConvertFrom-Json}catch{$recovery=$true}}
        foreach($backup in @(Get-ChildItem -LiteralPath (Join-Path $script:StateRoot 'Backups') -Directory -ErrorAction SilentlyContinue)){
            $status=Join-Path $backup.FullName 'status'
            if((Test-Path -LiteralPath $status) -and (Get-Content -Encoding UTF8 -LiteralPath $status -Raw).Trim() -notin @('committed','rolled-back','backup-complete')){$recovery=$true}
        }
        if($journal -and $journal.outcome -in @('Running','RestartRequired')) {
            if(-not $owned -or $journal.outcome -eq 'RestartRequired'){$active=$journal.operationId}
            elseif(Get-PropertyValue $journal 'mutationStarted' $true){$recovery=$true}
        }
        if($journal -and (Get-PropertyValue $journal 'recoveryRequired' $false)){$recovery=$true}
        $pending=Join-Path $script:StateRoot 'pending-process.json'
        if(Test-Path -LiteralPath $pending){$recovery=$true}
        if(Get-PendingWatchdogRecovery){$recovery=$true}
        $safe=$owned -and $launcherOwned -and -not $recovery -and -not $active
        $next=if($recovery){'Wait for the previous operation to finish. Open Environment Setup and choose Verify after an interrupted operation. If verification reports unresolved backup recovery, follow the recovery instructions shown with its log.'}elseif($active -or -not $launcherOwned){'Wait for the active setup window or complete its restart continuation.'}else{''}
        [pscustomobject]@{schemaVersion=1;components=@(Get-ObservedComponents);ownerSid=(Get-ServerOwnerSid);activeOperationId=$active;safeToRetry=$safe;recoveryRequired=$recovery;nextAction=$next;configuration=(Get-SavedConfig);plan=(Get-DeploymentPlan (Get-SavedConfig))}
    } finally {if($owned){$mutex.ReleaseMutex()};$mutex.Dispose();if($launcherOwned){$launcherMutex.ReleaseMutex()};$launcherMutex.Dispose()}
}

function Assert-NoPendingNativeProcess {
    $path=Join-Path $script:StateRoot 'pending-process.json'
    if(Test-Path -LiteralPath $path){$pending=Get-Content -Encoding UTF8 -LiteralPath $path -Raw|ConvertFrom-Json}
    else {
        # A pending-file write can fail independently of the operation journal.
        # Retained command identity in that journal still blocks an unsafe retry.
        $journalPath=Join-Path $script:StateRoot 'last-operation.json'
        $journal=if(Test-Path -LiteralPath $journalPath){Get-Content -Encoding UTF8 -LiteralPath $journalPath -Raw|ConvertFrom-Json}else{$null}
        $pending=Get-PropertyValue $journal 'pendingNativeProcess' $null
        if(-not $pending){return}
    }
    $jobName=Get-PropertyValue $pending 'jobName' ''
    if ($jobName) {
        Initialize-LifecycleProtocol
        if ([KiloLink.Lifecycle.ConsoleBootstrapProcess]::IsJobActive($jobName)) {
            throw 'The previous WSL bootstrap or a descendant is still running. Wait for its tracked process tree to finish before verifying or retrying.'
        }
    }
    $receipt=if(Get-PropertyValue $pending 'bootstrapResult' ''){Get-WslBootstrapReceipt $pending}else{$null}
    $processId=[int]$pending.processId;$startedUtc=[string]$pending.startedUtc
    if($processId -le 0 -and $receipt){$processId=[int]$receipt.hostProcessId;$startedUtc=[string]$receipt.hostStartedUtc}
    $process=if($processId -gt 0){Get-Process -Id $processId -ErrorAction SilentlyContinue}else{$null}
    if($process -and $process.StartTime.ToUniversalTime().ToString('o') -eq $startedUtc) {
        throw 'The previous native command is still running. Wait for it to finish before verifying or retrying.'
    }
    if(Get-PropertyValue $pending 'bootstrapResult' '') {
        if(-not $receipt -or $receipt.phase -ne 'completed') {throw 'The interrupted WSL bootstrap has no confirmed process-tree completion. Preserve its recovery records and inspect the bootstrap supervisor before retrying.'}
    }
    if($Action -ne 'Verify'){throw 'The previous native command has unverified completion. Inspect recovery records and run -Action Verify before retrying.'}
}

function Remove-VerifiedPendingProcess {
    $path=Join-Path $script:StateRoot 'pending-process.json'
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
}

function Test-NonServerRecovery {
    $pendingPath=Join-Path $script:StateRoot 'pending-process.json'
    $pending=if(Test-Path -LiteralPath $pendingPath){Get-Content -Encoding UTF8 -LiteralPath $pendingPath -Raw|ConvertFrom-Json}else{$null}
    if($pending -and (Get-PropertyValue $pending 'action' '') -eq 'RemoveApp'){
        if(@(Get-ConfigurationProducts).Count){throw 'Configuration app removal is incomplete. Complete or repair Windows Installer removal before verifying.'}
        return
    }
    if($pending -and (Get-PropertyValue $pending 'reason' '') -match 'Windows Installer'){
        if(@(Get-ConfigurationProducts).Count -ne 1){throw 'Windows Installer did not leave one verified configuration application. Repair it in Windows Apps before verifying.'}
        $installed=Join-Path $env:ProgramFiles 'Kiloview\Environment Setup'
        foreach($file in @('Install-KiloLinkSuite.ps1','QuietInstaller.cs')){
            if((Get-FileHash -LiteralPath (Join-Path $installed $file)).Hash -ne (Get-FileHash -LiteralPath (Join-Path (Split-Path $script:PersistentLauncherPath) $file)).Hash){throw 'Configuration application payload is incomplete. Repair it in Windows Apps before verifying.'}
        }
        return
    }
    if($pending -and (Get-PropertyValue $pending 'childResult' '')){
        $requestPath=Join-Path (Split-Path $pending.childResult) 'request.json'
        Initialize-LifecycleProtocol
        $child=[KiloLink.Lifecycle.Request]::LoadForProduct($requestPath,'pc-agent')
        $result=$child.ReadResult()
        if(-not $result -or $result['outcome'] -in @('running','restart-required') -or ($result.ContainsKey('recoveryRequired') -and $result['recoveryRequired'])){
            throw "PC Agent still requires its own recovery. Inspect $($pending.childResult) before verifying Environment."
        }
    }
    $components=@(Get-ObservedComponents)
    foreach($id in @('ndi-tools','pc-agent')){
        $component=@($components|Where-Object productId -eq $id)
        if($component.Count -ne 1 -or $component[0].installed -ne $true){throw "The $id installation is not verified. Repair it with its own verified installer before verifying Environment."}
    }
    if(-not(Test-NdiClientToolsReady)){throw 'Required NDI Client applications are missing. Repair NDI Tools before verifying Environment.'}
}
