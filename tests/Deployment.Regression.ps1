# Loaded inside the isolated regression harness. Never runs WSL or real Docker.
Test-Case 'Read-only plan reports latest stable policy without downloading or writing state' {
    function Invoke-WebRequest { throw 'Planning must be offline' }
    $plan = Get-DeploymentPlan (New-Config)
    Assert-True ($plan.policy -eq 'latest-stable' -and $plan.runtime -eq 'WSL2' -and $plan.upgradesRuntime) 'Wrong application/runtime policy.'
    Assert-True ($plan.kiloLinkImage -eq 'kiloview/klnk-pro:latest' -and $plan.ndiToolsSource -eq 'https://ndi.video/tools/') 'Vendor sources were lost.'
    Assert-True (-not (Test-Path $script:StateRoot)) 'Planning changed state.'
}
Test-Case 'Atomic state replacement and failed-step journals survive rereading' {
    $path = Join-Path $script:StateRoot 'state.json'
    Write-StateJson $path @{counter=1}
    Write-StateJson $path @{counter=2}
    Assert-True ((Get-Content $path -Raw | ConvertFrom-Json).counter -eq 2) 'State replacement failed.'
    Start-DeploymentJournal 'Update' (New-Config)
    Set-OperationOutcome 'Running' 'Fixture'
    $value = Invoke-DeploymentStep 'success' { 'result' }
    Assert-True ($value -eq 'result') 'Step wrapper swallowed its return value.'
    Assert-Throws { Invoke-DeploymentStep 'failure' { throw 'fixture failure' } } 'fixture failure'
    $journal = Get-Content (Join-Path $script:StateRoot 'last-operation.json') -Raw | ConvertFrom-Json
    Assert-True ($journal.outcome -eq 'Failed' -and $journal.steps[0].state -eq 'Completed' -and $journal.steps[1].error -eq 'fixture failure') 'Failure was not recorded durably.'
    Assert-True (@(Get-ChildItem $script:StateRoot -Filter '*.tmp' -Recurse).Count -eq 0) 'Atomic write leaked temporary files.'
}
Test-Case 'Reboot-required steps remain distinguishable from completed steps' {
    Start-DeploymentJournal 'MaintainRuntime' (New-Config)
    Invoke-DeploymentStep 'WSL' { Set-OperationOutcome 'RestartRequired' 'Fixture restart' }
    $journal = Get-Content (Join-Path $script:StateRoot 'last-operation.json') -Raw | ConvertFrom-Json
    Assert-True ($journal.outcome -eq 'RestartRequired' -and $journal.steps[0].state -eq 'RestartRequired') 'Restart checkpoint was lost.'
}
Test-Case 'Verified package receipts record actual bytes and latest policy' {
    Invoke-Expression ($ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-ResolvedPackage'},$true).Extent.Text)
    $file = Join-Path $testRoot 'receipt-fixture.bin'
    [IO.File]::WriteAllText($file,'fixture')
    Save-ResolvedPackage 'ndiTools' '9.0.0' 'https://example.invalid/fixture' $file
    $receipt = Get-ChildItem (Join-Path $script:StateRoot 'Packages') | Get-Content -Raw | ConvertFrom-Json
    Assert-True ($receipt.sha256 -eq (Get-FileHash $file).Hash.ToLowerInvariant() -and $receipt.version -eq '9.0.0' -and $receipt.policy -eq 'latest-stable') 'Receipt did not record the actual package.'
}
Test-Case 'Pending recovery and unsafe configuration block replacement before WSL' {
    $backup = Join-Path $script:StateRoot 'Backups\interrupted'
    New-Item -ItemType Directory $backup -Force | Out-Null
    Set-Content (Join-Path $backup 'status') 'pending'
    Assert-Throws { Invoke-KiloReplacement (New-Config) } 'interrupted KiloLink operation'
    $config = New-Config; $config.LinuxDataPath = '/'
    Assert-Throws { Get-KiloReplacementScript $config '/tmp/fixture' ('a' * 32) } 'Unsafe'
    $config = New-Config; $config.KiloLinkImage = 'evil/image:latest'
    Assert-Throws { Get-KiloReplacementScript $config '/tmp/fixture' ('a' * 32) } 'Unsafe'
}
Test-Case 'Runtime maintenance backs up before apt and never updates application images' {
    . $repairMocks
    $Action = 'MaintainRuntime'; $AcceptLicenses = $true
    Save-Config (New-Config)
    $script:RuntimeCalls = @()
    function Ensure-WslFeatures { $script:RuntimeCalls += 'WSL'; $true }
    function Invoke-KiloReplacement { param($Config,[switch]$BackupOnly) Assert-True $BackupOnly 'Runtime attempted application replacement'; $script:RuntimeCalls += 'Backup' }
    function Invoke-WslScript { param($Distro,$Script) Assert-True ($Script.Contains('apt-get upgrade -y') -and -not $Script.Contains('docker pull')) 'Wrong runtime work'; $script:RuntimeCalls += 'APT' }
    function Test-SuiteHealth { $script:RuntimeCalls += 'Health' }
    Maintain-SuiteRuntime
    Assert-True (($script:RuntimeCalls -join ',') -eq 'WSL,Backup,APT,Health' -and $script:OperationOutcome -eq 'Completed') 'Runtime stage order was incorrect.'
}

$replacementDocker = @'
#!/bin/bash
set -eu
test -f "$FIXTURE/fixture-only" || exit 90
op=$1; shift
case "$op" in
  info) exit 0 ;;
  pull) test "$MODE" != pull-fail; exit $? ;;
  image) test "$MODE" != repair || exit 98; echo 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; exit 0 ;;
  inspect)
    name=${!#}
    test -f "$FIXTURE/containers/$name.kind" || exit 1
    if [ "$1" = -f ]; then
      case "$2" in
        *Running*) cat "$FIXTURE/containers/$name.running" ;;
        *RestartPolicy*) cat "$FIXTURE/containers/$name.restart" ;;
        *Image*) echo 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
        *Config.Labels*) if [ "$(cat "$FIXTURE/containers/$name.kind")" = new ]; then echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi ;;
        *) exit 91 ;;
      esac
    else printf '{"kind":"%s"}\n' "$(cat "$FIXTURE/containers/$name.kind")"; fi ;;
  update)
    name=${!#}; policy=${1#--restart=}; if [ "$1" = --restart ]; then policy=$2; fi
    test -f "$FIXTURE/containers/$name.kind" || exit 1
    printf '%s' "$policy" > "$FIXTURE/containers/$name.restart" ;;
  stop) name=${!#}; printf false > "$FIXTURE/containers/$name.running" ;;
  start) name=${!#}; printf true > "$FIXTURE/containers/$name.running" ;;
  rename) for suffix in kind running restart; do mv "$FIXTURE/containers/$1.$suffix" "$FIXTURE/containers/$2.$suffix"; done ;;
  rm)
    test "$MODE" != removal-fail || exit 1
    name=${!#}; rm -f "$FIXTURE/containers/$name.kind" "$FIXTURE/containers/$name.running" "$FIXTURE/containers/$name.restart" ;;
  run)
    test "$MODE" != run-fail || exit 1
    if [ "$MODE" = repair ]; then test "${@: -3:1}" = 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' || exit 99; fi
    printf new > "$FIXTURE/containers/KLNKSVR-pro.kind"
    printf true > "$FIXTURE/containers/KLNKSVR-pro.running"
    printf no > "$FIXTURE/containers/KLNKSVR-pro.restart"
    printf migrated > "$FIXTURE/data/value"
    if [ "$MODE" = corrupt ]; then printf corrupt >> "$FIXTURE/backup/data.tar"; fi
    if [ "$MODE" = interrupted ]; then kill -KILL "$PPID"; fi ;;
  *) echo "Unsupported fixture Docker command: $op" >&2; exit 92 ;;
