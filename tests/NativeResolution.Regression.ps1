#Requires -Version 5.1
# Real PS5.1 PATH resolution and real native children; never invokes real WSL.
param([string]$EnginePath)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run the resolution regression in Windows PowerShell 5.1.'}
$root=Split-Path -Parent $PSScriptRoot
if(-not $EnginePath){$EnginePath=Join-Path $root 'Install-KiloLinkSuite.ps1'}
$testRoot=Join-Path $env:TEMP ('kiloview-native-resolution-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($EnginePath),[ref]$tokens,[ref]$errors)
Assert-True (-not $errors.Count) 'Engine parse failed.'
$wanted=@('Initialize-LifecycleProtocol','Invoke-Native','Test-WslRuntime','Get-WslDistroNames','Write-WslProbeFailure')
$definitions=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $wanted})
$engineFunctions=[scriptblock]::Create(($definitions|ForEach-Object {$_.Extent.Text}) -join "`n")
. $engineFunctions
Initialize-LifecycleProtocol
$script:NativeTimeoutSeconds=5;$script:NativeStallSeconds=5;$script:LifecycleNextAction=''
$a=Join-Path $testRoot 'first path';$b=Join-Path $testRoot 'second path';New-Item -ItemType Directory -Path $a,$b|Out-Null
$fixtureName='kiloview-resolution-fixture.exe';$first=Join-Path $a $fixtureName;$second=Join-Path $b $fixtureName
Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Web.Script.Serialization;
internal static class ResolutionFixture {
 static int Main(string[] args){
  int code;Int32.TryParse(Environment.GetEnvironmentVariable("KILOVIEW_RESOLUTION_EXIT"),out code);
  if(code==0){Console.WriteLine(new JavaScriptSerializer().Serialize(new {file=Process.GetCurrentProcess().MainModule.FileName,arguments=args}));}
  return code;
 }
}
'@ -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll') -OutputAssembly $first -OutputType ConsoleApplication
Copy-Item -LiteralPath $first -Destination $second
Copy-Item -LiteralPath $first -Destination (Join-Path $a 'wsl.exe')
Copy-Item -LiteralPath $first -Destination (Join-Path $b 'wsl.exe')
$priorPath=$env:PATH;$priorExit=$env:KILOVIEW_RESOLUTION_EXIT
try{
    foreach($mode in @('single','multiple','reversed','explicit-path')){
        Test-Case "Real Get-Command and native execution: $mode" {
            . $engineFunctions
            function Update-SuiteProgressPulse { }
            function Write-InstallerLog { }
            $env:KILOVIEW_RESOLUTION_EXIT='0'
            $env:PATH=$(if($mode -eq 'single'){$a}elseif($mode -eq 'reversed'){$b+';'+$a}else{$a+';'+$b})+';'+$priorPath
            $target=if($mode -eq 'explicit-path'){$second}else{$fixtureName}
            $resolved=@(Get-Command $target -CommandType Application -ErrorAction Stop)
            $expected=if($mode -in @('reversed','explicit-path')){$second}else{$first}
            Assert-True ($resolved[0].Source -ieq $expected) 'Fixture PATH precedence was not established.'
            Assert-True ($resolved.Count -eq $(if($mode -in @('single','explicit-path')){1}else{2})) 'Actual PowerShell resolution cardinality differs.'
            $wire=Invoke-Native $target @('--status') -Capture -ReadOnly -TimeoutSeconds 5 -StallSeconds 5|ConvertFrom-Json
            Assert-True ($wire.file -ieq $expected -and ($wire.arguments -join '|') -ceq '--status' -and $global:LASTEXITCODE -eq 0) 'The runner did not execute exactly the first intended application.'
        }
    }
    Test-Case 'Actual readiness succeeds with multiple harmless WSL executables on PATH' {
        . $engineFunctions
        function Test-WslRuntimeInstalled {$true}
        function Update-SuiteProgressPulse { }
        $script:Logs=New-Object 'Collections.Generic.List[string]'
        function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
        $env:PATH=$a+';'+$b+';'+$priorPath;$env:KILOVIEW_RESOLUTION_EXIT='0'
        $resolved=@(Get-Command wsl.exe -CommandType Application -ErrorAction Stop)
        Assert-True ($resolved.Count -ge 2 -and $resolved[0].Source -ieq (Join-Path $a 'wsl.exe')) 'The first WSL command is not the harmless fixture; refusing to run.'
        Assert-True (Test-WslRuntime) 'A successful real readiness child was reported unavailable.'
        $wire=$script:Logs[0]|ConvertFrom-Json
        Assert-True ($wire.file -ieq (Join-Path $a 'wsl.exe') -and ($wire.arguments -join '|') -ceq '--status') 'Readiness did not use the intended first executable.'
    }
    Test-Case 'Output-free native failures log exit codes once per probe interval' {
        . $engineFunctions
        function Test-WslRuntimeInstalled {$true}
        function Update-SuiteProgressPulse { }
        $script:Logs=New-Object 'Collections.Generic.List[string]';$script:WslProbeFailures=@{}
        function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
        $env:PATH=$a+';'+$b+';'+$priorPath;$env:KILOVIEW_RESOLUTION_EXIT='7'
        Assert-True ((@(Get-Command wsl.exe -CommandType Application))[0].Source -ieq (Join-Path $a 'wsl.exe')) 'Unsafe probe resolution.'
        1..3|ForEach-Object {Assert-True (-not(Test-WslRuntime)) 'Nonzero readiness exit became healthy.'}
        Assert-True ($script:Logs.Count -eq 1 -and $script:Logs[0] -match 'runtime status probe: Exited with code 7') 'Readiness exit detail was lost or repeatedly logged.'
        $script:WslProbeFailures['runtime status'].loggedUtc=[datetime]::UtcNow.AddSeconds(-31)
        Assert-True (-not(Test-WslRuntime)) 'Nonzero readiness exit became healthy.'
        Assert-True ($script:Logs.Count -eq 2) 'A continued failure stopped reporting after its interval.'
    }
    Test-Case 'Readiness exceptions and distribution exits retain bounded diagnostic details' {
        . $engineFunctions
        function Test-WslRuntimeInstalled {$true}
        $script:Logs=New-Object 'Collections.Generic.List[string]';$script:WslProbeFailures=@{}
        function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
        function Invoke-Native {throw ('Fixture unavailable '+('x'*1200))}
        1..3|ForEach-Object {Assert-True (-not(Test-WslRuntime)) 'Exception became healthy.'}
        Assert-True ($script:Logs.Count -eq 1 -and $script:Logs[0] -match 'Unavailable: Fixture unavailable' -and $script:Logs[0].Length -le 1050) 'Exception diagnostic was lost, unbounded or repeated.'
        function Invoke-Native {$global:LASTEXITCODE=8}
        Assert-True (@(Get-WslDistroNames).Count -eq 0) 'Failed list became a distribution.'
        Assert-True ($script:Logs.Count -eq 2 -and $script:Logs[1] -match 'distribution probe: Exited with code 8') 'Distribution exit code was not logged.'
    }
}finally{$env:PATH=$priorPath;$env:KILOVIEW_RESOLUTION_EXIT=$priorExit}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} native resolution checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
