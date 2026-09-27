function Convert-ToBashLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'" + '"' + "'" + '"' + "'") + "'"
}

function Get-WslBackupPath {
    param([string]$WindowsPath)
    $path = [IO.Path]::GetFullPath($WindowsPath)
    if ($path -notmatch '^([A-Za-z]):\\') { throw 'Backups require a local Windows drive.' }
    return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + $path.Substring(3).Replace('\','/')
}

function Assert-KiloDeploymentConfig {
    param($Config)
    if ($Config.DistroName -notmatch '^[a-zA-Z0-9_.-]+$' -or
        $Config.LinuxDataPath -notmatch '^/(?:opt|root|home/[a-zA-Z0-9_-]+)/kilolink-server/?$' -or
        $Config.KiloLinkImage -notmatch '^kiloview/klnk-pro(?::[a-zA-Z0-9_.-]+|@sha256:[a-fA-F0-9]{64})?$' -or
        [string]$Config.PublicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        [int]$Config.WebPort -lt 1 -or [int]$Config.WebPort -gt 65535 -or
        [int]$Config.LinkPort -lt 2 -or [int]$Config.LinkPort -gt 65534 -or [int]$Config.LinkPort % 2 -ne 0) {
        throw 'Unsafe KiloLink deployment settings; no container or data was changed.'
    }
}

function Assert-NoPendingKiloRecovery {
    $root = Join-Path $script:StateRoot 'Backups'
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        $status = Join-Path $directory.FullName 'status'
        if ((Test-Path -LiteralPath $status) -and (Get-Content -LiteralPath $status -Raw).Trim() -notin @('committed','rolled-back','backup-complete')) {
            throw "An interrupted KiloLink operation needs recovery from $($directory.FullName). Follow docs/RECOVERY.md before retrying. Its data and previous container were retained."
        }
    }
}

