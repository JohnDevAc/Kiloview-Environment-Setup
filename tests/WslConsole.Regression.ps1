#Requires -Version 5.1
# Real hidden-console/job tests with harmless fixtures; no WSL or servicing.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-wsl-console-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$results=New-Object Collections.Generic.List[object]
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}}
function Import-Functions([string]$Path){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) 'Source parse failed.'
    [scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object {$_.Extent.Text})) -join "`n")
}
function Wait-Until([scriptblock]$Condition){$deadline=[datetime]::UtcNow.AddSeconds(12);while(-not (& $Condition)){if([datetime]::UtcNow -gt $deadline){throw 'Fixture deadline exceeded'};Start-Sleep -Milliseconds 80}}
$wsl=Import-Functions (Join-Path $root 'src\Provisioner\20-Wsl.ps1')
$lifecycleFunctions=Import-Functions (Join-Path $root 'src\Provisioner\12-Lifecycle.ps1')
$fixture=Join-Path $testRoot 'harmless wsl fixture.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ("/out:$fixture") (Join-Path $root 'launcher\LifecycleProtocol.cs') (Join-Path $PSScriptRoot 'WslConsole.Fixture.cs')
Assert-True ($LASTEXITCODE -eq 0) 'Fixture compilation failed.'
[void][Reflection.Assembly]::LoadFile($fixture)
$hostEntry=Join-Path $testRoot 'FixtureHostEntry.cs'
@'
internal static class FixtureHostEntry {
    static int Main(string[] args) {
        if(System.Environment.GetEnvironmentVariable("KILOVIEW_WSL_FIXTURE_MODE")=="supervisor-crash") {
            new System.Threading.Thread(delegate() {
                string evidence=System.Environment.GetEnvironmentVariable("KILOVIEW_WSL_FIXTURE_OUTPUT");
                while(!System.IO.File.Exists(evidence)){System.Threading.Thread.Sleep(20);}
                System.Threading.Thread.Sleep(150);System.Environment.Exit(99);
            }) {IsBackground=true}.Start();
        }
        return KiloLink.Lifecycle.WslBootstrapHost.Run(System.Environment.GetEnvironmentVariable("KILOVIEW_WSL_FIXTURE_BINARY"),
            new string[]{"--install","--no-distribution","--web-download"},args[0],args[1]);
    }
}
'@|Set-Content -LiteralPath $hostEntry -Encoding UTF8
$hostFixture=Join-Path $testRoot 'harmless supervisor.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /main:FixtureHostEntry /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ("/out:$hostFixture") (Join-Path $root 'launcher\LifecycleProtocol.cs') (Join-Path $root 'launcher\WslBootstrapHost.cs') $hostEntry
Assert-True ($LASTEXITCODE -eq 0) 'Supervisor fixture compilation failed.'
$savedMode=$env:KILOVIEW_WSL_FIXTURE_MODE;$savedOutput=$env:KILOVIEW_WSL_FIXTURE_OUTPUT
$savedBinary=$env:KILOVIEW_WSL_FIXTURE_BINARY;$env:KILOVIEW_WSL_FIXTURE_BINARY=$fixture
try {
    foreach($mode in @('normal','descendant','dispose-active')) {
        Test-Case "Actual console and descendant ownership: $mode" {
            $env:KILOVIEW_WSL_FIXTURE_OUTPUT=Join-Path $testRoot ($mode+'.json')
            $env:KILOVIEW_WSL_FIXTURE_MODE=if($mode -eq 'normal'){'normal'}else{'descendant'}
            $job='Global\KiloviewWslBootstrap_'+[guid]::NewGuid().ToString('N')
            $owned=New-Object KiloLink.Lifecycle.ConsoleBootstrapProcess($fixture,[string[]]@('--install','--no-distribution','--web-download'),$job)
            try {
                Wait-Until {Test-Path -LiteralPath $env:KILOVIEW_WSL_FIXTURE_OUTPUT}
                $wire=Get-Content -LiteralPath $env:KILOVIEW_WSL_FIXTURE_OUTPUT -Raw|ConvertFrom-Json
                Assert-True ($wire.stdinConsole -and $wire.stdoutConsole -and $wire.hasConsole -and -not $wire.visible -and $wire.desktop -like 'KiloviewWsl_*') 'Fixture did not get a real hidden private console.'
                Assert-True (($wire.arguments -join '|') -ceq '--install|--no-distribution|--web-download') 'Console argument transport changed.'
                if($mode -ne 'normal') {
                    Wait-Until {Test-Path -LiteralPath ($env:KILOVIEW_WSL_FIXTURE_OUTPUT+'.child.json')}
                    Start-Sleep -Milliseconds 150
                    Assert-True (-not $owned.HasExited -and [KiloLink.Lifecycle.ConsoleBootstrapProcess]::IsJobActive($job)) 'A root exit abandoned its active descendant.'
                    if($mode -eq 'dispose-active') {
                        $owned.Dispose();$owned=$null
                        # A job's name becomes inaccessible after the last handle
                        # closes. Production therefore keeps an independent host.
                        Wait-Until { (Get-Content -LiteralPath ($env:KILOVIEW_WSL_FIXTURE_OUTPUT+'.child.json') -Raw|ConvertFrom-Json).complete }
                    }
                }
                Wait-Until {-not [KiloLink.Lifecycle.ConsoleBootstrapProcess]::IsJobActive($job)}
                if($null -ne $owned){Assert-True ($owned.HasExited -and $owned.ExitCode -eq 0) 'Bootstrap did not finish cleanly.'}
                if($mode -ne 'normal') { Assert-True ((Get-Content -LiteralPath ($env:KILOVIEW_WSL_FIXTURE_OUTPUT+'.child.json') -Raw|ConvertFrom-Json).complete) 'Descendant was killed before completion.' }
            } finally {if($null -ne $owned){$owned.Dispose()}}
        }
    }
    foreach($mode in @('success','failure','restart','timeout','heartbeat-failure','second-write-failure','first-write-failure','start-failure','supervisor-crash')) {
        Test-Case "Actual PowerShell bootstrap ownership and recovery: $mode" {
            . $wsl;. $lifecycleFunctions
            function Initialize-LifecycleProtocol { }
            function Get-PropertyValue($Object,$Name,$Default){if($Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default}}
            function Get-Command { [pscustomobject]@{Source=$(if($mode -eq 'start-failure'){Join-Path $testRoot 'nonexistent.exe'}else{$fixture})} }
            function New-WslBootstrapHost {
                $copy=Join-Path $script:StateRoot 'supervisor.exe'
                if($mode -ne 'start-failure'){Copy-Item -LiteralPath $hostFixture -Destination $copy}
                return $copy
            }
            function Write-InstallerLog { }
            $script:StateRoot=Join-Path $testRoot $mode;New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
            $script:Lifecycle=$null;$Action='Resume';$script:LifecycleRecoveryRequired=$false;$script:LifecycleErrorCode='';$script:LifecycleNextAction=''
            $script:Writes=0;$script:Pulses=0
            function Write-StateJson($Path,$Value){
                $script:Writes++
                if(($mode -eq 'first-write-failure' -and $script:Writes -eq 1) -or ($mode -eq 'second-write-failure' -and $script:Writes -eq 2)){$script:LifecycleErrorCode='lifecycle-result-write-failed';throw 'Fixture persistence failure'}
                $Value|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $Path -Encoding UTF8
            }
            function Update-SuiteProgressPulse {$script:Pulses++;if($mode -eq 'heartbeat-failure'){$script:LifecycleErrorCode='lifecycle-result-write-failed';throw 'Fixture heartbeat failure'}}
            $env:KILOVIEW_WSL_FIXTURE_OUTPUT=Join-Path $script:StateRoot 'child.json'
            $env:KILOVIEW_WSL_FIXTURE_MODE=switch($mode){'failure'{'failure'} 'restart'{'restart'} 'timeout'{'descendant'} 'supervisor-crash'{'supervisor-crash'} {$_ -in @('heartbeat-failure','second-write-failure')}{'slow'} default{'normal'}}
            $failure=$null;$code=$null
            try{$code=Invoke-WslRuntimeBootstrap -TimeoutSeconds $(if($mode -eq 'timeout'){1}else{8})}catch{$failure=$_.Exception.Message}
            $pendingPath=Join-Path $script:StateRoot 'pending-process.json'
            if($mode -eq 'supervisor-crash') {
                Assert-True ($failure -and $script:LifecycleRecoveryRequired -and (Test-Path -LiteralPath $pendingPath)) 'Supervisor crash became a safe terminal failure.'
                $Action='Verify';$blocked=$false;try{Assert-NoPendingNativeProcess}catch{$blocked=$_.Exception.Message -match 'no confirmed process-tree completion'}
                Assert-True $blocked 'Verify accepted a crashed supervisor without completion evidence.'
                $child=Get-Content -LiteralPath $env:KILOVIEW_WSL_FIXTURE_OUTPUT -Raw|ConvertFrom-Json
                Wait-Until {-not(Get-Process -Id $child.processId -ErrorAction SilentlyContinue)}
            } elseif($mode -in @('timeout','heartbeat-failure','second-write-failure')) {
                Assert-True ($failure -and $script:LifecycleRecoveryRequired -and (Test-Path -LiteralPath $pendingPath)) 'An active bootstrap lost recovery ownership.'
                $pending=Get-Content -LiteralPath $pendingPath -Raw|ConvertFrom-Json
                Wait-Until {[KiloLink.Lifecycle.ConsoleBootstrapProcess]::IsJobActive($pending.jobName)}
                Assert-True ($script:LifecycleErrorCode -eq $(if($mode -eq 'timeout'){'command-timeout'}else{'lifecycle-result-write-failed'})) 'Original failure code was replaced.'
                $Action='Verify';$blocked=$false;try{Assert-NoPendingNativeProcess}catch{$blocked=$_.Exception.Message -match 'still running'}
                Assert-True $blocked 'Verify accepted a live descendant.'
                Wait-Until {-not [KiloLink.Lifecycle.ConsoleBootstrapProcess]::IsJobActive($pending.jobName)}
                Wait-Until { $receipt=Get-WslBootstrapReceipt $pending;$receipt -and $receipt.phase -eq 'completed' }
                $finishedReceipt=Get-WslBootstrapReceipt $pending
                Wait-Until {-not(Get-Process -Id $finishedReceipt.hostProcessId -ErrorAction SilentlyContinue)}
                Assert-NoPendingNativeProcess
                Assert-True (Test-Path -LiteralPath $pendingPath) 'Read-only verification consumed recovery evidence.'
            } else {
                Assert-True (-not(Test-Path -LiteralPath $pendingPath) -and -not $script:LifecycleRecoveryRequired) 'Completed or unstarted fixture retained false active ownership.'
                if($mode -in @('success','restart')) {Assert-True (-not $failure -and $code -eq $(if($mode -eq 'restart'){3010}else{0})) 'Exit code was not preserved.'}
                else {Assert-True ([bool]$failure) 'Expected fixture failure was hidden.'}
                if($mode -in @('first-write-failure','start-failure')){Assert-True (-not(Test-Path -LiteralPath $env:KILOVIEW_WSL_FIXTURE_OUTPUT)) 'Fixture started without durable ownership.'}
            }
        }
    }
    foreach($mode in @('missing','running','wrong-job','completed')) {
        Test-Case "Recovery requires durable supervisor completion: $mode" {
            . $wsl;. $lifecycleFunctions
            function Initialize-LifecycleProtocol { }
            function Get-PropertyValue($Object,$Name,$Default){if($Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default}}
            $script:StateRoot=Join-Path $testRoot ('receipt-'+$mode);New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
            $job='Global\KiloviewWslBootstrap_'+[guid]::NewGuid().ToString('N')
            $receiptPath=Join-Path $script:StateRoot 'receipt.json'
            @{processId=0;startedUtc=$null;jobName=$job;bootstrapResult=$receiptPath}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $script:StateRoot 'pending-process.json')
            if($mode -ne 'missing'){@{schemaVersion=1;jobName=$(if($mode -eq 'wrong-job'){'different'}else{$job});phase=$(if($mode -eq 'running'){'running'}else{'completed'});hostProcessId=0;hostStartedUtc=''}|ConvertTo-Json|Set-Content -LiteralPath $receiptPath}
            $Action='Verify';$failure=$null
            try{Assert-NoPendingNativeProcess}catch{$failure=$_.Exception.Message}
            Assert-True (([bool]$failure) -eq ($mode -ne 'completed')) 'Unconfirmed supervisor completion became safe to retry.'
        }
    }
    Test-Case 'Actual generated engine compiles the embedded supervisor without running it' {
        $generated=Import-Functions (Join-Path $root 'Install-KiloLinkSuite.ps1')
        . $generated
        function Initialize-LifecycleProtocol { }
        function New-OwnedOperationDirectory {$path=Join-Path $testRoot 'generated-supervisor';New-Item -ItemType Directory -Path $path|Out-Null;return $path}
        $built=New-WslBootstrapHost
        Assert-True (Test-Path -LiteralPath $built -PathType Leaf) 'Embedded supervisor compilation produced no file.'
        Assert-True (([Reflection.AssemblyName]::GetAssemblyName($built)).Name -eq 'WslBootstrapHost') 'Generated supervisor is not a managed executable.'
    }
    foreach($mode in @('absent','broken-service','registered-without-cli','service','appx','evidence-denied')) {
        Test-Case "Passive runtime detection and probe gating: $mode" {
            . $wsl
            function Test-Path($LiteralPath,$PathType){
                if($LiteralPath -like 'HKLM:*'){return $mode -in @('service','broken-service','registered-without-cli','evidence-denied')}
                if($LiteralPath -eq 'C:\WSL\wslservice.exe'){return $mode -in @('service','registered-without-cli')}
                if($LiteralPath -eq 'C:\WSL\wsl.exe'){return $mode -eq 'service'}
                if($LiteralPath -eq 'C:\Appx\wsl.exe'){return $mode -eq 'appx'}
                throw "Unexpected static path $LiteralPath"
            }
            function Get-ItemProperty {if($mode -eq 'evidence-denied'){throw 'Fixture access denied'};[pscustomobject]@{ImagePath='"C:\WSL\wslservice.exe"'}}
            function Get-Command { [pscustomobject]@{Name='fixture'} }
            function Get-AppxPackage {if($mode -eq 'appx'){[pscustomobject]@{InstallLocation='C:\Appx'}}}
            $script:ProbeCalls=0
            function Invoke-Native {$script:ProbeCalls++;$global:LASTEXITCODE=0;'KiloLink-Ubuntu'}
            if($mode -eq 'evidence-denied') {
                $failure=$null;try{Test-WslRuntime|Out-Null}catch{$failure=$_.Exception.Message}
                Assert-True ($failure -match 'access denied' -and $script:ProbeCalls -eq 0) 'Denied evidence launched the stub or became healthy.'
            } else {
                $ready=Test-WslRuntime;$names=@(Get-WslDistroNames)
                $installed=$mode -in @('service','appx')
                Assert-True ($ready -eq $installed -and $script:ProbeCalls -eq $(if($installed){2}else{0}) -and $names.Count -eq $(if($installed){1}else{0})) 'Missing-runtime stub was invoked or real runtime was skipped.'
            }
        }
    }
} finally {$env:KILOVIEW_WSL_FIXTURE_MODE=$savedMode;$env:KILOVIEW_WSL_FIXTURE_OUTPUT=$savedOutput;$env:KILOVIEW_WSL_FIXTURE_BINARY=$savedBinary}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} WSL console checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
