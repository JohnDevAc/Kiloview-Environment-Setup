function Test-SupportedWindows {
    $current = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$current.CurrentBuildNumber
    if ($build -lt 22621) {
        throw 'Windows 11 22H2 (build 22621) or later is required for mirrored WSL networking.'
    }
}

function Ensure-WslFeatures {
    Test-SupportedWindows
    Write-Step 'Checking WSL prerequisites'
    $restart = $false
    foreach ($name in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
        if ($feature.State -eq 'EnablePending') {
            $restart = $true
            continue
        }
        if ($feature.State -ne 'Enabled') {
            Write-Detail "Enabling $name"
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
            if ($result.RestartNeeded) { $restart = $true }
            $verified = Get-WindowsOptionalFeature -Online -FeatureName $name
            if ($verified.State -notin @('Enabled', 'EnablePending')) {
                throw "Windows feature $name did not enter an enabled state. Current state: $($verified.State)."
            }
            if ($verified.State -eq 'EnablePending') { $restart = $true }
        }
    }
    if ($restart) {
        Request-RestartAndResume 'Windows must finish enabling WSL and Virtual Machine Platform before Linux can start.'
        return $false
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Request-RestartAndResume 'Windows enabled the required features but wsl.exe is not available until the next restart.'
        return $false
    }
    if (-not (Test-WslRuntime)) {
        Write-Step 'Installing the Windows Subsystem for Linux runtime'
        Invoke-Native wsl.exe @('--install', '--no-distribution', '--web-download')
        Set-SuiteProgress -Percent ([Math]::Min(14, $script:ProgressPercent + 2)) -Status 'Waiting for the WSL runtime to become ready'
        if (-not (Wait-WslRuntime -TimeoutSeconds 120)) {
            Request-RestartAndResume 'The WSL runtime was installed but has not become ready in the current Windows session.'
            return $false
        }
    }
    Write-Step 'Verifying the Windows Subsystem for Linux runtime'
    if ($Action -in @('Setup','MaintainRuntime')) { Invoke-Native wsl.exe @('--update', '--web-download') }
    if (-not (Wait-WslRuntime -TimeoutSeconds 180)) {
        Request-RestartAndResume 'WSL did not report a healthy runtime after installation and update.'
        return $false
    }
    Invoke-Native wsl.exe @('--set-default-version', '2')
    if (-not (Test-WslRuntime)) {
        throw 'WSL stopped responding after its default version was set. Check virtualization support and the diagnostic log.'
    }
    Write-Detail 'WSL runtime and required Windows features are ready.' Green
    return $true
}

function Set-IniKey {
    param(
        [Collections.Generic.List[string]]$Lines,
        [string]$Section,
        [string]$Key,
        [string]$Value
    )
    $sectionIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match ('^\s*\[{0}\]\s*$' -f [regex]::Escape($Section))) {
            $sectionIndex = $i
            break
        }
    }
    if ($sectionIndex -lt 0) {
        if ($Lines.Count -gt 0) { $Lines.Add('') }
        $Lines.Add("[$Section]")
        $Lines.Add("$Key=$Value")
        return $true
    }
    $nextSection = $Lines.Count
    for ($i = $sectionIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*\[.+\]\s*$') {
            $nextSection = $i
            break
        }
    }
    for ($i = $sectionIndex + 1; $i -lt $nextSection; $i++) {
        if ($Lines[$i] -match ('^\s*{0}\s*=' -f [regex]::Escape($Key))) {
            $newValue = "$Key=$Value"
            if ($Lines[$i] -ne $newValue) {
                $Lines[$i] = $newValue
                return $true
            }
            return $false
        }
    }
    $Lines.Insert($nextSection, "$Key=$Value")
    return $true
}

function Ensure-MirroredNetworking {
    Write-Step 'Configuring mirrored WSL networking on all physical adapters'
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $lines = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path) { $lines.Add([string]$line) }
    }
    $changed = $false
    $changed = (Set-IniKey $lines 'wsl2' 'networkingMode' 'mirrored') -or $changed
    $changed = (Set-IniKey $lines 'wsl2' 'dnsTunneling' 'true') -or $changed
    $changed = (Set-IniKey $lines 'wsl2' 'firewall' 'true') -or $changed
    $changed = (Set-IniKey $lines 'experimental' 'hostAddressLoopback' 'true') -or $changed
    if ($changed) {
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllLines($path, $lines.ToArray(), $utf8)
        Invoke-Native wsl.exe @('--shutdown') -IgnoreExitCode
    }
}