function Get-KiloReplacementScript {
    param($Config, [string]$BackupPath, [string]$BackupId, [switch]$Pull, [switch]$BackupOnly, [switch]$UpdateImage)
    Assert-KiloDeploymentConfig $Config
    if ($BackupId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid backup identifier.' }
    $template = @'
set -euo pipefail
container=__CONTAINER__
previous=__PREVIOUS__
data=__DATA__
backup=__BACKUP__
image=__IMAGE__
operation=__BACKUP_ID__
mkdir -p /var/lib/kilolink
exec 9>/var/lib/kilolink/maintenance.lock
flock -x 9
test ! -e /var/lib/kilolink/recovery-required || { echo 'Recover the previous interrupted operation first.' >&2; exit 30; }
test ! -L "$data" || { echo 'Data directory is a symbolic link.' >&2; exit 31; }
__ACQUIRE__
mkdir -p "$backup" "$data"
existed=0
running=false
restart_policy=always
renamed=0
replacement=0
snapshot=0
recover() {
  result=$?
  trap - EXIT
  if [ "$result" -eq 0 ]; then return; fi
  failed=0
  if [ "$replacement" -eq 1 ]; then
    # Docker must be available, and any replacement must be stopped before restoring data.
    docker info >/dev/null 2>&1 || failed=1
    if [ "$failed" -eq 0 ] && docker inspect "$container" >/dev/null 2>&1; then
      identity=$(docker inspect -f '{{index .Config.Labels "org.kiloview.operation"}}' "$container") || failed=1
      if [ "$failed" -eq 0 ] && [ "$identity" = "$operation" ]; then docker rm -f "$container" >/dev/null 2>&1 || failed=1; else failed=1; fi
    fi
  fi
  if [ "$failed" -eq 0 ] && [ "$snapshot" -eq 1 ] && [ "$replacement" -eq 1 ]; then
    if sha256sum -c "$backup/data.tar.sha256" >/dev/null; then
      find "$data" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || failed=1
      if [ "$failed" -eq 0 ]; then tar --numeric-owner --acls --xattrs -xf "$backup/data.tar" -C "$data" || failed=1; fi
    else failed=1; fi
  fi
  if [ "$failed" -eq 0 ] && [ "$renamed" -eq 1 ]; then docker rename "$previous" "$container" || failed=1; fi
  if [ "$failed" -eq 0 ] && [ "$existed" -eq 1 ]; then docker update --restart "$restart_policy" "$container" >/dev/null || failed=1; fi
  if [ "$failed" -eq 0 ] && [ "$existed" -eq 1 ] && [ "$running" = true ]; then docker start "$container" >/dev/null || failed=1; fi
  if [ "$failed" -eq 0 ]; then printf 'rolled-back\n' > "$backup/status"; rm -f /var/lib/kilolink/recovery-required; else
    printf '%s\n' "$backup" > /var/lib/kilolink/recovery-required
    printf 'recovery-required\n' > "$backup/status"
    echo "Automatic recovery failed. Preserve and restore $backup before starting KiloLink." >&2
  fi
  exit "$result"
}
trap recover EXIT
printf 'pending\n' > "$backup/status"
printf '%s\n' "$backup" > /var/lib/kilolink/recovery-required
if docker inspect "$container" > "$backup/container.json" 2>/dev/null; then
  existed=1
  running=$(docker inspect -f '{{.State.Running}}' "$container")
  restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container")
  docker update --restart=no "$container" >/dev/null
  docker stop --time 30 "$container" >/dev/null
  tar --numeric-owner --acls --xattrs -cf "$backup/data.tar" -C "$data" .
  tar -tf "$backup/data.tar" >/dev/null
  sha256sum "$backup/data.tar" > "$backup/data.tar.sha256"
  snapshot=1
else
  # A failed inspect is not proof of absence (for example, a daemon failure).
  docker container ls -a --format '{{.Names}}' > "$backup/container-names"
  if grep -qx "$container" "$backup/container-names"; then echo 'Existing container could not be inspected safely.' >&2; exit 34; fi
fi
__BACKUP_ONLY__
if [ "$existed" -eq 1 ]; then docker rename "$container" "$previous"; renamed=1; fi
replacement=1
docker run -d --name "$container" --label "org.kiloview.operation=$operation" --label "org.kiloview.source-image=$image" --ulimit nofile=10000:10000 -e 'web_port=__WEB__' -e 'server_port=__LINK__' -e 'stream_server_ip=__IP__' -e 'stream_server_port=__LINK_PLUS_ONE__' -v /var/run/avahi-daemon:/var/run/avahi-daemon -v /var/run/dbus:/var/run/dbus -v "$data":/data --restart=no --network host --privileged=true "$resolved_image" /bin/bash /start_server.sh
healthy=0
for attempt in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ] && curl -fsS --max-time 2 'http://127.0.0.1:__WEB__/' >/dev/null; then healthy=1; break; fi
  sleep 2
done
test "$healthy" -eq 1 || { echo 'Replacement failed its web readiness check; restoring previous data and container.' >&2; exit 32; }
docker inspect "$container" > "$backup/deployed-container.json"
printf 'committed\n' > "$backup/status"
rm -f /var/lib/kilolink/recovery-required
docker update --restart=always "$container" >/dev/null
trap - EXIT
# Preserve the stopped previous container and its exact image for explicit recovery.
echo "KILOLINK_BACKUP=$backup"
'@
    $acquire = if ($Pull) { 'docker pull "$image"' } else { 'docker image inspect "$image" >/dev/null' }
    $acquire = if ($BackupOnly) { '' }
        elseif ($Pull -or $UpdateImage) { $acquire + "`n" + 'resolved_image=$(docker image inspect -f ''{{.Id}}'' "$image")' }
        else { 'resolved_image=$(docker inspect -f ''{{.Image}}'' "$container")' }
    $backupOnlyCode = if ($BackupOnly) { @'
test "$existed" -eq 1 || { echo 'KiloLink is missing.' >&2; exit 33; }
docker update --restart "$restart_policy" "$container" >/dev/null
if [ "$running" = true ]; then docker start "$container" >/dev/null; fi
printf 'backup-complete\n' > "$backup/status"
rm -f /var/lib/kilolink/recovery-required
trap - EXIT
exit 0
'@ } else { '' }
    return $template.Replace('__CONTAINER__',(Convert-ToBashLiteral $script:ContainerName)).Replace('__PREVIOUS__',(Convert-ToBashLiteral ($script:ContainerName + '-previous-' + $BackupId))).Replace('__DATA__',(Convert-ToBashLiteral $Config.LinuxDataPath)).Replace('__BACKUP__',(Convert-ToBashLiteral $BackupPath)).Replace('__BACKUP_ID__',(Convert-ToBashLiteral $BackupId)).Replace('__IMAGE__',(Convert-ToBashLiteral $Config.KiloLinkImage)).Replace('__ACQUIRE__',$acquire).Replace('__BACKUP_ONLY__',$backupOnlyCode).Replace('__WEB__',[string]$Config.WebPort).Replace('__LINK__',[string]$Config.LinkPort).Replace('__LINK_PLUS_ONE__',[string]([int]$Config.LinkPort+1)).Replace('__IP__',[string]$Config.PublicIp)
}

function Invoke-KiloReplacement {
    param($Config, [switch]$Pull, [switch]$BackupOnly, [switch]$UpdateImage)
    Assert-KiloDeploymentConfig $Config
    Assert-NoPendingKiloRecovery
    $id = [guid]::NewGuid().ToString('N')
    $directory = Join-Path $script:StateRoot ('Backups\' + $id)
    $existing = if (Test-KiloContainer $Config.DistroName) { Get-LegacyKiloConfig $Config.DistroName } else { $null }
    if ($existing -and $existing.LinuxDataPath.TrimEnd('/') -ne $Config.LinuxDataPath.TrimEnd('/')) { throw 'Moving KiloLink data requires an explicit migration, not repair.' }
    Write-StateJson (Join-Path $directory 'deployment.json') ([ordered]@{schemaVersion=1; backupId=$id; createdUtc=[datetime]::UtcNow.ToString('o'); before=$existing; requested=$Config})
    $linux = Get-KiloReplacementScript $Config (Get-WslBackupPath $directory) $id -Pull:$Pull -BackupOnly:$BackupOnly -UpdateImage:$UpdateImage
    # Older installed watchdogs do not know about the Linux lock. Disable their
    # triggers as well as stopping the current instance during migration/backup.
    $watchdog = Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
    $enabled = $watchdog -and [bool]$watchdog.Settings.Enabled
    $running = $watchdog -and $watchdog.State -eq 'Running'
    if ($watchdog) {
        Write-StateJson (Join-Path $directory 'watchdog.json') @{enabled=$enabled; running=$running; taskName=$script:StartupTaskName}
        if ($enabled) { Disable-ScheduledTask -TaskName $script:StartupTaskName | Out-Null }
    }
    try {
        Stop-ManagedTask $script:StartupTaskName
        Invoke-WslScript $Config.DistroName $linux
    } finally {
        $statusPath = Join-Path $directory 'status'
        $status = if (Test-Path -LiteralPath $statusPath) { (Get-Content -LiteralPath $statusPath -Raw).Trim() } else { 'not-started' }
        if ($enabled -and $status -in @('committed','rolled-back','backup-complete','not-started')) {
            Enable-ScheduledTask -TaskName $script:StartupTaskName | Out-Null
            if ($running) { Start-ScheduledTask -TaskName $script:StartupTaskName }
        }
    }
    Write-Detail "KiloLink recovery files: $directory" Green
}
