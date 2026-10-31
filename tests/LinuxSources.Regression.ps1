#Requires -Version 5.1
# Production Bash probe and native output handling, with fake curl/apt commands.
# No WSL, network access, package installation, services or live state changes.
param([string]$BashPath='C:\Program Files\Git\bin\bash.exe')
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Run Linux source regressions in Windows PowerShell 5.1.'}
$root=Split-Path -Parent $PSScriptRoot
$testRoot=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('kiloview-linux-sources-'+[guid]::NewGuid().ToString('N'))))
$bin=Join-Path $testRoot 'fake-bin'
New-Item -ItemType Directory -Path $bin -Force|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Save-Text([string]$Path,[string]$Value){[IO.File]::WriteAllText($Path,$Value.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))}
function Bash-Quote([string]$Value){return "'"+$Value.Replace("'","'\''")+"'"}
function Bash-Path([string]$Path){return '/'+$Path.Substring(0,1).ToLowerInvariant()+$Path.Substring(2).Replace('\','/')}
foreach($file in @('10-Core.ps1','20-Wsl.ps1','60-Ownership.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('src\Provisioner\'+$file)),[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) "$file has parse errors."
    foreach($fn in $ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}){
        if($file -eq '10-Core.ps1'){
            if($fn.Name -eq 'Invoke-Native'){Invoke-Expression ($fn.Extent.Text.Replace('function Invoke-Native {','function Invoke-FixtureNative {'))}
        }else{Invoke-Expression $fn.Extent.Text}
    }
}
Add-Type -Path (Join-Path $root 'launcher\LifecycleProtocol.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
function Initialize-LifecycleProtocol {}
function Update-SuiteProgressPulse {}
function Write-InstallerLog {param([string]$Message) $script:Logs.Add($Message)}
Save-Text (Join-Path $bin 'curl') @'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$FIXTURE_TRACE"
if [[ "$*" == *registry-1.docker.io* ]]; then
  if [ "$FIXTURE_MODE" = registry-dns ]; then echo 'Could not resolve registry' >&2; exit 6; fi
  printf '%s' "$FIXTURE_HTTP"
else
  if [ "$FIXTURE_MODE" = tls-failure ]; then echo 'Certificate verification failed' >&2; exit 60; fi
  if [ "$FIXTURE_MODE" = curl-timeout ]; then echo 'Transfer timed out' >&2; exit 28; fi
  echo 'HTTP/2 200'
fi
'@
Save-Text (Join-Path $bin 'apt-get') @'
#!/bin/bash
printf 'apt-get %s\n' "$*" >> "$FIXTURE_TRACE"
# Refuse any request to install/upgrade or relax source validation.
case " $* " in *' update --error-on=any '*) ;; *) exit 91 ;; esac
case " $* " in *' Acquire::Retries=0 '*) ;; *) exit 92 ;; esac
case " $* " in *' Acquire::http::Timeout=12 '*) ;; *) exit 93 ;; esac
case " $* " in *' Acquire::https::Timeout=12 '*) ;; *) exit 94 ;; esac
echo 'Get:1 fixture package metadata'
case "$FIXTURE_MODE" in
  slow) sleep 0.8 ;;
  timeout) sleep 10 ;;
  ignore-term) trap '' TERM; while true; do sleep 1; done ;;
  apt-failure) echo 'E: Failed to fetch fixture repository' >&2; exit 100 ;;
  apt-lock) echo 'E: Could not get lock /var/lib/apt/lists/lock' >&2; exit 100 ;;
