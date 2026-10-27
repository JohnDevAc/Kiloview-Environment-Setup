# Included by Installer.Regression.ps1. All writes are inside its owned fixture root.
function New-LifecycleFixture([string]$Action='inspect') {
    Initialize-LifecycleProtocol
    $directory=Join-Path $testRoot ('operation-'+[guid]::NewGuid().ToString('D')+'-'+[char]0x00e9+[char]0x65e5)
    New-Item -ItemType Directory -Path $directory|Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
    $request=Join-Path $directory 'request.json'
    $data=@{schemaVersion=1;operationId=[guid]::NewGuid().ToString('D');productId='environment';action=$Action;resultPath=(Join-Path $directory 'result.json')}
    [IO.File]::WriteAllText($request,($data|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{Directory=$directory;Path=$request;Data=$data;Request=[KiloLink.Lifecycle.Request]::Load($request)}
}
Test-Case 'Lifecycle script uses the reviewed Client role when request leaves selection to the owner' {
    # The real entry point holds Action at script scope. Do not let the test
    # harness's parent-local Menu variable shadow the initializer's update.
    Remove-Variable -Name Action -Scope 1
    $PurgeData=$false
    try {
        foreach($actionName in @('install','update','repair')) {
            $fixture=New-LifecycleFixture $actionName
            $script:Lifecycle=$null
            $script:LifecycleRequestPath=$fixture.Path
            $script:Role='client'
            $script:Action='Menu'
            Initialize-Lifecycle
            Assert-True ($script:Action -eq 'InstallClient') 'Reviewed Client selection routed into server maintenance.'
        }
    } finally {
        $script:Lifecycle=$null
        $script:LifecycleRequestPath=''
        $script:Role=''
        $script:ForceComponentRepair=$false
        $script:Action='Menu'
    }
}
Test-Case 'Lifecycle results are atomic, correlated and retain the operation on resume' {
    $fixture=New-LifecycleFixture
    $request=$fixture.Request
    $request.Write('running','Inspecting','inspect','','','{}')
    $request.ContinueAttempt()
    $request.Write('succeeded','Inspected','inspect','','','{"components":[]}')
    $result=Get-Content -LiteralPath $request.ResultPath -Raw|ConvertFrom-Json
    Assert-True ($result.operationId -eq $fixture.Data.operationId -and $result.attempt -eq 2 -and $result.outcome -eq 'succeeded') 'Continuation identity or outcome was lost.'
    Assert-True (@(Get-ChildItem -LiteralPath $fixture.Directory -Filter '*.tmp').Count -eq 0) 'Atomic replacement left a temporary result.'
    Assert-Throws {$request.AtomicWrite($fixture.Path.ToUpperInvariant(),'bad')} 'escaped'
}
Test-Case 'Lifecycle rejects mismatched prior results without overwriting them' {
    $fixture=New-LifecycleFixture
    $fixture.Request.Write('running','Fixture','inspect','','','{}')
    $json=Get-Content -LiteralPath $fixture.Request.ResultPath -Raw|ConvertFrom-Json
    $json.operationId=[guid]::NewGuid().ToString('D')
    [IO.File]::WriteAllText($fixture.Request.ResultPath,($json|ConvertTo-Json))
    $before=(Get-FileHash -LiteralPath $fixture.Request.ResultPath).Hash
    Assert-Throws {$fixture.Request.Write('succeeded','bad','','','','{}')} 'mismatched'
    Assert-True ((Get-FileHash -LiteralPath $fixture.Request.ResultPath).Hash -eq $before) 'A stale result was overwritten.'
}
Test-Case 'Lifecycle refuses unsupported schema, escaping results and writable foreign ACLs' {
    foreach($mode in @('schema','escape','acl')) {
        $fixture=New-LifecycleFixture
        switch($mode){
            schema {$fixture.Data.schemaVersion='1'}
            escape {$fixture.Data.resultPath=Join-Path $testRoot 'outside.json'}
            acl {
                $acl=[IO.Directory]::GetAccessControl($fixture.Directory,[Security.AccessControl.AccessControlSections]::Access)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),'Write','Allow'))
                [IO.Directory]::SetAccessControl($fixture.Directory,$acl)
            }
        }
        [IO.File]::WriteAllText($fixture.Path,($fixture.Data|ConvertTo-Json))
        Assert-Throws {[KiloLink.Lifecycle.Request]::Load($fixture.Path)} 'Unsupported|owned operation directory|another account'
    }
}
Test-Case 'Path safety accepts only known cloud tags and rejects actual junction traversal' {
    Initialize-LifecycleProtocol
    foreach($tag in @([uint32]0x9000001aL,[uint32]0x9000601aL,[uint32]0x9000f01aL)){Assert-True ([KiloLink.Lifecycle.SafePath]::IsAllowedCloudTag($tag)) 'Known cloud placeholder rejected.'}
    foreach($tag in @([uint32]0xa0000003L,[uint32]0xa000000cL,[uint32]0x9000102aL)){Assert-True (-not[KiloLink.Lifecycle.SafePath]::IsAllowedCloudTag($tag)) 'Redirecting/unknown tag accepted.'}
    $fixture=New-LifecycleFixture
    $junction=Join-Path $testRoot ('junction-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Junction -Path $junction -Target $fixture.Directory|Out-Null
    Assert-Throws {[KiloLink.Lifecycle.Request]::Load((Join-Path $junction 'request.json'))} 'unsupported link|reparse'
}
Test-Case 'Cancellation differs from partial completion and conflict exit codes' {
    Set-OperationOutcome 'Cancelled' 'Fixture cancel'
    Assert-True ((Get-InstallerExitCode) -eq 1602) 'Cancellation returned success.'
    Add-LifecycleEffect 'NDI changed'
    Assert-True ((Get-InstallerExitCode) -eq 1 -and (Get-LifecycleResultOutcome 'Cancelled') -eq 'partial') 'Partial cancellation returned ordinary success/cancel.'
    $script:LifecycleErrorCode='operation-conflict'
    Assert-True ((Get-InstallerExitCode) -eq 1618) 'Conflict did not retain Windows installer conflict semantics.'
}
Test-Case 'Inspection allows retry after preflight-only crash but requires verification after mutation' {
    function Get-ObservedComponents { @() }
    function Get-ServerOwnerSid { $null }
    Start-DeploymentJournal 'Update' $null
    Assert-True (Get-LifecycleInspection).safeToRetry 'A preflight-only interrupted request cannot be retried.'
    $script:ActiveJournal.mutationStarted=$true;Save-DeploymentJournal
    $inspection=Get-LifecycleInspection
    Assert-True ($inspection.recoveryRequired -and -not $inspection.safeToRetry -and $inspection.nextAction -match 'Verify') 'An interrupted mutation was force-unlocked or lacks an owner recovery path.'
}
Test-Case 'Bounded native runner drains both streams, preserves quoting and stops only timed-out probes' {
    Invoke-Expression ($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Native'},$true).Extent.Text)
    $shell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath=Join-Path $testRoot 'native argument fixture.ps1'
    [IO.File]::WriteAllText($scriptPath,'param([string]$Value) [Console]::Out.WriteLine($Value); [Console]::Error.WriteLine("stderr fixture"); exit 7')
    $output=Invoke-Native $shell @('-NoProfile','-File',$scriptPath,'quote " and slash\') -Capture -IgnoreExitCode -ReadOnly -TimeoutSeconds 15
    Assert-True ($LASTEXITCODE -eq 7 -and $output -contains 'quote " and slash\' -and $output -contains 'stderr fixture') 'Native output/arguments/exit code changed.'
    $started=[datetime]::UtcNow
    Assert-Throws {Invoke-Native $shell @('-NoProfile','-Command','Start-Sleep -Seconds 30') -ReadOnly -TimeoutSeconds 1 -StallSeconds 1} 'time limit'
    Assert-True (([datetime]::UtcNow-$started).TotalSeconds -lt 8 -and -not(Test-Path (Join-Path $script:StateRoot 'pending-process.json'))) 'A harmless timed-out probe hung or created mutation recovery state.'
}
Test-Case 'Unconfirmed remove-app never invokes Windows Installer' {
    function Get-ConfigurationProducts { @('{12345678-1234-1234-1234-123456789012}') }
    Assert-Throws {Remove-ConfigurationApp} 'Retained maintenance is missing'
}
Test-Case 'Default server removal stops services, preserves data and owner, and can be repeated safely' {
    $Action='Uninstall';$PurgeData=$false;$LauncherMode=$true
    Save-Config (New-Config)
    function Get-UbuntuDistro {'KiloLink-Ubuntu'}
    function Get-WslDistroNames {'KiloLink-Ubuntu'}
    function Test-KiloContainer {$true}
    function Stop-ManagedTask { }
    function Restore-DiscoveryOwnership { }
    function Get-NetFirewallRule {@()}
    function Get-NetFirewallHyperVRule {@()}
    function Remove-NetFirewallRule { }
    function Remove-NetFirewallHyperVRule { }
    function Remove-LegacyPortProxies { }
    function Remove-OwnedFile {param($Path) if($Path.StartsWith($testRoot+'\',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $Path)){Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Force}}
    $script:Stops=0
    function Invoke-Wsl {param($Distro,$Command,[switch]$Capture)
        if($Capture){'false no'}else{Assert-True ($Command -match 'docker update --restart=no' -and $Command -match 'docker stop' -and $Command -notmatch 'rm ' ) 'Preserved role removal deleted container/data';$script:Stops++}
    }
    Uninstall-Suite -Confirmed
    $retained=Get-Content -LiteralPath (Join-Path $script:StateRoot 'retained-server.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-True ($script:Stops -eq 1 -and -not(Get-SavedConfig) -and $retained.configuration.PublicIp -eq '192.0.2.10' -and -not $retained.active) 'Inactive retained deployment was not recorded correctly.'
    Assert-True ((Get-ServerOwnerSid) -eq (Get-CurrentUserSid)) 'Retained WSL environment lost its owner.'
    $before=(Get-FileHash -LiteralPath (Join-Path $script:StateRoot 'retained-server.json')).Hash
    Uninstall-Suite -Confirmed
    Assert-True ($script:OperationOutcome -eq 'NoChange' -and $script:Stops -eq 1 -and (Get-FileHash -LiteralPath (Join-Path $script:StateRoot 'retained-server.json')).Hash -eq $before) 'Repeated preservation changed retained configuration or services.'
}
Test-Case 'Lifecycle hard-linked input cannot alias another owned file' {
    $fixture=New-LifecycleFixture
    $alias=Join-Path $fixture.Directory 'alias.json'
    New-Item -ItemType HardLink -Path $alias -Target $fixture.Path|Out-Null
    Assert-Throws {[KiloLink.Lifecycle.Request]::Load($fixture.Path)} 'hard links'
}
Test-Case 'Current Client detects the actual NDI shipped executable names and missing files' {
    $directory=Join-Path $testRoot ('ndi-client-'+[guid]::NewGuid().ToString('N'))
    $access=Join-Path $directory 'Access Manager\Application.NdiGroupEditor.exe'
    $monitor=Join-Path $directory 'Studio Monitor\Application.Network.StudioMonitor.x64.exe'
    foreach($file in @($access,$monitor)){New-Item -ItemType Directory -Path (Split-Path $file) -Force|Out-Null;[IO.File]::WriteAllText($file,'fixture')}
    function Get-NdiToolsFiles {Get-ChildItem -LiteralPath $directory -File -Recurse}
    Assert-True (Test-NdiClientToolsReady) 'The shipped NDI filenames would cause unnecessary repair/download.'
    Remove-Item -LiteralPath $monitor
    Assert-True (-not(Test-NdiClientToolsReady)) 'Missing Studio Monitor was reported complete.'
}
Test-Case 'Bridge Discovery helper is not treated as the managed Discovery service' {
    $directory=Join-Path $testRoot ('ndi-bridge-'+[guid]::NewGuid().ToString('N'))
    $discovery=Join-Path $directory 'Discovery Service\NDI Discovery Service.exe'
    $bridge=Join-Path $directory 'Bridge\NDI Discovery Service.exe'
    foreach($file in @($discovery,$bridge)){New-Item -ItemType Directory -Path (Split-Path $file) -Force|Out-Null;[IO.File]::WriteAllText($file,'fixture')}
    function Get-NdiToolsFiles {Get-ChildItem -LiteralPath $directory -File -Recurse}
    Invoke-Expression ($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-NdiDiscoveryExe'},$true).Extent.Text)
    Assert-True ((Get-NdiDiscoveryExe) -eq $discovery) 'Bridge helper won the managed service selection.'
    Remove-Item -LiteralPath $discovery
    Assert-True ($null -eq (Get-NdiDiscoveryExe)) 'Bridge helper concealed the missing managed Discovery component.'
}
