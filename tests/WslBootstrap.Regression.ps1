#Requires -Version 5.1
# Actual native command-line transport plus isolated runtime orchestration.
# Does not execute wsl.exe, Windows servicing, downloads or a real reboot.
param([string]$ProtocolSource)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $ProtocolSource){$ProtocolSource=Join-Path $root 'launcher\LifecycleProtocol.cs'}
$testRoot=Join-Path $env:TEMP ('kiloview-wsl-bootstrap-'+[guid]::NewGuid().ToString('N'))
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
$linux=Import-SourceFunctions (Join-Path $root 'src\Provisioner\40-Linux.ps1')
$exe=Join-Path $testRoot 'native argument fixture.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ("/out:$exe") $ProtocolSource (Join-Path $PSScriptRoot 'NativeArguments.Fixture.cs')
Assert-True ($LASTEXITCODE -eq 0) 'Native fixture compilation failed.'
[void][Reflection.Assembly]::LoadFile($exe)
Test-Case 'Actual runner dispatches WSL bootstrap switches as unquoted native tokens' {
    . $core
    function Initialize-LifecycleProtocol { }
    function Write-InstallerLog { }
    function Update-SuiteProgressPulse { }
    $wire=Invoke-Native $exe @('--install','--no-distribution','--web-download') -Capture -ReadOnly -TimeoutSeconds 10 -StallSeconds 5|ConvertFrom-Json
    Assert-True ($wire.rawArguments -ceq '--install --no-distribution --web-download') 'Missing-runtime bootstrap command was altered.'
    Assert-True (($wire.arguments -join '|') -ceq '--install|--no-distribution|--web-download') 'Native argv changed.'
    $wire|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'bootstrap-command.json') -Encoding UTF8
}
Test-Case 'Actual runner keeps WSL management verbs recognizable' {
    . $core
    function Initialize-LifecycleProtocol { }
    function Write-InstallerLog { }
    function Update-SuiteProgressPulse { }
    foreach($verb in @('--status','--list','--update','--set-default-version','--distribution','--terminate','--unregister')){
        $wire=Invoke-Native $exe @($verb) -Capture -ReadOnly -TimeoutSeconds 10 -StallSeconds 5|ConvertFrom-Json
        Assert-True ($wire.rawVerb -ceq $verb) "Native verb was not recognized: $verb"
    }
}
Test-Case 'Actual native argv retains empty, spaced, quoted, Unicode and trailing-backslash data' {
    . $core
    function Initialize-LifecycleProtocol { }
    function Write-InstallerLog { }
    function Update-SuiteProgressPulse { }
    $values=[string[]]@('--fixture','','two words','quote " in text','C:\directory with spaces\','no-spaces\',"tab`tvalue",('Unicode '+[char]0x65e5),'a&b|c;d')
    $wire=Invoke-Native $exe $values -Capture -ReadOnly -TimeoutSeconds 10 -StallSeconds 5|ConvertFrom-Json
    Assert-True ($wire.arguments.Count -eq $values.Count) 'Native argv count changed.'
    for($i=0;$i -lt $values.Count;$i++){Assert-True ($wire.arguments[$i] -ceq $values[$i]) "Native argv value changed at index $i"}
}
foreach($mode in @('missing-runtime','current-runtime','bootstrap-failure','command-timeout','lifecycle-result-write-failed','needs-restart','bootstrap-restart','runtime-still-absent')){
    Test-Case "Missing WSL runtime orchestration and guidance: $mode" {
        . $linux
        $Action='Repair';$script:RuntimeReady=$mode -eq 'current-runtime';$script:ProgressPercent=12
        $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:LifecycleRecoveryRequired=$false
        $script:WslCalls=New-Object Collections.Generic.List[object];$script:RestartRequests=0
        function Test-SupportedWindows { }
        function Write-Step { }
        function Write-Detail { }
        function Write-InstallerLog { }
        function Set-SuiteProgress { }
        function Get-Command { [pscustomobject]@{Name='wsl.exe'} }
        function Get-WindowsOptionalFeature { [pscustomobject]@{State='Enabled'} }
        function Enable-WindowsOptionalFeature {throw 'Unexpected feature mutation'}
        function Test-WslRuntime {$script:RuntimeReady}
        function Test-WslRuntimeInstalled { $mode -ne 'runtime-still-absent' }
        function Wait-WslRuntime {$script:RuntimeReady}
        function Invoke-WslRuntimeBootstrap { Invoke-Native wsl.exe @('--install','--no-distribution','--web-download'); if($mode -eq 'bootstrap-restart'){return 3010}; return 0 }
        function Request-RestartAndResume {$script:RestartRequests++}
        function Invoke-Native($FilePath,[string[]]$Arguments){
            $script:WslCalls.Add([pscustomobject]@{FilePath=$FilePath;Arguments=$Arguments})
            if($Arguments[0] -eq '--install'){
                if($mode -eq 'bootstrap-failure'){throw 'Fixture original bootstrap error'}
                if($mode -in @('command-timeout','lifecycle-result-write-failed')){
                    $script:LifecycleErrorCode=$mode;$script:LifecycleNextAction='Original owner recovery guidance'
                    $script:LifecycleRecoveryRequired=$mode -eq 'command-timeout'
                    throw 'Fixture original ownership error'
                }
                $script:RuntimeReady=$mode -notin @('needs-restart','runtime-still-absent')
            }
        }
        $failure=$null;$ready=$null
        try{$ready=Ensure-WslFeatures}catch{$failure=$_.Exception.Message}
        $installs=@($script:WslCalls|Where-Object {$_.Arguments[0] -eq '--install'})
        Assert-True ($installs.Count -eq $(if($mode -eq 'current-runtime'){0}else{1})) 'Runtime was redundantly installed or skipped.'
        if($installs.Count){Assert-True (($installs[0].Arguments -join '|') -ceq '--install|--no-distribution|--web-download') 'Bootstrap used a default distro or different source path.'}
        if($mode -eq 'bootstrap-failure'){
            Assert-True ($failure -match 'Fixture original bootstrap error' -and $script:LifecycleErrorCode -eq 'wsl-runtime-install-failed' -and $script:LifecycleNextAction -match 'retry Server setup') 'Bootstrap failure lost its cause or actionable guidance.'
        }elseif($mode -in @('command-timeout','lifecycle-result-write-failed')){
            Assert-True ($failure -eq 'Fixture original ownership error' -and $script:LifecycleErrorCode -eq $mode -and $script:LifecycleNextAction -eq 'Original owner recovery guidance') 'Supervisor/result persistence failure was overwritten.'
            Assert-True ($script:LifecycleRecoveryRequired -eq ($mode -eq 'command-timeout')) 'Process recovery ownership changed.'
        }elseif($mode -eq 'runtime-still-absent'){
            Assert-True ($failure -match 'not detected' -and $script:LifecycleErrorCode -eq 'wsl-runtime-install-failed') 'Absent runtime was treated as a successful install or a reboot loop.'
        }else{
            Assert-True (-not $failure) $failure
            Assert-True (($ready -eq $true) -eq ($mode -notin @('needs-restart','bootstrap-restart'))) 'Runtime readiness was incorrectly reported.'
        }
        Assert-True ($script:RestartRequests -eq $(if($mode -in @('needs-restart','bootstrap-restart')){1}else{0})) 'Restart continuation behavior changed.'
        if($failure -or $mode -in @('needs-restart','bootstrap-restart')){Assert-True ($script:WslCalls.Count -eq 1) 'Later WSL commands ran before runtime readiness.'}
    }
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} WSL bootstrap checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
