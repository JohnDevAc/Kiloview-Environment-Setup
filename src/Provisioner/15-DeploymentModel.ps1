# Durable deployment state and package policy. No machine changes at import time.
function Write-StateJson {
    param([string]$Path, $Value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ([IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 15))
        $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        Initialize-LifecycleProtocol
        [KiloLink.Lifecycle.AtomicFile]::Commit($temporary,$Path,$null)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Start-DeploymentJournal {
    param([string]$Operation, $Config)
    if ($script:ActiveJournal -and $script:ActiveJournal.outcome -eq 'Running') { $script:ActiveJournal.desired=$Config; Save-DeploymentJournal; return }
    $id = if ($script:Lifecycle) { $script:Lifecycle.OperationId } else { [guid]::NewGuid().ToString('D') }
    $script:ActiveJournal = [ordered]@{schemaVersion=1; operationId=$id; action=$Operation; productVersion=$script:ProductVersion;
        policy=$script:ApplicationManifest.policy; ownerSid=(Get-CurrentUserSid); startedUtc=[datetime]::UtcNow.ToString('o');
        updatedUtc=[datetime]::UtcNow.ToString('o'); outcome='Running'; desired=$Config; steps=@(); mutationStarted=$false;
        attempt=$(if($script:Lifecycle){$script:Lifecycle.Attempt}else{1})}
    Save-DeploymentJournal
}

function Save-ResolvedPackage {
    param([string]$Name, [string]$Version, [string]$Source, [string]$Path)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-StateJson (Join-Path $script:StateRoot ('Packages\' + $Name + '-' + $hash + '.json')) ([ordered]@{
        schemaVersion=1; name=$Name; version=$Version; source=$Source; sha256=$hash;
        size=(Get-Item -LiteralPath $Path).Length; verifiedUtc=[datetime]::UtcNow.ToString('o'); policy=$script:ApplicationManifest.policy})
}

function Save-DeploymentJournal {
    if (-not $script:ActiveJournal) { return }
    $script:ActiveJournal.updatedUtc = [datetime]::UtcNow.ToString('o')
    $path = Join-Path $script:StateRoot ('Operations\' + $script:ActiveJournal.operationId + '.json')
    Write-StateJson $path $script:ActiveJournal
    Write-StateJson (Join-Path $script:StateRoot 'last-operation.json') $script:ActiveJournal
}

function Invoke-DeploymentStep {
    param([string]$Name, [scriptblock]$Body, [switch]$IncompleteOnFalse)
    if (-not $script:ActiveJournal) { & $Body; return }
    $step = [ordered]@{name=$Name; state='Running'; startedUtc=[datetime]::UtcNow.ToString('o'); finishedUtc=$null; error=$null}
    $script:ActiveJournal.steps += $step
    $script:ActiveJournal.mutationStarted=$true
    Write-LifecycleResult 'running' $Name -Stage $Name
    Save-DeploymentJournal
    try {
        if ($IncompleteOnFalse) {
            $result = & $Body
            $step.state = if ($result -is [bool] -and -not $result) { 'Incomplete' } elseif ($script:OperationOutcome -eq 'RestartRequired') { 'RestartRequired' } else { 'Completed' }
            $result
        } else {
            & $Body
            $step.state = if ($script:OperationOutcome -eq 'RestartRequired') { 'RestartRequired' } else { 'Completed' }
        }
    } catch {
        $step.state = 'Failed'; $step.error = $_.Exception.Message
        $script:ActiveJournal.outcome = 'Failed'
        throw
    } finally { $step.finishedUtc = [datetime]::UtcNow.ToString('o'); Save-DeploymentJournal }
}

function Get-DeploymentPlan {
    param($Config)
    [pscustomobject]@{schemaVersion=1; productVersion=$script:ProductVersion; runtime='WSL2'; policy=$script:ApplicationManifest.policy;
        ndiToolsSource=$script:ApplicationManifest.ndiTools.source; pcAgentSource=$script:ApplicationManifest.pcAgent.source;
        kiloLinkImage=$script:KiloImage; desired=$Config; upgradesRuntime=$true;
        stages=@('Verify packages','Windows prerequisites','Dedicated WSL distribution','Docker and Avahi','KiloLink','NDI Tools','Discovery service','Firewall and shortcuts','Watchdog','Verify health');
        runtimeMaintenanceAction='MaintainRuntime'}
}

function Save-InstalledPackageSet {
    param($Config)
    Write-StateJson (Join-Path $script:StateRoot 'installed-package-set.json') ([ordered]@{
        schemaVersion=1; policy=$script:ApplicationManifest.policy; productVersion=$script:ProductVersion;
        verifiedUtc=[datetime]::UtcNow.ToString('o'); kiloLinkImage=$Config.KiloLinkImage;
        ndiToolsVersion=[string](Get-PropertyValue (Get-NdiRegistration) 'DisplayVersion' 'unknown')})
}
