#Requires -Version 5.1
# Real Bash children and /proc identities; fake Docker, services and advisory
# locks use only this fixture's temp directory. Never invokes WSL or a task.
param([string]$BashPath='C:\Program Files\Git\bin\bash.exe')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-watchdog-lifecycle-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}}
foreach($file in @('45-KiloRecovery.ps1','78-WatchdogLifecycle.ps1','80-Services.ps1')){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('src\Provisioner\'+$file)),[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) "$file has parse errors."
    foreach($fn in $ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}){Invoke-Expression $fn.Extent.Text}
}
$script:ContainerName='KLNKSVR-pro';$script:ManagedDistroName='KiloLink-Ubuntu'
$script:StartupScriptPath=Join-Path $testRoot 'absent-startup.ps1'
function Save-Text([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))}
$fixtureFunctions=@'
# Git Bash has no flock. This shell-function boundary models its exclusive,
# lifetime/unlock behavior with atomic mkdir; Linux flock itself is VM-tested.
flock() {
    local fd="${@: -1}" wait=3 nonblock=false unlock=false arg previous='' owner="$BASHPID"
    for arg in "$@"; do
        [ "$previous" != -w ] || wait="$arg"
        [ "$arg" != -n ] || nonblock=true
        [ "$arg" != -u ] || unlock=true
        previous="$arg"
    done
    local lock="$FIXTURE/lock-$fd" until=$((SECONDS+wait))
    if [ "$unlock" = true ]; then
        if [ "$(cat "$lock/owner" 2>/dev/null)" = "$owner" ]; then rm "$lock/owner"; rmdir "$lock"; fi
        return 0
    fi
    if [ "${FAIL_LOCK9:-0}" = 1 ] && [ "$fd" = 9 ]; then return 1; fi
    while ! mkdir "$lock" 2>/dev/null; do
        [ "$nonblock" = false ] || return 1
        [ "$SECONDS" -lt "$until" ] || return 1
        /usr/bin/sleep .02
    done
    printf '%s' "$owner" > "$lock/owner"
    trap 'for lock in "$FIXTURE"/lock-*; do if [ "$(cat "$lock/owner" 2>/dev/null)" = "$BASHPID" ]; then rm "$lock/owner"; rmdir "$lock"; fi; done' EXIT
}
systemctl() { printf 'service %s\n' "$*" >> "$FIXTURE/events"; }
docker() {
    printf 'docker %s\n' "$*" >> "$FIXTURE/events"
    case "$1" in
        update) if [ "$2" = --restart=no ]; then echo no > "$FIXTURE/policy"; else echo always > "$FIXTURE/policy"; fi ;;
        start) echo true > "$FIXTURE/running"; echo "$BASHPID" >> "$FIXTURE/starters" ;;
        stop) if [ "${FAIL_STOP:-0}" = 1 ]; then return 23; fi; echo false > "$FIXTURE/running" ;;
        inspect) if [[ "$*" == *RestartPolicy* ]]; then echo "$(cat "$FIXTURE/running") $(cat "$FIXTURE/policy")"; else cat "$FIXTURE/running"; fi ;;
        *) return 91 ;;
    esac
}
sleep() { if [ "$1" = 30 ]; then /usr/bin/sleep "${LOOP_SLEEP:-.4}"; else /usr/bin/sleep "$1"; fi; }
export -f flock systemctl docker sleep
'@
function New-ShellCase {
    $dir=Join-Path $testRoot ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $dir|Out-Null
    # GitHub's TEMP can use an 8.3 alias; /proc/fd reports the expanded path.
    $dir=[IO.Path]::GetFullPath($dir)
    $unix='/'+$dir.Substring(0,1).ToLowerInvariant()+$dir.Substring(2).Replace('\','/')
    $stateRoot=Convert-ToBashLiteral "$unix/state"
    Save-Text (Join-Path $dir 'fixture.sh') $fixtureFunctions
    $legacy=Get-LegacyKiloWatchdogCommand;$current=Get-KiloWatchdogCommand
    $oldMapped=$legacy.Replace('/var/lib/kilolink',$stateRoot)
    $newMapped=$current.Replace('/var/lib/kilolink',$stateRoot)
    Save-Text (Join-Path $dir 'legacy-direct.sh') $oldMapped
    $legacy64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($legacy));$current64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($current))
    $old64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($oldMapped));$new64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newMapped))
    foreach($mode in @('Quiesce','Activate','Retain','Reactivate')){
        $script=if($mode -eq 'Reactivate'){Get-KiloWatchdogTransitionScript -Mode Activate -Reactivate}else{Get-KiloWatchdogTransitionScript -Mode $mode}
        $script=$script.Replace('/var/lib/kilolink',$stateRoot).Replace($legacy64,$old64).Replace($current64,$new64).Replace('SECONDS+45','SECONDS+3').Replace('flock -w 45','flock -w 3')
        Save-Text (Join-Path $dir ($mode+'.sh')) $script
    }
    [pscustomobject]@{Directory=$dir;Unix=$unix;Legacy="printf '%s' '$old64' | base64 -d | bash";Current="printf '%s' '$new64' | base64 -d | bash"}
}
function Invoke-ShellCase($Case,[string]$Body){
    $header="set -euo pipefail`nexport FIXTURE='"+$Case.Unix+"'`nexport BASH_ENV='"+$Case.Unix+"/fixture.sh'`nsource `"`$BASH_ENV`"`nlegacy="+(Convert-ToBashLiteral $Case.Legacy)+"`ncurrent="+(Convert-ToBashLiteral $Case.Current)+"`n"
    $script=Join-Path $Case.Directory 'driver.sh';Save-Text $script ($header+$Body)
    $previousPreference=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=& $BashPath --noprofile --norc $script 2>&1;$code=$LASTEXITCODE}
    finally{$ErrorActionPreference=$previousPreference}
    Save-Text (Join-Path $Case.Directory 'output.txt') ($output -join "`n")
    Assert-True ($code -eq 0) "Shell fixture exit $code. Evidence: $($Case.Directory). $($output -join ' ')"
}
Test-Case 'Four legacy loops exit naturally before retained shutdown and quick reactivation' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
echo preserved > "$FIXTURE/data"
pids=()
for n in 1 2 3 4; do bash -lc "$legacy" > "$FIXTURE/old-$n.log" 2>&1 & pids+=("$!"); done
for n in {1..100}; do [ -f "$FIXTURE/running" ] && break; /usr/bin/sleep .02; done
/usr/bin/sleep .2
bash "$FIXTURE/Retain.sh"
for pid in "${pids[@]}"; do if kill -0 "$pid" 2>/dev/null; then echo 'Legacy owner survived confirmed quiescence'; exit 90; fi; wait "$pid" || test "$?" = 30; done
docker update --restart=no KLNKSVR-pro
docker stop KLNKSVR-pro
test "$(docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' KLNKSVR-pro)" = 'false no'
/usr/bin/sleep 1
test "$(cat "$FIXTURE/running") $(cat "$FIXTURE/policy")" = 'false no'
test "$(cat "$FIXTURE/data")" = preserved
# Ordinary refresh cannot clear a retained-role inhibit.
if bash "$FIXTURE/Activate.sh"; then exit 91; else test "$?" = 31; fi
bash "$FIXTURE/Reactivate.sh"
test ! -e "$FIXTURE/state/recovery-required"
bash -lc "$current" > "$FIXTURE/new.log" 2>&1 & newer=$!
for n in {1..100}; do [ "$(cat "$FIXTURE/running")" = true ] && break; /usr/bin/sleep .02; done
test "$(cat "$FIXTURE/running") $(cat "$FIXTURE/policy")" = 'true always'
bash "$FIXTURE/Retain.sh"
wait "$newer"
'@
}
Test-Case 'Repeated startup has one active watchdog and all waiting owners quiesce' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
pids=()
for n in 1 2 3; do bash -lc "$current" > "$FIXTURE/current-$n.log" 2>&1 & pids+=("$!"); done
for n in {1..100}; do [ -f "$FIXTURE/running" ] && break; /usr/bin/sleep .02; done
test -d "$FIXTURE/lock-8"
bash "$FIXTURE/Retain.sh"
for pid in "${pids[@]}"; do wait "$pid"; done
test ! -d "$FIXTURE/lock-8"
test "$(sort -u "$FIXTURE/starters" | wc -l)" -eq 1
'@
}
Test-Case 'Legacy inner loop without a known outer wrapper is observed by maintenance fd9' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
bash "$FIXTURE/legacy-direct.sh" > "$FIXTURE/orphan.log" 2>&1 & inner=$!
for n in {1..100}; do [ -f "$FIXTURE/running" ] && break; /usr/bin/sleep .02; done
bash "$FIXTURE/Reactivate.sh"
if kill -0 "$inner" 2>/dev/null; then echo 'Unwrapped legacy loop escaped quiescence'; exit 90; fi
wait "$inner" || test "$?" = 30
test ! -e "$FIXTURE/state/recovery-required"
'@
}
foreach($kind in @('genuine-recovery','foreign-stop','ambiguous-pair','symlink')){
    Test-Case "Preserve $kind marker without clearing or overwriting" {
        $case=New-ShellCase
        $setup=switch($kind){
            'genuine-recovery' {'echo /important/backup > "$FIXTURE/state/recovery-required"'}
            'foreign-stop' {'echo foreign > "$FIXTURE/state/watchdog-stop"'}
            'ambiguous-pair' {'echo kiloview-watchdog-stop-v1 > "$FIXTURE/state/watchdog-stop"; cp "$FIXTURE/state/watchdog-stop" "$FIXTURE/state/recovery-required"'}
            'symlink' {'echo foreign > "$FIXTURE/data"; ln -s "$FIXTURE/data" "$FIXTURE/state/recovery-required"'}
        }
        Invoke-ShellCase $case ("mkdir -p `"`$FIXTURE/state`"`n"+$setup+"`n"+@'
before=$(find "$FIXTURE/state" -maxdepth 1 -type f -exec sha256sum {} \;)
if bash "$FIXTURE/Reactivate.sh"; then exit 91; else test "$?" = 30; fi
after=$(find "$FIXTURE/state" -maxdepth 1 -type f ! -name maintenance.lock -exec sha256sum {} \;)
test "$before" = "$after"
'@)
    }
}
Test-Case 'Bounded failed shutdown retains ownership until sleeping legacy loop exits' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
export LOOP_SLEEP=5
bash -lc "$legacy" > "$FIXTURE/slow.log" 2>&1 & old=$!
for n in {1..100}; do [ -f "$FIXTURE/running" ] && break; /usr/bin/sleep .02; done
/usr/bin/sleep .1
if bash "$FIXTURE/Retain.sh"; then exit 91; else test "$?" = 41; fi
test "$FIXTURE/state/watchdog-stop" -ef "$FIXTURE/state/recovery-required"
wait "$old" || test "$?" = 30
bash "$FIXTURE/Quiesce.sh"
test "$FIXTURE/state/watchdog-stop" -ef "$FIXTURE/state/recovery-required"
bash "$FIXTURE/Reactivate.sh"
'@
}
Test-Case 'Lock failure is bounded and preserves data' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
echo preserved > "$FIXTURE/data"
export FAIL_LOCK9=1
if bash "$FIXTURE/Retain.sh"; then exit 91; else test "$?" = 40; fi
test "$(cat "$FIXTURE/data")" = preserved
test ! -e "$FIXTURE/state/recovery-required"
'@
}
Test-Case 'Interrupted marker creation is retried without deleting genuine records' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
mkdir -p "$FIXTURE/state"
echo kiloview-watchdog-stop-v1 > "$FIXTURE/state/watchdog-stop"
bash "$FIXTURE/Retain.sh"
test "$FIXTURE/state/watchdog-stop" -ef "$FIXTURE/state/recovery-required"
test "$(cat "$FIXTURE/state/watchdog-stop")" = kiloview-role-inactive-v1
bash "$FIXTURE/Retain.sh"
'@
}
Test-Case 'Failed Docker stop retains inhibition and data for a later retry' {
    $case=New-ShellCase
    Invoke-ShellCase $case @'
echo preserved > "$FIXTURE/data"
echo true > "$FIXTURE/running"
echo always > "$FIXTURE/policy"
bash "$FIXTURE/Retain.sh"
docker update --restart=no KLNKSVR-pro
export FAIL_STOP=1
if docker stop KLNKSVR-pro; then exit 91; else test "$?" = 23; fi
test "$FIXTURE/state/watchdog-stop" -ef "$FIXTURE/state/recovery-required"
test "$(cat "$FIXTURE/data")" = preserved
test "$(docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' KLNKSVR-pro)" != 'false no'
export FAIL_STOP=0
bash "$FIXTURE/Retain.sh"
docker stop KLNKSVR-pro
test "$(docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}}' KLNKSVR-pro)" = 'false no'
'@
}
Test-Case 'PowerShell failure records recovery before dispatch and Verify retains inhibition' {
    $script:StateRoot=Join-Path $testRoot 'owner-state';New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
    $script:StartupTaskName='Fixture watchdog';$Action='Uninstall'
    $script:LifecycleRecoveryRequired=$false;$script:LifecycleErrorCode='';$script:LifecycleNextAction=''
    $events=New-Object 'Collections.Generic.List[string]'
    function Write-StateJson($Path,$Value){Save-Text $Path ($Value|ConvertTo-Json)}
    function Remove-OwnedFile($Path){Remove-Item -LiteralPath $Path -ErrorAction Stop}
    function Get-ScheduledTask {[pscustomobject]@{State='Running'}}
    function Disable-ScheduledTask {$events.Add('disable')}
    function Stop-ManagedTask {$events.Add('stop')}
    function Get-PropertyValue($Value,$Name,$Default){if($null -ne $Value.$Name){$Value.$Name}else{$Default}}
    function Invoke-WslScript {
        param($Distro,$Content,[switch]$Capture)
        Assert-True (Test-Path -LiteralPath (Join-Path $script:StateRoot 'pending-watchdog.json')) 'Native shutdown began before durable recovery ownership.'
        $events.Add('native');throw 'fixture lock ownership failure'
    }
    $failure=$null;try{Set-KiloWatchdogState -Distro 'KiloLink-Ubuntu' -Mode Retain}catch{$failure=$_}
    Assert-True ($failure -and $failure.Exception.Message -eq 'fixture lock ownership failure') 'Original shutdown failure was lost.'
    Assert-True (($events -join ',') -eq 'disable,stop,native') 'Triggers were not disabled before stopping the Windows/Linux owners.'
    Assert-True ($script:LifecycleRecoveryRequired -and $script:LifecycleErrorCode -eq 'watchdog-quiescence-failed' -and $script:LifecycleNextAction -match 'Verify') 'Failed shutdown lacks truthful recovery guidance.'
    function Invoke-WslScript {param($Distro,$Content,[switch]$Capture) Assert-True ($Content -match 'mode=Quiesce') 'Verify cleared the inhibit or reactivated services';'KILOLINK_WATCHDOGS_QUIESCED'}
    $Action='Verify'
    Assert-True (Test-PendingWatchdogRecovery) 'Verify did not handle pending shutdown.'
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $script:StateRoot 'pending-watchdog.json'))) 'Confirmed retry still has pending shutdown ownership.'
}
Test-Case 'Pending-file write failure retains journal identity without starting shutdown' {
    $script:StateRoot=Join-Path $testRoot 'journal-state';New-Item -ItemType Directory -Path $script:StateRoot|Out-Null
    $script:ActiveJournal=[ordered]@{action='Uninstall';mutationStarted=$true}
    $script:LifecycleErrorCode='';$script:LifecycleRecoveryRequired=$false;$Action='Uninstall'
    function Write-StateJson {throw 'fixture pending-file storage failure'}
    function Get-ScheduledTask {throw 'Shutdown started without durable pending storage'}
    function Get-PropertyValue($Value,$Name,$Default){if($null -ne $Value.$Name){$Value.$Name}else{$Default}}
    $failure=$null;try{Set-KiloWatchdogState -Distro 'KiloLink-Ubuntu' -Mode Retain}catch{$failure=$_}
    Assert-True ($failure.Exception.Message -eq 'fixture pending-file storage failure') 'Pending storage failure was masked or shutdown started.'
    Assert-True ($script:LifecycleRecoveryRequired -and $script:ActiveJournal.pendingWatchdog.distro -eq 'KiloLink-Ubuntu') 'Journal fallback lost shutdown ownership.'
    Save-Text (Join-Path $script:StateRoot 'last-operation.json') ($script:ActiveJournal|ConvertTo-Json -Depth 6)
    $script:ActiveJournal=$null
    Assert-True ((Get-PendingWatchdogRecovery).mode -eq 'Retain') 'Durable journal fallback was ignored when pending file was absent.'
}
$results|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
$passed=@($results|Where-Object {$_.Passed}).Count
Write-Output "$passed/$($results.Count) watchdog checks passed. Evidence: $testRoot"
if($passed -ne $results.Count){exit 1}
exit 0
