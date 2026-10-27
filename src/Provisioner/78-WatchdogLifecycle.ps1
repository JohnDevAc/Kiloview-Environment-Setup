# Windows task termination does not terminate its Linux descendants. Retire the
# known loops cooperatively before changing services or starting another owner.
function Get-KiloWatchdogTransitionScript {
    param([ValidateSet('Quiesce','Activate','Retain')][string]$Mode='Quiesce', [switch]$Reactivate)
    $commands=New-Object 'Collections.Generic.List[string]'
    foreach($body in @((Get-LegacyKiloWatchdogCommand),(Get-KiloWatchdogCommand))){
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
        $commands.Add("printf '%s' '$encoded' | base64 -d | bash")
    }
    # The last installed helper can identify a previous supported generation.
    # It is never executed here; its exact command is only observed in /proc.
    if(Test-Path -LiteralPath $script:StartupScriptPath -PathType Leaf){
        $helper=[IO.File]::ReadAllText($script:StartupScriptPath)
        $match=[regex]::Match($helper,'(?m)^\$linux = ''([A-Za-z0-9+/=]+)''\r?$')
        if($match.Success){$commands.Add("printf '%s' '$($match.Groups[1].Value)' | base64 -d | bash")}
    }
    $known=(@($commands|Select-Object -Unique|ForEach-Object {Convert-ToBashLiteral $_}) -join ' ')
    $scriptText=@'
set -euo pipefail
root=/var/lib/kilolink
stop="$root/watchdog-stop"
recovery="$root/recovery-required"
normal=kiloview-watchdog-stop-v1
inactive=kiloview-role-inactive-v1
mode=__MODE__
reactivate=__REACTIVATE__
known=(__KNOWN__)
mkdir -p "$root"
exec 9>"$root/maintenance.lock"
flock -w 45 -x 9 || { echo 'Timed out acquiring the KiloLink maintenance lock.' >&2; exit 40; }
owned_stop() {
    test -f "$stop" && test ! -L "$stop" &&
    { test "$(cat "$stop")" = "$normal" || test "$(cat "$stop")" = "$inactive"; }
}
owned_pair() {
    owned_stop && test -f "$recovery" && test ! -L "$recovery" && test "$stop" -ef "$recovery"
}
if [ -e "$recovery" ] || [ -L "$recovery" ]; then
    owned_pair || { echo 'Existing recovery marker is not an owned watchdog inhibit; preserve it and resolve recovery first.' >&2; exit 30; }
else
    if [ -e "$stop" ] || [ -L "$stop" ]; then
        owned_stop || { echo 'Existing watchdog inhibit is ambiguous; preserve it for recovery.' >&2; exit 30; }
    else
        (set -o noclobber; printf '%s\n' "$normal" > "$stop")
    fi
    # Exclusive hard link makes the compatibility marker identifiable without
    # overwriting any pre-existing backup/recovery record, even after a crash.
    ln -- "$stop" "$recovery"
fi
if [ "$mode" = Activate ] && [ "$(cat "$stop")" = "$inactive" ] && [ "$reactivate" != true ]; then
    echo 'Server role is inactive. Explicitly review Server setup or repair to reactivate it.' >&2; exit 31
fi
if [ "$mode" = Retain ]; then printf '%s\n' "$inactive" > "$stop"; fi
flock -u 9

find_watchdogs() {
    local path command holder; local -a args
    for path in /proc/[0-9]*/cmdline; do
        args=()
        { mapfile -d '' -t args < "$path"; } 2>/dev/null || continue
        [ "${#args[@]}" -eq 3 ] || continue
        case "${args[0]}" in bash|/bin/bash|/usr/bin/bash) ;; *) continue ;; esac
        [ "${args[1]}" = -lc ] || continue
        for command in "${known[@]}"; do
            if [ "${args[2]}" = "$command" ]; then
                printf '%s\n' "${path%/cmdline}"
                break
            fi
        done
    done
    # Legacy inner loops keep fd9 open during their sleep. Observe holders too:
    # an outer wrapper can disappear without proving its descendants exited.
    # This only waits on the exact maintenance file; it never signals a process.
    for path in /proc/[0-9]*/fd/9; do
        holder=${path#/proc/}; holder=${holder%%/*}
        [ "$holder" != "$$" ] && [ "$holder" != "$BASHPID" ] || continue
        if [ "$(readlink "$path" 2>/dev/null || true)" = "$root/maintenance.lock" ]; then
            printf '/proc/%s (maintenance fd9)\n' "$holder"
        fi
    done
}
deadline=$((SECONDS+45))
while true; do
    remaining=$(find_watchdogs)
    [ -n "$remaining" ] || break
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "Owned watchdogs have not exited: $remaining. Inhibition retained." >&2; exit 41
    fi
    sleep .2
