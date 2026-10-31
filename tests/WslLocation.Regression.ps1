#Requires -Version 5.1
# Real bounded NativeProcess children emulate WSL help; never invokes real WSL.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run location regressions in Windows PowerShell 5.1.'}
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-wsl-location-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Import-Functions([string]$Name){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('src\Provisioner\'+$Name)),[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) ('Parse failed: '+$Name)
    [scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object {$_.Extent.Text})) -join "`n")
}
$core=Import-Functions '10-Core.ps1';$storage=Import-Functions '35-Storage.ps1'
Add-Type -Path (Join-Path $root 'launcher\LifecycleProtocol.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$bin=Join-Path $testRoot 'harmless path';New-Item -ItemType Directory -Path $bin|Out-Null
$fixture=Join-Path $bin 'wsl.exe'
Add-Type -TypeDefinition @'
using System;using System.IO;using System.Text;using System.Threading;
internal static class LocationHelpFixture {
 static int Main(string[] args){
  if(args.Length!=1 || args[0]!="--help"){return 90;}
  string mode=Environment.GetEnvironmentVariable("KILOVIEW_LOCATION_MODE");
  string help="    --install [Distro] [Options...]\r\n            --location <Location>\r\n";
  if(mode=="missing" || mode=="missing-zero"){help="    --install [Distro]\r\n";}
  if(mode=="mention"){help="Unsupported option --location; retry later.\r\n";}
  if(mode=="empty"){help="";}
  if(mode=="utf16"){
   byte[] bytes=Encoding.Unicode.GetBytes("Aide du programme\r\n"+help);
   Stream output=Console.OpenStandardOutput();output.Write(bytes,0,bytes.Length);output.Flush();
  }else{Console.Write(help);}
  if(mode=="hang"){Thread.Sleep(60000);}
  return mode=="zero" || mode=="missing-zero" ? 0 : mode=="error" ? 5 : -1;
 }
}
'@ -ReferencedAssemblies @('System.dll','System.Core.dll') -OutputAssembly $fixture -OutputType ConsoleApplication
$priorPath=$env:PATH;$priorMode=$env:KILOVIEW_LOCATION_MODE
$env:PATH=$bin+';'+$priorPath
Assert-True ((@(Get-Command wsl.exe -CommandType Application))[0].Source -ieq $fixture) 'First WSL executable is not the harmless fixture; refusing execution.'
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& {
        . $core;. $storage
        $script:ManagedDistroName='KiloLink-Ubuntu';$script:ApplicationManifest=@{runtime=@{ubuntuDistribution='Ubuntu-24.04'}}
        $script:PlannedDistroPath=Join-Path $testRoot ([guid]::NewGuid().ToString('N')+'\distro')
        $script:NativeTimeoutSeconds=5;$script:NativeStallSeconds=5
        $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:LifecycleRecoveryRequired=$false
        $script:Logs=New-Object 'Collections.Generic.List[string]'
        function Initialize-LifecycleProtocol {}
        function Update-SuiteProgressPulse {}
        function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
        & $Body
    };$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
}
try{
    foreach($mode in @('zero','minus-one','utf16')){
        Test-Case "Actual $mode help child advertises a supported explicit install location" {
            $env:KILOVIEW_LOCATION_MODE=$mode
            $arguments=@(Get-NewWslInstallArguments)
            Assert-True ($arguments[-2] -eq '--location' -and $arguments[-1] -eq $script:PlannedDistroPath) 'Supported help did not retain its planned location.'
            Assert-True ($global:LASTEXITCODE -eq $(if($mode -eq 'zero'){0}else{-1})) 'Observed native help exit code was lost.'
            Assert-True (-not $script:LifecycleRecoveryRequired -and -not(Test-Path -LiteralPath $script:PlannedDistroPath)) 'Help created a distro or recovery state.'
        }
    }
    Test-Case 'Native help exit is not replaced by a stale caller-scoped LASTEXITCODE' {
        $env:KILOVIEW_LOCATION_MODE='minus-one';$LASTEXITCODE=5
        $arguments=@(Get-NewWslInstallArguments)
        Assert-True ($arguments[-1] -eq $script:PlannedDistroPath -and $global:LASTEXITCODE -eq -1 -and $LASTEXITCODE -eq 5) 'Help used a stale caller exit rather than Invoke-Native output.'
    }
    foreach($mode in @('missing','missing-zero','empty','mention','error')){
        Test-Case "Actual $mode help cannot authorize a new location" {
            $env:KILOVIEW_LOCATION_MODE=$mode;$failure=''
            try{Get-NewWslInstallArguments|Out-Null}catch{$failure=$_.Exception.Message}
            Assert-True ($failure -match 'install-location support' -and -not(Test-Path -LiteralPath (Split-Path $script:PlannedDistroPath -Parent))) 'Invalid help permitted installation or changed storage.'
            Assert-True (-not $script:LifecycleRecoveryRequired) 'Read-only help failure created a recovery latch.'
            if($mode -eq 'error'){Assert-True ($script:LifecycleErrorCode -eq 'wsl-location-probe-failed' -and $failure -match 'exit 5') 'Genuine help failure was misreported as unsupported WSL.'}
        }
    }
    Test-Case 'Help compatibility does not relax normal native command exit handling' {
        $env:KILOVIEW_LOCATION_MODE='minus-one';$failure=''
        try{Invoke-Native wsl.exe @('--help') -ReadOnly -Capture|Out-Null}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'exit code -1' -and -not $script:LifecycleRecoveryRequired) 'Global native nonzero-exit semantics changed.'
    }
    Test-Case 'Valid help text from a still-running CLI cannot bypass its bounded deadline' {
        $env:KILOVIEW_LOCATION_MODE='hang';$failure=$null
        $realInvokeNative=(Get-Item Function:\Invoke-Native).ScriptBlock
        function Invoke-Native($FilePath,$Arguments,[switch]$Capture,[switch]$IgnoreExitCode,[switch]$ReadOnly,$TimeoutSeconds,$StallSeconds){
            Assert-True ($ReadOnly -and $TimeoutSeconds -eq 30 -and $StallSeconds -eq 30) 'Production help probe lost its read-only bounds.'
            & $realInvokeNative $FilePath $Arguments -Capture:$Capture -IgnoreExitCode:$IgnoreExitCode -ReadOnly:$ReadOnly -TimeoutSeconds 0.4 -StallSeconds 0.4
        }
        try{Get-NewWslInstallArguments|Out-Null}catch{$failure=$_.Exception}
        Assert-True ($failure -and $failure.Data['NativeCommandTimeout'] -and $script:LifecycleErrorCode -eq 'command-timeout' -and -not $script:LifecycleRecoveryRequired) 'Timeout was swallowed or reclassified as capability success.'
        Assert-True (-not(Test-Path -LiteralPath (Split-Path $script:PlannedDistroPath -Parent))) 'Timed-out help created a location.'
    }
    Test-Case 'Help heartbeat/result persistence errors retain their original cause' {
        $env:KILOVIEW_LOCATION_MODE='minus-one';$failure=''
        function Update-SuiteProgressPulse {$script:LifecycleErrorCode='lifecycle-result-write-failed';throw 'fixture result write failed'}
        try{Get-NewWslInstallArguments|Out-Null}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'fixture result write failed' -and $script:LifecycleErrorCode -eq 'lifecycle-result-write-failed') 'Persistence failure became an unsupported-runtime diagnosis.'
    }
}finally{$env:PATH=$priorPath;$env:KILOVIEW_LOCATION_MODE=$priorMode}
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} WSL location checks passed. Evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
exit 0