esac
echo 'Reading package lists... Done'
'@
function Reset-Fixture([string]$Mode='success',[string]$Http='401'){
    $script:Mode=$Mode;$script:Http=$Http;$script:Calls=0
    $script:Directory=Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Directory|Out-Null
    $script:Logs=New-Object 'Collections.Generic.List[string]'
    $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:LifecycleRecoveryRequired=$false
    $script:NativeFailure=$null;$script:ExpectedIgnore=$true
}
function Invoke-Native {
    param($FilePath,$Arguments,[switch]$Capture,[switch]$IgnoreExitCode)
    Assert-True ($FilePath -eq 'wsl.exe' -and $Arguments[1] -eq 'Fixture' -and $Arguments[3] -eq 'root') 'Probe targeted an unexpected executable or distro.'
    Assert-True ($Capture -and [bool]$IgnoreExitCode -eq $script:ExpectedIgnore) 'WSL script flags were not forwarded.'
    $script:Calls++
    if($script:NativeFailure){throw $script:NativeFailure}
    if($script:Mode -eq 'wsl-failure'){$global:LASTEXITCODE=7;return 'WSL could not execute the command'}
    if($script:Mode -eq 'incomplete'){$global:LASTEXITCODE=0;return 'KILOLINK_SOURCE_CHECK_OK:ubuntu-metadata'}
    $match=[regex]::Match($Arguments[-1],"printf '%s' '([A-Za-z0-9+/=]+)'")
    Assert-True $match.Success 'WSL script encoding was not found.'
    $content=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[1].Value))
    Assert-True (-not $content.Contains("`r")) 'WSL script retained CRLF.'
    # Scale 60s -> 0.5s and 240s -> 2s. The slow fixture needs 0.8s;
    # production control flow and actual GNU timeout remain unchanged.
    $content=$content.Replace('--kill-after=10s 240s','--kill-after=0.2s 2s')
    $prefix=@(
        ('export PATH='+(Bash-Quote (Bash-Path $bin))+':/usr/bin:/bin'),
        ('export FIXTURE_TRACE='+(Bash-Quote (Bash-Path (Join-Path $script:Directory 'commands.log')))),
        ('export FIXTURE_MODE='+(Bash-Quote $script:Mode)),
        ('export FIXTURE_HTTP='+(Bash-Quote $script:Http))
    ) -join "`n"
    if($script:Mode -eq 'no-curl'){$prefix+="`n"+'command() { if [ "$*" = "-v curl" ]; then return 1; fi; builtin command "$@"; }'}
    $path=Join-Path $script:Directory 'probe.sh'
    Save-Text $path ($prefix+"`n"+$content)
    Invoke-FixtureNative $BashPath @('--noprofile','--norc',$path) -Capture -IgnoreExitCode:$IgnoreExitCode -TimeoutSeconds 15 -StallSeconds 10
}
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
    finally{if($script:Directory){$script:Logs.ToArray()|Set-Content -LiteralPath (Join-Path $script:Directory 'diagnostic.log')}}
}
function Get-Failure([scriptblock]$Body){try{& $Body;throw 'Expected failure was not raised'}catch{return $_.Exception}}
function Assert-Log([string]$Pattern){Assert-True (@($script:Logs|Where-Object {$_ -match $Pattern}).Count -gt 0) "Missing log: $Pattern"}
foreach($http in @('200','401')){
    Test-Case "Registry HTTP $http and complete package metadata pass" {
        Reset-Fixture 'success' $http
        Assert-LinuxDownloads 'Fixture'
        Assert-True ($script:Calls -eq 1 -and -not $script:LifecycleErrorCode) 'Success retained an error or repeated the probe.'
        Assert-Log '^Get:1';Assert-Log '^Reading package lists';Assert-Log '^KILOLINK_LINUX_SOURCES_READY$'
    }
}
Test-Case 'Slow first metadata processing passes with visible diagnostics' {
    Reset-Fixture 'slow'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    Assert-LinuxDownloads 'Fixture'
    Assert-True ($clock.Elapsed.TotalSeconds -gt 0.5 -and $clock.Elapsed.TotalSeconds -lt 8) 'Slow metadata fixture did not exercise the enlarged bounded budget.'
    Assert-Log '^Reading package lists';Assert-Log '^KILOLINK_SOURCE_CHECK_OK:ubuntu-metadata$'
}
Test-Case 'Metadata timeout reports its stage and retains pre-timeout output' {
    Reset-Fixture 'timeout'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
    Assert-True ($failure.Message -match 'Ubuntu package checks exceeded the 4-minute limit' -and $script:LifecycleErrorCode -eq 'linux-package-check-timeout') 'Metadata timeout was classified as a network outage.'
    Assert-True ($clock.Elapsed.TotalSeconds -lt 8 -and -not $script:LifecycleRecoveryRequired) 'Completed Linux timeout became an unobserved native process.'
    Assert-Log '^Get:1';Assert-Log '^KILOLINK_SOURCE_CHECK_FAILED:ubuntu-metadata:124$'
}
Test-Case 'Unresponsive metadata child remains bounded by the termination grace' {
    Reset-Fixture 'ignore-term'
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
    Assert-True ($failure.Message -match 'Ubuntu package check failed \(exit 137\)' -and $script:LifecycleErrorCode -eq 'linux-package-check-failed') 'Killed metadata child was hidden or called a source outage.'
    Assert-True ($clock.Elapsed.TotalSeconds -lt 8 -and -not $script:LifecycleRecoveryRequired) 'Linux termination grace left the native CLI active.'
    Assert-Log '^Get:1';Assert-Log '^KILOLINK_SOURCE_CHECK_FAILED:ubuntu-metadata:137$'
}
foreach($mode in @('apt-failure','apt-lock')){
    Test-Case "$mode remains a strict failure with its original diagnostic" {
        Reset-Fixture $mode
        $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
        Assert-True ($failure.Message -match 'Ubuntu package check failed \(exit 100\)' -and $script:LifecycleErrorCode -eq 'linux-package-check-failed') 'APT failure was masked or called a timeout.'
        Assert-Log '^E:'
        Assert-True (-not($script:Logs -contains 'KILOLINK_LINUX_SOURCES_READY')) 'Failed source was marked ready.'
    }
}
foreach($case in @(@('tls-failure','Docker download',60),@('registry-dns','Docker registry',6),@('curl-timeout','Docker download',28))){
    Test-Case "$($case[0]) fails before APT and identifies the endpoint" {
        Reset-Fixture $case[0]
        $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
        Assert-True ($failure.Message -eq "$($case[1]) check failed (exit $($case[2])). See diagnostics, then retry.") 'Endpoint failure was misclassified.'
        Assert-True (-not(@($script:Logs|Where-Object {$_ -match '^Get:1'}).Count)) 'APT ran after a required endpoint failed.'
    }
}
foreach($http in @('302','403','500')){
    Test-Case "Unexpected registry HTTP $http fails closed" {
        Reset-Fixture 'success' $http
        $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
        Assert-True ($failure.Message -match 'Docker registry check failed \(exit 22\)') 'Unexpected registry response passed.'
        Assert-Log "unexpected HTTP $http"
    }
}
Test-Case 'Fresh distro without curl still requires complete APT metadata' {
    Reset-Fixture 'no-curl'
    Assert-LinuxDownloads 'Fixture'
    Assert-Log 'deferred until curl is installed';Assert-Log '^Reading package lists'
}
Test-Case 'A WSL invocation failure is not relabelled as a repository outage' {
    Reset-Fixture 'wsl-failure'
    $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
    Assert-True ($failure.Message -match 'WSL package check failed \(exit 7\)') 'A WSL invocation failure was called a source outage.'
}
Test-Case 'A zero exit without the completion marker cannot pass the gate' {
    Reset-Fixture 'incomplete'
    $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
    Assert-True ($failure.Message -match 'did not confirm completion' -and $script:LifecycleErrorCode -eq 'linux-package-check-failed') 'Missing completion was accepted.'
}
foreach($errorCode in @('command-timeout','lifecycle-result-write-failed')){
    Test-Case "$errorCode keeps the native error and recovery instructions" {
        Reset-Fixture
        $script:LifecycleErrorCode=$errorCode;$script:LifecycleRecoveryRequired=$true;$script:LifecycleNextAction='Wait for the owned native process.'
        $script:NativeFailure=[TimeoutException]::new('Original native or persistence failure')
        $failure=Get-Failure {Assert-LinuxDownloads 'Fixture'}
        Assert-True ([object]::ReferenceEquals($failure,$script:NativeFailure) -and $script:LifecycleErrorCode -eq $errorCode -and $script:LifecycleRecoveryRequired -and $script:LifecycleNextAction -eq 'Wait for the owned native process.') 'Source gate overwrote an unobserved native/persistence failure.'
    }
}
Test-Case 'Existing WSL script callers still throw on nonzero exit by default' {
    Reset-Fixture 'apt-failure';$script:ExpectedIgnore=$false
    $failure=Get-Failure {Invoke-WslScript 'Fixture' (Get-LinuxSourceCheckScript) -Capture}
    Assert-True ($failure.Message -match 'Command failed with exit code 100') 'Optional exit-code capture changed default callers.'
}
$failed=@($results|Where-Object {-not $_.Passed})
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $testRoot 'results.json')
Write-Host ("{0}/{1} Linux source checks passed. Evidence: {2}" -f ($results.Count-$failed.Count),$results.Count,$testRoot)
if($failed.Count){exit 1}
exit 0
