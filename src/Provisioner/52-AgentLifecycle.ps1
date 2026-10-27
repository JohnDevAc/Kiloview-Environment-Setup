function Get-PcAgentLifecycleEntry([string]$Directory,[string]$Action) {
    $descriptor=Join-Path $Directory 'toolbox-lifecycle.json'
    if(-not(Test-Path -LiteralPath $descriptor -PathType Leaf)){return $null}
    Initialize-LifecycleProtocol
    [KiloLink.Lifecycle.SafePath]::Check($descriptor)
    $data=Get-Content -Encoding UTF8 -LiteralPath $descriptor -Raw|ConvertFrom-Json
    if($data.schemaVersion -ne 1 -or $data.productId -cne 'pc-agent' -or $Action -notin @($data.supportedActions)) {
        throw 'PC Agent lifecycle metadata does not support this request. Use its verified complete package.'
    }
    $relative=[string]$data.entryPoint
    if([IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')){throw 'PC Agent lifecycle entry must be relative to its owned directory.'}
    $path=[IO.Path]::GetFullPath((Join-Path $Directory $relative))
    if(-not $path.StartsWith([IO.Path]::GetFullPath($Directory).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($path) -ine '.exe' -or -not(Test-Path -LiteralPath $path -PathType Leaf)) {throw 'PC Agent lifecycle entry escaped its verified package or is missing.'}
    [KiloLink.Lifecycle.SafePath]::Check($path)
    if(-not(Get-PcAgentBinaryVersion $path 'NDI Configurator PC Agent')){throw 'PC Agent lifecycle executable identity is invalid.'}
    return $path
}

function New-OwnedOperationDirectory {
    $root=Join-Path $env:LOCALAPPDATA 'Kiloview Environment Setup\Operations'
    $path=Join-Path $root ([guid]::NewGuid().ToString('D'))
    Initialize-LifecycleProtocol
    [KiloLink.Lifecycle.SafePath]::CheckParent($path)
    New-Item -ItemType Directory -Path $path -Force|Out-Null
    [KiloLink.Lifecycle.SafePath]::Check($path)
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
    return $path
}

function Invoke-PcAgentLifecycle([string]$Entry,[string]$Action) {
    $directory=New-OwnedOperationDirectory
    $id=[IO.Path]::GetFileName($directory)
    $requestPath=Join-Path $directory 'request.json'
    $resultPath=Join-Path $directory 'result.json'
    Write-StateJson $requestPath @{schemaVersion=1;operationId=$id;productId='pc-agent';action=$Action;resultPath=$resultPath;preserveData=$true}
    $request=[KiloLink.Lifecycle.Request]::LoadForProduct($requestPath,'pc-agent')
    $process=Start-Process -FilePath $Entry -ArgumentList ('--lifecycle-request "'+$requestPath+'"') -WorkingDirectory (Split-Path -Parent $Entry) -WindowStyle $(if($Action -eq 'inspect'){'Hidden'}else{'Normal'}) -PassThru
    $started=[datetime]::UtcNow
    try {
        while(-not $process.HasExited) {
            if($Action -eq 'inspect' -and ([datetime]::UtcNow-$started).TotalSeconds -gt 90){
                $process.Kill();throw 'PC Agent read-only inspection exceeded its deadline.'
            }
            if($Action -ne 'inspect') {
                if(([datetime]::UtcNow-$script:LifecycleLastHeartbeat).TotalSeconds -ge 5){Write-LifecycleResult 'running' 'Waiting for PC Agent to complete its own operation. Licence and onboarding choices remain in PC Agent.' -Stage 'pc-agent'}
                if(Test-Path -LiteralPath $resultPath) {
                    $progress=$request.ReadResult()
                    $waiting=[KiloLink.Lifecycle.Request]::Text($progress,'stage') -match 'waiting|review|licen|elevation|user'
                    $stamp=[datetime]::Parse([KiloLink.Lifecycle.Request]::Text($progress,'updatedUtc')).ToUniversalTime()
                    if(-not $waiting -and ([datetime]::UtcNow-$stamp).TotalMinutes -gt 10){
                        $script:LifecycleRecoveryRequired=$true
                        Write-StateJson (Join-Path $script:StateRoot 'pending-process.json') @{processId=$process.Id;startedUtc=$process.StartTime.ToUniversalTime().ToString('o');filePath=$Entry;childResult=$resultPath}
                        throw "PC Agent stopped reporting progress. Its process was retained; inspect $resultPath before retrying."
                    }
                }
                elseif(([datetime]::UtcNow-$started).TotalMinutes -gt 10){
                    $script:LifecycleRecoveryRequired=$true
                    Write-StateJson (Join-Path $script:StateRoot 'pending-process.json') @{processId=$process.Id;startedUtc=$process.StartTime.ToUniversalTime().ToString('o');filePath=$Entry;childResult=$resultPath}
                    throw "PC Agent has not reported a result. Its process was retained; inspect $directory before retrying."
                }
            }
            Start-Sleep -Milliseconds 500
            $process.Refresh()
        }
        $result=$request.ReadResult()
        if(-not $result -or [KiloLink.Lifecycle.Request]::Text($result,'outcome') -eq 'running'){throw "PC Agent exited without a terminal correlated result. Inspect $directory"}
        $expected=[KiloLink.Lifecycle.Request]::ExitCode([KiloLink.Lifecycle.Request]::Text($result,'outcome'),[KiloLink.Lifecycle.Request]::Text($result,'errorCode'))
        if($process.ExitCode -eq 0 -and $expected -ne 0){throw 'PC Agent result and process exit code disagree.'}
        if($process.ExitCode -ne 0 -and $expected -eq 0){throw 'PC Agent reported success but its process failed.'}
        return ($result|ConvertTo-Json -Depth 15|ConvertFrom-Json)
    } finally {$process.Dispose()}
}

function Invoke-OwnedPcAgentSetup([string]$Path) {
    $entry=Get-PcAgentLifecycleEntry (Split-Path -Parent $Path) 'install'
    if(-not $entry){return Invoke-PcAgentSetup $Path}
    $action=if(Get-Variable ForceComponentRepair -ValueOnly -ErrorAction SilentlyContinue){'repair'}else{'install'}
    $entry=Get-PcAgentLifecycleEntry (Split-Path -Parent $Path) $action
    $result=Invoke-PcAgentLifecycle $entry $action
    foreach($effect in @(Get-PropertyValue $result 'partialEffects' @())){Add-LifecycleEffect ('PC Agent: '+$effect)}
    if($result.outcome -eq 'cancelled'){return $false}
    if($result.outcome -eq 'restart-required'){$script:PcAgentRestartRequired=$true;return $true}
    if($result.outcome -notin @('succeeded','no-change')){throw ('PC Agent needs attention: '+$result.message+' '+(Get-PropertyValue $result 'nextAction' ''))}
    $component=@($result.components|Where-Object productId -eq 'pc-agent')
    if($component.Count -ne 1 -or $component[0].installed -ne $true){throw 'PC Agent did not verify its installed files.'}
    if($result.outcome -eq 'succeeded'){Add-LifecycleEffect 'PC Agent installation completed and its files were verified.'}
    return $true
}
