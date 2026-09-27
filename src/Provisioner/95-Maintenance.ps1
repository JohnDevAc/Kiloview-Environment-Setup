function Update-SuiteRuntimePackages {
    param([string]$Distro)
    Invoke-WslScript $Distro @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/lib/kilolink
exec 9>/var/lib/kilolink/maintenance.lock
flock -x 9
test ! -e /var/lib/kilolink/recovery-required
apt-get update
apt-get upgrade -y
systemctl enable --now docker avahi-daemon
'@
}

function Maintain-SuiteRuntime {
    Assert-ServerOwner
    Assert-NoPendingKiloRecovery
    if (-not $AcceptLicenses) { throw 'Runtime maintenance requires vendor licence acceptance.' }
    $config = Get-SavedConfig
    if (-not $config) { throw 'Install the server before maintaining its runtime.' }
    Start-DeploymentJournal 'MaintainRuntime' $config
    Set-OperationOutcome 'Running' 'Maintaining the WSL, Ubuntu and Docker runtime.'
    if (-not (Invoke-DeploymentStep 'WSL runtime' { Ensure-WslFeatures })) { return }
    Invoke-DeploymentStep 'Linux source readiness' { Assert-LinuxDownloads $config.DistroName }
    Invoke-DeploymentStep 'Consistent KiloLink data backup' { Invoke-KiloReplacement $config -BackupOnly }
    Invoke-DeploymentStep 'Linux runtime updates' {
        Invoke-WslScript $config.DistroName @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mkdir -p /var/lib/kilolink
exec 9>/var/lib/kilolink/maintenance.lock
flock -x 9
test ! -e /var/lib/kilolink/recovery-required
apt-get update
apt-get upgrade -y
systemctl enable --now docker avahi-daemon
'@
    }
    Invoke-DeploymentStep 'Service health' { Test-SuiteHealth $config }
    Clear-ResumeContinuation
    Set-OperationOutcome 'Completed' 'Runtime maintenance completed. Application versions were retained.'
}

function Backup-SuiteData {
    Assert-ServerOwner
    $config = Get-SavedConfig
    if (-not $config) { throw 'A configured server is required for backup.' }
    Start-DeploymentJournal 'Backup' $config
    Set-OperationOutcome 'Running' 'Backing up KiloLink data; the container will stop briefly.'
    Invoke-DeploymentStep 'Consistent KiloLink data backup' { Invoke-KiloReplacement $config -BackupOnly }
    Set-OperationOutcome 'Completed' 'KiloLink backup completed in ProgramData\KiloLink\Backups.'
}