function Ensure-Ubuntu {
    param($Config)
    $distro = Get-UbuntuDistro ([string]$Config.DistroName)
    if (-not $distro) {
        Write-Step "Installing dedicated Ubuntu WSL 2 distribution '$($script:ManagedDistroName)'"
        Invoke-Native wsl.exe @('--install', $script:ApplicationManifest.runtime.ubuntuDistribution, '--name', $script:ManagedDistroName, '--version', '2', '--no-launch', '--web-download')
        Set-SuiteProgress -Percent ([Math]::Min(27, $script:ProgressPercent + 2)) -Status 'Waiting for the dedicated Ubuntu distribution to register'
        if (-not (Wait-WslDistroRegistration -Distro $script:ManagedDistroName -TimeoutSeconds 180)) {
            Request-RestartAndResume "The $($script:ManagedDistroName) distribution was installed but has not registered in the current Windows session."
            return $null
        }
        $distro = $script:ManagedDistroName
    }
    $Config.DistroName = $distro
    Save-Config $Config
    Write-Step "Verifying $distro as a working WSL 2 distribution"
    $probe = Get-WslDistroLaunchProbe $distro
    if (-not $probe.Success) {
        $message = Get-WslLaunchFailureMessage -Distro $distro -Output $probe.Output
        if ($message -match 'nested virtualization') { throw $message }
        Set-SuiteProgress -Percent ([Math]::Min(28, $script:ProgressPercent + 1)) -Status "Waiting for $distro to finish its first launch"
        if (-not (Wait-WslDistroReady -Distro $distro -TimeoutSeconds 180)) {
            $probe = Get-WslDistroLaunchProbe $distro
            throw (Get-WslLaunchFailureMessage -Distro $distro -Output $probe.Output)
        }
    }
    $version = Get-WslDistroVersion $distro
    if ($version -ne 2) {
        Write-Step "Converting $distro to WSL 2"
        Invoke-Native wsl.exe @('--set-version', $distro, '2')
    }
    if (-not (Wait-WslDistroReady -Distro $distro -TimeoutSeconds 60)) {
        $probe = Get-WslDistroLaunchProbe $distro
        throw (Get-WslLaunchFailureMessage -Distro $distro -Output $probe.Output)
    }
    return $distro
}

function Ensure-Docker {
    param([string]$Distro)
    Write-Step "Installing systemd, Docker Engine, and Avahi in $Distro"

    Set-SuiteProgress -Percent ([Math]::Min(40, $script:ProgressPercent + 2)) -Status 'Enabling systemd in the dedicated WSL distribution'
    $enableSystemd = @'
set -euo pipefail
touch /etc/wsl.conf
awk '
BEGIN { in_boot=0; saw_boot=0; wrote_systemd=0 }
function finish_boot() {
    if (in_boot && !wrote_systemd) {
        print "systemd=true"
        wrote_systemd=1
    }
}
/^[[:space:]]*\[boot\][[:space:]]*$/ {
    finish_boot()
    in_boot=1
    saw_boot=1
    wrote_systemd=0
    print
    next
}
/^[[:space:]]*\[.*\][[:space:]]*$/ {
    finish_boot()
    in_boot=0
    print
    next
}
in_boot && /^[[:space:]]*systemd[[:space:]]*=/ {
    if (!wrote_systemd) {
        print "systemd=true"
        wrote_systemd=1
    }
    next
}
{ print }
END {
    finish_boot()
    if (!saw_boot) {
        print ""
        print "[boot]"
        print "systemd=true"
    }
}
' /etc/wsl.conf > /etc/wsl.conf.kilolink
if cmp -s /etc/wsl.conf.kilolink /etc/wsl.conf; then
    rm /etc/wsl.conf.kilolink
else
    mv /etc/wsl.conf.kilolink /etc/wsl.conf
fi
# A prior interrupted attempt may have saved systemd=true without restarting.
# Conversely, a running systemd does not need a restart after normalizing config.
if [ "$(ps -p 1 -o comm= | tr -d ' ')" = "systemd" ]; then
    echo KILOLINK_SYSTEMD_READY
else
    echo KILOLINK_SYSTEMD_RESTART_REQUIRED
fi
'@
    $systemdState = @(Invoke-WslScript $Distro $enableSystemd -Capture)
    if ($systemdState -contains 'KILOLINK_SYSTEMD_RESTART_REQUIRED') {
        Set-SuiteProgress -Percent ([Math]::Min(42, $script:ProgressPercent + 2)) -Status "Restarting $Distro with systemd enabled"
        Invoke-Native wsl.exe @('--terminate', $Distro)
        if (-not (Wait-WslDistroReady -Distro $Distro -TimeoutSeconds 120)) {
            throw "$Distro did not restart with systemd within 120 seconds."
        }
    } elseif ($systemdState -notcontains 'KILOLINK_SYSTEMD_READY') {
        throw "Could not verify the systemd state in $Distro. No distribution was restarted."
    }

    Set-SuiteProgress -Percent ([Math]::Min(44, $script:ProgressPercent + 2)) -Status 'Installing Linux networking and service prerequisites'
    $installDocker = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg avahi-daemon dbus iproute2 libnss-mdns

# WSL appends the Windows PATH by default. Docker Desktop can therefore make
# `command -v docker` resolve to a Windows interop shim under /mnt/c even when
# this dedicated distro has no Linux Docker Engine or docker.service.
if [ ! -x /usr/bin/docker ] || ! dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'install ok installed'; then
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "$pkg" >/dev/null 2>&1 || true
    done
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if [ "$(ps -p 1 -o comm= | tr -d ' ')" != "systemd" ]; then
    echo "systemd is not PID 1" >&2
    exit 20
fi
systemctl enable --now docker
systemctl enable --now avahi-daemon
docker version >/dev/null
'@
    Invoke-WslScript $Distro $installDocker
}