esac
'@
foreach ($replacementMode in @('success','repair','unhealthy','run-fail','backup-fail','pull-fail','removal-fail','corrupt','interrupted','backup-only','stopped-backup')) {
    Test-Case "Generated container replacement with actual archive and fake Docker: $replacementMode" {
        $fixture = Join-Path $testRoot ('replacement-' + $replacementMode)
        New-Item -ItemType Directory -Path $fixture,(Join-Path $fixture 'bin'),(Join-Path $fixture 'containers'),(Join-Path $fixture 'data') -Force | Out-Null
        $unix = '/' + $fixture.Substring(0,1).ToLowerInvariant() + $fixture.Substring(2).Replace('\','/')
        Set-Content (Join-Path $fixture 'fixture-only') 'isolated'
        [IO.File]::WriteAllText((Join-Path $fixture 'data\value'),'original')
        foreach ($pair in @(@('kind','old'),@('running',$(if ($replacementMode -eq 'stopped-backup') {'false'} else {'true'})),@('restart','always'))) {
            [IO.File]::WriteAllText((Join-Path $fixture ('containers\KLNKSVR-pro.' + $pair[0])), $pair[1])
        }
        $stubs = @{
            docker=$replacementDocker
            flock="#!/bin/sh`nexit 0`n" # Git Bash lacks flock; Linux concurrency needs VM acceptance.
            sleep="#!/bin/sh`nexit 0`n"
            curl='#!/bin/sh' + "`n" + 'test "$MODE" = success || test "$MODE" = repair'
            tar='#!/bin/sh' + "`n" + 'if [ "$MODE" = backup-fail ] && [ "$4" = -cf ]; then exit 1; fi' + "`n" + '/usr/bin/tar "$@"'
        }
        foreach ($name in $stubs.Keys) { [IO.File]::WriteAllText((Join-Path $fixture "bin\$name"), $stubs[$name].Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false)) }
        $only = $replacementMode -in @('backup-only','stopped-backup')
        $shell = Get-KiloReplacementScript (New-Config) "$unix/backup" ('a' * 32) -Pull:($replacementMode -ne 'repair') -BackupOnly:$only
        $shell = $shell.Replace('/var/lib/kilolink', "$unix/state").Replace('/opt/kilolink-server', "$unix/data").Replace('seq 1 60','seq 1 2')
        Assert-True (-not $shell.Contains('/var/lib/') -and -not $shell.Contains('/opt/')) 'Fixture path escaped the temporary directory.'
        $shell = "export FIXTURE='$unix'`nexport MODE='$replacementMode'`nexport PATH='$unix/bin':/usr/bin:/bin`n" + $shell
        $path = Join-Path $fixture 'run.sh'
        [IO.File]::WriteAllText($path,$shell.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
        $previousErrorAction = $ErrorActionPreference
        try { $ErrorActionPreference = 'Continue'; $output = & $BashPath --noprofile --norc $path 2>&1; $exit = $LASTEXITCODE } finally { $ErrorActionPreference = $previousErrorAction }
        $statusPath = Join-Path $fixture 'backup\status'
        $status = if (Test-Path $statusPath) { (Get-Content $statusPath -Raw).Trim() } else { '' }
        $data = [IO.File]::ReadAllText((Join-Path $fixture 'data\value'))
        if ($replacementMode -in @('success','repair')) {
            Assert-True ($exit -eq 0 -and $status -eq 'committed' -and $data -eq 'migrated') "Commit failed: $output"
            Assert-True ((Get-Content (Join-Path $fixture ('containers\KLNKSVR-pro-previous-' + ('a'*32) + '.restart')) -Raw) -eq 'no') 'Previous container could start on reboot.'
        } elseif ($only) {
            Assert-True ($exit -eq 0 -and $status -eq 'backup-complete' -and $data -eq 'original') "Backup failed: $output"
            $running = Get-Content (Join-Path $fixture 'containers\KLNKSVR-pro.running') -Raw
            Assert-True (($running -eq 'true') -eq ($replacementMode -eq 'backup-only')) 'Backup changed the original running state.'
        } elseif ($replacementMode -in @('removal-fail','corrupt','interrupted')) {
            Assert-True ($exit -ne 0 -and $status -in @('recovery-required','pending') -and $data -eq 'migrated') "Recovery did not fail closed: $output"
            Assert-True (Test-Path (Join-Path $fixture 'state\recovery-required')) 'Recovery guard disappeared.'
        } else {
            Assert-True ($exit -ne 0 -and $data -eq 'original' -and ($status -eq 'rolled-back' -or $replacementMode -eq 'pull-fail')) "Rollback failed: $output"
            Assert-True ((Get-Content (Join-Path $fixture 'containers\KLNKSVR-pro.kind') -Raw) -eq 'old') 'Old container not restored.'
            Assert-True ((Get-Content (Join-Path $fixture 'containers\KLNKSVR-pro.running') -Raw) -eq 'true') 'Old container not restarted.'
        }
    }
}

foreach ($watchdogResult in @('committed','rolled-back','recovery-required')) {
    Test-Case "Legacy watchdog exclusion and restoration: $watchdogResult" {
        $script:TaskCalls = @()
        function Get-ScheduledTask { [pscustomobject]@{State='Running';Settings=[pscustomobject]@{Enabled=$true}} }
        function Test-KiloContainer { $true }
        function Get-LegacyKiloConfig { New-Config }
        function Disable-ScheduledTask { $script:TaskCalls += 'Disable' }
        function Stop-ManagedTask { $script:TaskCalls += 'Stop' }
        function Enable-ScheduledTask { $script:TaskCalls += 'Enable' }
        function Start-ScheduledTask { $script:TaskCalls += 'Start' }
        function Invoke-WslScript {
            Assert-True (($script:TaskCalls -join ',') -eq 'Disable,Stop') 'Legacy watchdog was not disabled before replacement.'
            $backup = Get-ChildItem (Join-Path $script:StateRoot 'Backups') -Directory | Select-Object -First 1
            Set-Content (Join-Path $backup.FullName 'status') $watchdogResult
            if ($watchdogResult -ne 'committed') { throw 'fixture replacement failure' }
        }
        if ($watchdogResult -eq 'committed') { Invoke-KiloReplacement (New-Config) }
        else { Assert-Throws { Invoke-KiloReplacement (New-Config) } 'fixture replacement failure' }
        $expected = if ($watchdogResult -eq 'recovery-required') { 'Disable,Stop' } else { 'Disable,Stop,Enable,Start' }
        Assert-True (($script:TaskCalls -join ',') -eq $expected) 'Watchdog resumed despite pending recovery or was not restored.'
    }
}
