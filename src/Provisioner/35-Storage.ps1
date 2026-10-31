# A snapshot of host headroom, not a prediction of total installation/data size.
function Initialize-StorageProbe {
    if ('KiloLink.Storage.VolumeProbe' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace KiloLink.Storage {
    public sealed class VolumeSpace {
        public string VolumeId;
        public string VolumePath;
        public ulong AvailableBytes;
    }
    public static class VolumeProbe {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool GetVolumePathName(string path, StringBuilder volume, uint length);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool GetVolumeNameForVolumeMountPoint(string mount, StringBuilder name, uint length);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool GetDiskFreeSpaceEx(string path, out ulong available, out ulong total, out ulong free);
        public static VolumeSpace Read(string directory) {
            var mount=new StringBuilder(32768);
            if(!GetVolumePathName(directory,mount,(uint)mount.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var id=new StringBuilder(1024);
            if(!GetVolumeNameForVolumeMountPoint(mount.ToString(),id,(uint)id.Capacity)) throw new Win32Exception(Marshal.GetLastWin32Error());
            ulong available,total,free;
            // This follows junctions and uses the caller's quota, not disk size
            // or free space that is unavailable to the installing account.
            if(!GetDiskFreeSpaceEx(directory,out available,out total,out free)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return new VolumeSpace { VolumeId=id.ToString(),VolumePath=mount.ToString(),AvailableBytes=available };
        }
    }
}
'@
}

function Get-LocalStoragePath([string]$Path) {
    $pathText=[Environment]::ExpandEnvironmentVariables($Path)
    if ($pathText -match '^(?:\\\\\?\\|\\\?\?\\)[A-Za-z]:\\') { $pathText=$pathText.Substring(4) }
    if ($pathText -notmatch '^[A-Za-z]:[\\/]') { throw "Storage path is not an absolute local drive path: $Path" }
    return [IO.Path]::GetFullPath($pathText)
}

function Get-WindowsStorageVolume([string]$Path) {
    $directory=Get-LocalStoragePath $Path
    while (-not (Test-Path -LiteralPath $directory -PathType Container -ErrorAction Stop)) {
        $parent=[IO.Path]::GetDirectoryName($directory.TrimEnd('\'))
        if (-not $parent -or $parent -eq $directory) { throw "Storage volume is unavailable for $Path" }
        $directory=$parent
    }
    Initialize-StorageProbe
    return [KiloLink.Storage.VolumeProbe]::Read($directory)
}

function Get-WslStorageRegistrations {
    # Passive current-owner registry lookup; never launch WSL for preflight.
    $root='HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $root -ErrorAction Stop)) { return @() }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        $entry=Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
        [pscustomobject]@{Name=[string](Get-PropertyValue $entry 'DistributionName' '');Path=[string](Get-PropertyValue $entry 'BasePath' '')}
    }
}

function Get-NewManagedDistroPath {
    if (-not (Get-Variable PlannedDistroPath -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
        # A new attempt never adopts or deletes an unregistered/orphaned VHD.
        $script:PlannedDistroPath=Join-Path $env:LOCALAPPDATA ('Kiloview Environment Setup\WSL\'+$script:ManagedDistroName+'-'+[guid]::NewGuid().ToString('N'))
    }
    return $script:PlannedDistroPath
}

function Get-ServerStorageTargets($Config) {
    $registered=@(Get-WslStorageRegistrations)
    $selected=@()
    foreach ($name in @([string]$Config.DistroName,$script:ManagedDistroName)|Select-Object -Unique) {
        $selected=@($registered|Where-Object {$_.Name -eq $name})
        if ($selected.Count -gt 1) { throw "Distribution storage registration is ambiguous: $name" }
        if ($selected.Count -eq 1) { break }
    }
    $distroPath=if ($selected.Count) {
        if (-not $selected[0].Path) { throw 'The registered distribution has no disk location.' }
        $selected[0].Path
    } else { Get-NewManagedDistroPath }
    # Policy: 16 GiB distro growth headroom, 2 GiB Windows working space,
    # 2 GiB download/state staging. Sum purposes sharing a volume; do not count
    # the same purpose twice on one volume. These are reserves, not guarantees.
    [pscustomobject]@{Path=$distroPath;Purpose='WSL disk';Budget='distro';Bytes=16GB}
    if (-not $env:WINDIR -or -not $env:ProgramFiles) { throw 'The Windows and application storage paths are unavailable.' }
    foreach ($path in @($env:WINDIR,$env:ProgramFiles)+@(Get-NdiToolsRoots)) {
        if ($path) { [pscustomobject]@{Path=$path;Purpose='Windows/NDI';Budget='windows';Bytes=2GB} }
    }
    foreach ($path in @((Join-Path $env:TEMP 'KiloLinkSuite'),$script:StateRoot)) {
        [pscustomobject]@{Path=$path;Purpose='Downloads/state';Budget='staging';Bytes=2GB}
    }
}

function Assert-ServerStorage($Config) {
    $volumes=@{}
    $details=New-Object 'Collections.Generic.List[string]'
    try {
        foreach ($target in @(Get-ServerStorageTargets $Config)) {
            $space=Get-WindowsStorageVolume $target.Path
            if (-not $space.VolumeId -or -not $space.VolumePath -or $null -eq $space.AvailableBytes) { throw 'Storage probe returned incomplete volume information.' }
            if (-not $volumes.ContainsKey($space.VolumeId)) {
                $volumes[$space.VolumeId]=@{Path=$space.VolumePath;Available=[decimal]$space.AvailableBytes;Budgets=@{}}
            }
            $volume=$volumes[$space.VolumeId]
            $volume.Available=[Math]::Min($volume.Available,[decimal]$space.AvailableBytes)
            $volume.Budgets[$target.Budget]=[decimal]$target.Bytes
            $details.Add(('Storage target {0}: {1}; volume {2}; reserve {3} GiB ({4}).' -f $target.Purpose,$target.Path,$space.VolumePath,($target.Bytes/1GB),$target.Budget))
        }
        if (-not $volumes.Count) { throw 'No Server storage volumes could be identified.' }
    } catch {
        Write-InstallerLog ('Storage preflight could not determine capacity: '+$_.Exception.Message)
        $script:LifecycleErrorCode='storage-preflight-unavailable'
        $script:LifecycleNextAction='Check the storage paths and permissions in diagnostics, then retry Server setup.'
        throw 'Cannot verify Server disk space. Check diagnostics, then retry.'
    }
    foreach ($line in $details) { Write-InstallerLog $line }
    foreach ($entry in $volumes.GetEnumerator()|Sort-Object Name) {
        $volume=$entry.Value
        $required=[decimal]0
        foreach ($bytes in $volume.Budgets.Values) { $required+=$bytes }
        Write-InstallerLog ('Storage preflight {0} ({1}): available={2} bytes; policyReserve={3} bytes. Snapshot only; future packages/data/backups may need more.' -f $volume.Path,$entry.Key,$volume.Available,$required)
        if ($volume.Available -lt $required) {
            $needed=[Math]::Ceiling(($required-$volume.Available)/1GB)
            $script:LifecycleErrorCode='insufficient-disk-space'
            $script:LifecycleNextAction='Free space on the reported Windows volume, then retry Server setup. See diagnostics for the safety-reserve calculation.'
            throw ("Free at least {0} GiB on {1} before Server setup ({2:N1} GiB available; {3:N0} GiB safety reserve)." -f $needed,$volume.Path,($volume.Available/1GB),($required/1GB))
        }
    }
}

function Get-NewWslInstallArguments {
    # Only called after the runtime is installed. An unsupported runtime must
    # not silently fall back to a different, unchecked default location.
    $help=@(Invoke-Native wsl.exe @('--help') -Capture -IgnoreExitCode -ReadOnly -TimeoutSeconds 30 -StallSeconds 30)
    # Invoke-Native publishes the observed exit globally. WSL 3.0.3 (and older
    # builds) returns -1 for informational --help, even with complete valid help.
    # Accept that help-only convention only alongside an advertised option line.
    $helpExitCode=$global:LASTEXITCODE
    $advertisesLocation=(($help -join "`n") -replace [char]0,'') -match '(?m)^[ \t]*--location(?:[ \t]|$)'
    Write-InstallerLog ("WSL install-location probe: helpExitCode={0}; advertised={1}." -f $helpExitCode,$advertisesLocation)
    if ($helpExitCode -notin @(0,-1)) {
        $script:LifecycleErrorCode='wsl-location-probe-failed'
        $script:LifecycleNextAction='Check the WSL help failure in diagnostics, then retry Server setup.'
        throw "Cannot verify WSL install-location support (help exit $helpExitCode). Check diagnostics, then retry."
    }
    if (-not $advertisesLocation) {
        $script:LifecycleErrorCode='wsl-location-unsupported'
        $script:LifecycleNextAction='Update WSL to a runtime with the --location install option, then retry Server setup.'
        throw 'Update WSL before Server setup; this runtime does not advertise install-location support.'
    }
    $location=Get-NewManagedDistroPath
    Initialize-LifecycleProtocol
    [KiloLink.Lifecycle.SafePath]::CheckParent($location)
    if (Test-Path -LiteralPath $location) { throw 'The new WSL storage folder already exists. It was retained; retry with a new setup operation.' }
    $parent=Split-Path -Parent $location
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop|Out-Null
    [KiloLink.Lifecycle.SafePath]::CheckParent($location)
    Write-InstallerLog "New managed WSL disk location: $location"
    return @('--install',$script:ApplicationManifest.runtime.ubuntuDistribution,'--name',$script:ManagedDistroName,'--version','2','--no-launch','--web-download','--location',$location)
}