function Install-KiloLink {
    param($Config)
    if (Test-KiloContainer $Config.DistroName) {
        Write-Detail 'KiloLink Server Pro is already installed.' Green
        Invoke-Wsl $Config.DistroName "test ! -e /var/lib/kilolink/recovery-required && docker update --restart always '$script:ContainerName' >/dev/null && docker start '$script:ContainerName' >/dev/null"
        return
    }

    Write-Step 'Installing KiloLink Server Pro'
    # Deploy the official image with the same container settings published by
    # Kiloview's installer. This avoids automating a variable interactive prompt
    # sequence while retaining the user's explicit licence acceptance above.
    Recreate-KiloContainer $Config -Pull
    Write-Detail 'KiloLink Server Pro installed.' Green
}

function Recreate-KiloContainer {
    param($Config, [switch]$Pull, [switch]$UpdateImage)
    Invoke-DeploymentStep 'Replace KiloLink with backup and health verification' { Invoke-KiloReplacement $Config -Pull:$Pull -UpdateImage:$UpdateImage }
}

function Sync-KiloConfig {
    param($Config, [switch]$Latest)
    if ($Latest) { $Config.KiloLinkImage = $script:KiloImage }
    if (-not (Test-KiloContainer $Config.DistroName)) {
        Install-KiloLink $Config
        return
    }
    # The saved file records the requested settings for restart continuation.
    # Only the live container can tell us what a previous attempt actually applied.
    $actual = Get-LegacyKiloConfig $Config.DistroName
    if (-not $actual) {
        throw 'Could not read the live KiloLink container configuration. Repair cannot safely compare its settings.'
    }
    $changed =
        ([string]$actual.PublicIp -ne [string]$Config.PublicIp) -or
        ([int]$actual.WebPort -ne [int]$Config.WebPort) -or
        ([int]$actual.LinkPort -ne [int]$Config.LinkPort) -or
        ([string]$actual.LinuxDataPath -ne [string]$Config.LinuxDataPath) -or
        ([string]$actual.KiloLinkImage -ne [string]$Config.KiloLinkImage)
    if ($changed) {
        Write-Step 'Applying the changed KiloLink network configuration'
        Recreate-KiloContainer $Config -UpdateImage:$Latest
    } else {
        Invoke-Wsl $Config.DistroName "test ! -e /var/lib/kilolink/recovery-required && docker update --restart always '$script:ContainerName' >/dev/null && docker start '$script:ContainerName' >/dev/null"
        if ($Latest) { Update-KiloLink $Config }
    }
}