done
flock -w 45 -x 9 || { echo 'Could not reacquire maintenance ownership; inhibition retained.' >&2; exit 40; }
owned_pair || { echo 'Watchdog inhibit ownership changed; preserve all recovery records.' >&2; exit 30; }
# Future generations also hold this lock for their entire lifetime.
exec 8>"$root/watchdog.lock"
flock -w 2 -x 8 || { echo 'A watchdog still owns its lifetime lock; inhibition retained.' >&2; exit 41; }
if [ "$mode" = Activate ]; then
    rm -- "$recovery"
    rm -- "$stop"
fi
echo KILOLINK_WATCHDOGS_QUIESCED
'@
    return $scriptText.Replace('__MODE__',$Mode).Replace('__REACTIVATE__',([string][bool]$Reactivate).ToLowerInvariant()).Replace('__KNOWN__',$known)
}

function Set-KiloWatchdogState {
    param([string]$Distro,[ValidateSet('Quiesce','Activate','Retain')][string]$Mode='Quiesce',[switch]$Reactivate)
    if($Reactivate -and $Action -notin @('Setup','Install','Repair','Update','Resume')){throw 'Only reviewed Server setup or repair can reactivate a retained role.'}
    $pending=Join-Path $script:StateRoot 'pending-watchdog.json'
    try {
        $ownership=@{schemaVersion=1;distro=$Distro;action=$Action;mode=$Mode;startedUtc=[datetime]::UtcNow.ToString('o')}
        if($script:ActiveJournal){$script:ActiveJournal['pendingWatchdog']=$ownership}
        Write-StateJson $pending $ownership
        $task=Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
        if($task){Disable-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction Stop|Out-Null}
        Stop-ManagedTask $script:StartupTaskName
        if($Distro){
            $output=@(Invoke-WslScript $Distro (Get-KiloWatchdogTransitionScript -Mode $Mode -Reactivate:$Reactivate) -Capture)
            if($output -notcontains 'KILOLINK_WATCHDOGS_QUIESCED'){throw 'Linux watchdog quiescence was not confirmed.'}
        }
        Remove-OwnedFile $pending
        if($script:ActiveJournal){$script:ActiveJournal.Remove('pendingWatchdog')}
    } catch {
        $script:LifecycleRecoveryRequired=$true
        if(-not $script:LifecycleErrorCode){$script:LifecycleErrorCode='watchdog-quiescence-failed'}
        $script:LifecycleNextAction='Keep the watchdog inhibit and recovery records. Wait for any recorded native command to finish, then run Verify to confirm watchdog shutdown before retrying. Genuine backup recovery must be resolved first. Reactivating a retained Server requires explicit Server setup or repair.'
        throw
    }
}

function Get-PendingWatchdogRecovery {
    $path=Join-Path $script:StateRoot 'pending-watchdog.json'
    if(Test-Path -LiteralPath $path){return Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json}
    if($script:ActiveJournal){return Get-PropertyValue $script:ActiveJournal 'pendingWatchdog' $null}
    $journalPath=Join-Path $script:StateRoot 'last-operation.json'
    if(Test-Path -LiteralPath $journalPath){
        $journal=Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8|ConvertFrom-Json
        return Get-PropertyValue $journal 'pendingWatchdog' $null
    }
    return $null
}

function Test-PendingWatchdogRecovery {
    $pending=Get-PendingWatchdogRecovery
    if(-not $pending){return $false}
    $distro=[string](Get-PropertyValue $pending 'distro' '')
    if($distro -and $distro -ne $script:ManagedDistroName){throw 'Unexpected watchdog recovery distribution. Preserve the recovery record.'}
    Set-KiloWatchdogState -Distro $distro -Mode Quiesce
    # Verify only establishes that an interrupted shutdown can be retried. It
    # does not reactivate services or mark the interrupted removal successful.
    return $true
}
