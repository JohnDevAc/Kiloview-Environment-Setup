#Requires -Version 5.1
<#
.SYNOPSIS
    Menu-driven installer for KiloLink Server Pro, NDI Tools, and NDI Discovery Server.

.DESCRIPTION
    KiloLink runs in Docker Engine inside Ubuntu WSL 2. Windows 11 mirrored
    networking exposes its TCP, UDP, and multicast traffic on physical adapters.
    The selected wired/DHCP address is advertised to KiloLink devices, while the
    services listen on all available interfaces.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:StateRoot = Join-Path $env:ProgramData 'KiloLink'
$script:ConfigPath = Join-Path $script:StateRoot 'installer-config.json'
$script:StartupScriptPath = Join-Path $script:StateRoot 'start-kilolink.ps1'
$script:StartupTaskName = 'KiloLink WSL Startup'
$script:NdiTaskName = 'NDI Discovery Server Startup'
$script:FirewallGroup = 'KiloLink Suite Installer'
$script:HyperVPrefix = 'KiloLinkSuite-'
$script:WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$script:ContainerName = 'KLNKSVR-pro'
$script:KiloImage = 'kiloview/klnk-pro:latest'
$script:LinuxDataPath = '/opt/kilolink-server'
$script:NdiToolsUrl = 'https://downloads.ndi.tv/Tools/NDI%206%20Tools.exe'
$script:KiloInstallerUrl = 'https://www.kiloview.com/downloads/klnk-pro/install.sh'

function Write-Heading {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "-- $Text" -ForegroundColor Yellow
}

function Get-PropertyValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $Default
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if (Test-Administrator) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Save this script to a .ps1 file before running it.'
    }
    Write-Host 'Requesting Administrator access...' -ForegroundColor Yellow
    $quotedPath = '"' + $PSCommandPath + '"'
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $quotedPath" -Verb RunAs | Out-Null
    exit 0
}

function Get-SavedConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return $null
    }
    try {
        return Get-Content -Raw -LiteralPath $script:ConfigPath | ConvertFrom-Json
    } catch {
        Write-Warning "Saved configuration is unreadable: $($_.Exception.Message)"
        return $null
    }
}

function Save-Config {
    param($Config)
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    if ($null -eq $Config.PSObject.Properties['UpdatedAt']) {
        $Config | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue (Get-Date).ToString('o')
    } else {
        $Config.UpdatedAt = (Get-Date).ToString('o')
    }
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode,
        [switch]$Capture
    )
    if ($Capture) {
        $output = & $FilePath @Arguments 2>&1
    } else {
        & $FilePath @Arguments
        $output = $null
    }
    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw ('Command failed with exit code {0}: {1} {2}' -f $code, $FilePath, ($Arguments -join ' '))
    }
    if ($Capture) {
        return @($output | ForEach-Object { [string]$_ })
    }
}

function Get-WslDistroNames {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return @()
    }
    $output = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    return @($output | ForEach-Object { ([string]$_ -replace [char]0, '').Trim() } | Where-Object { $_ })
}

function Get-UbuntuDistro {
    param([string]$Preferred)
    $distros = @(Get-WslDistroNames)
    if ($Preferred -and $distros -contains $Preferred) {
        return $Preferred
    }
    return @($distros | Where-Object { $_ -match '^Ubuntu(?:-|$)' } | Select-Object -First 1)[0]
}

function Invoke-Wsl {
    param(
        [string]$Distro,
        [string]$Command,
        [switch]$IgnoreExitCode,
        [switch]$Capture
    )
    $arguments = @('-d', $Distro, '-u', 'root', '--', 'bash', '-lc', $Command)
    return Invoke-Native wsl.exe $arguments -IgnoreExitCode:$IgnoreExitCode -Capture:$Capture
}

function Invoke-WslScript {
    param(
        [string]$Distro,
        [string]$Content,
        [switch]$Capture
    )
    $utf8 = New-Object Text.UTF8Encoding($false)
    $base64 = [Convert]::ToBase64String($utf8.GetBytes($Content))
    $command = "printf '%s' '$base64' | base64 -d > /tmp/kilolink-suite.sh && chmod 700 /tmp/kilolink-suite.sh && bash /tmp/kilolink-suite.sh"
    return Invoke-Wsl $Distro $command -Capture:$Capture
}

function Test-KiloContainer {
    param([string]$Distro)
    if (-not $Distro) {
        return $false
    }
    & wsl.exe -d $Distro -u root -- bash -lc "docker inspect '$script:ContainerName' >/dev/null 2>&1" 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-NdiRegistration {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    }
    return @($items | Where-Object {
        $name = [string](Get-PropertyValue $_ 'DisplayName' '')
        $publisher = [string](Get-PropertyValue $_ 'Publisher' '')
        $name -match '^NDI\s+\d+\s+Tools' -or ($name -match 'NDI.*Tools' -and $publisher -match 'NDI|Vizrt|NewTek')
    } | Select-Object -First 1)[0]
}

function Get-NdiDiscoveryExe {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'NDI\NDI 6 Tools\Discovery\NDI Discovery Service.exe'),
        (Join-Path $env:ProgramFiles 'NDI\NDI 6 Tools\Discovery Service\NDI Discovery Service.exe')
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    $root = Join-Path $env:ProgramFiles 'NDI'
    if (Test-Path -LiteralPath $root) {
        $found = Get-ChildItem -LiteralPath $root -Filter 'NDI Discovery Service.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }
    return $null
}

function Get-NdiDiscoveryService {
    return @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'NDI.*Discovery' -or $_.DisplayName -match 'NDI.*Discovery'
    } | Select-Object -First 1)[0]
}

function Get-InstallState {
    $config = Get-SavedConfig
    $preferred = if ($config) { [string](Get-PropertyValue $config 'DistroName' '') } else { '' }
    $distro = Get-UbuntuDistro $preferred
    $container = if ($distro) { Test-KiloContainer $distro } else { $false }
    $ndi = Get-NdiRegistration
    $startup = Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
    $ndiTask = Get-ScheduledTask -TaskName $script:NdiTaskName -ErrorAction SilentlyContinue
    $ndiService = Get-NdiDiscoveryService
    return [pscustomobject]@{
        Any = [bool]($config -or $container -or $ndi -or $startup -or $ndiTask -or $ndiService)
        Config = $config
        Distro = $distro
        KiloLink = $container
        NDITools = [bool]$ndi
        NDIServer = [bool]($ndiTask -or $ndiService)
    }
}

function Get-LanCandidates {
    $list = New-Object Collections.Generic.List[object]
    $configurations = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address
    })
    foreach ($item in $configurations) {
        $alias = [string]$item.InterfaceAlias
        $description = [string]$item.InterfaceDescription
        if ($alias -match 'vEthernet|WSL|Loopback|Docker|Hyper-V|Default Switch' -or
            $description -match 'Virtual|Hyper-V|Docker|WSL|Loopback|VPN|TAP|Tunnel') {
            continue
        }
        foreach ($address in @($item.IPv4Address)) {
            if ($address.IPAddress -like '127.*' -or $address.IPAddress -like '169.254.*') {
                continue
            }
            $isWired = $alias -match 'Ethernet|Local Area|LAN' -or $description -match 'Ethernet|Gigabit|2.5Gb|10Gb'
            $isDhcp = $address.PrefixOrigin -eq 'Dhcp'
            $hasGateway = [bool]$item.IPv4DefaultGateway
            $score = 0
            if ($isWired) { $score += 100 }
            if ($isDhcp) { $score += 20 }
            if ($hasGateway) { $score += 10 }
            $list.Add([pscustomobject]@{
                Alias = $alias
                Description = $description
                Address = [string]$address.IPAddress
                Dhcp = $isDhcp
                Wired = $isWired
                Score = $score
            })
        }
    }
    $sort = @(
        @{ Expression = 'Score'; Descending = $true },
        @{ Expression = 'Alias'; Descending = $false }
    )
    return @($list | Sort-Object -Property $sort)
}

function Select-PrimaryLanAddress {
    param($Saved)
    $candidates = @(Get-LanCandidates)
    if ($candidates.Count -eq 0) {
        throw 'No physical Ethernet or Wi-Fi IPv4 address was detected. Connect the PC to the network and retry.'
    }
    $savedAlias = if ($Saved) { [string](Get-PropertyValue $Saved 'PrimaryInterfaceAlias' '') } else { '' }
    $defaultIndex = 0
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        if ($savedAlias -and $candidates[$i].Alias -eq $savedAlias) {
            $defaultIndex = $i
            break
        }
    }
    Write-Host ''
    Write-Host 'Physical network addresses (internal Docker/WSL adapters are excluded):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $type = if ($candidates[$i].Wired) { 'wired' } else { 'wireless' }
        $origin = if ($candidates[$i].Dhcp) { 'DHCP' } else { 'static/manual' }
        Write-Host ("  {0}. {1} - {2} ({3}, {4})" -f ($i + 1), $candidates[$i].Alias, $candidates[$i].Address, $type, $origin)
    }
    while ($true) {
        $answer = Read-Host "Primary advertised adapter [$($defaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $candidates[$defaultIndex]
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $candidates.Count) {
            return $candidates[$number - 1]
        }
        Write-Host 'Choose one of the listed adapter numbers.' -ForegroundColor Red
    }
}

function Read-Port {
    param([string]$Prompt, [int]$Default, [switch]$EvenPair)
    while ($true) {
        $answer = Read-Host "$Prompt [$Default]"
        $number = $Default
        if ($answer -and -not [int]::TryParse($answer, [ref]$number)) {
            Write-Host 'Enter a numeric port.' -ForegroundColor Red
            continue
        }
        $maximum = if ($EvenPair) { 65534 } else { 65535 }
        if ($number -lt 1 -or $number -gt $maximum) {
            Write-Host "Enter a port between 1 and $maximum." -ForegroundColor Red
            continue
        }
        if ($EvenPair -and $number % 2 -ne 0) {
            Write-Host 'The KiloLink link port must be even because it uses this port and the next one.' -ForegroundColor Red
            continue
        }
        return $number
    }
}

function Get-LegacyKiloConfig {
    param([string]$Distro)
    if (-not $Distro -or -not (Test-KiloContainer $Distro)) {
        return $null
    }
    try {
        $lines = Invoke-Wsl $Distro "docker inspect '$script:ContainerName'" -Capture
        $inspection = ($lines -join [Environment]::NewLine) | ConvertFrom-Json
        $container = @($inspection)[0]
        $environment = @{}
        foreach ($entry in @($container.Config.Env)) {
            if ($entry -match '^([^=]+)=(.*)$') {
                $environment[$matches[1]] = $matches[2]
            }
        }
        $mount = @($container.Mounts | Where-Object { $_.Destination -eq '/data' } | Select-Object -First 1)[0]
        return [pscustomobject]@{
            PublicIp = if ($environment.ContainsKey('stream_server_ip')) { $environment.stream_server_ip } else { $null }
            WebPort = if ($environment.ContainsKey('web_port')) { $environment.web_port } else { $null }
            LinkPort = if ($environment.ContainsKey('server_port')) { $environment.server_port } else { $null }
            LinuxDataPath = if ($mount) { [string]$mount.Source } else { $script:LinuxDataPath }
            KiloLinkImage = if ($container.Config.Image) { [string]$container.Config.Image } else { $script:KiloImage }
        }
    } catch {
        Write-Warning "Could not import the existing KiloLink container settings: $($_.Exception.Message)"
        return $null
    }
}

function Read-SuiteConfig {
    param([switch]$UseSaved)
    $saved = if ($UseSaved) { Get-SavedConfig } else { $null }
    $preferredDistro = if ($saved) { [string](Get-PropertyValue $saved 'DistroName' 'Ubuntu') } else { 'Ubuntu' }
    $distro = Get-UbuntuDistro $preferredDistro
    if (-not $distro) { $distro = 'Ubuntu' }
    $legacy = if (-not $saved -and (Get-WslDistroNames) -contains $distro) { Get-LegacyKiloConfig $distro } else { $null }
    $adapter = Select-PrimaryLanAddress $saved
    $webDefault = if ($saved) { [int](Get-PropertyValue $saved 'WebPort' 80) } elseif ($legacy -and $legacy.WebPort) { [int]$legacy.WebPort } else { 80 }
    $linkDefault = if ($saved) { [int](Get-PropertyValue $saved 'LinkPort' 50000) } elseif ($legacy -and $legacy.LinkPort) { [int]$legacy.LinkPort } else { 50000 }
    $ndiDefault = if ($saved) { [int](Get-PropertyValue $saved 'NdiDiscoveryPort' 5959) } else { 5959 }
    if (-not $adapter.Dhcp) {
        Write-Host 'Warning: the chosen address was not assigned by DHCP. A DHCP reservation or stable static address is recommended.' -ForegroundColor Yellow
    }
    return [pscustomobject]@{
        SchemaVersion = 1
        PrimaryInterfaceAlias = $adapter.Alias
        PublicIp = $adapter.Address
        WebPort = Read-Port 'KiloLink web port' $webDefault
        LinkPort = Read-Port 'KiloLink link port' $linkDefault -EvenPair
        NdiDiscoveryPort = Read-Port 'NDI Discovery Server port' $ndiDefault
        DistroName = $distro
        LinuxDataPath = if ($saved) { [string](Get-PropertyValue $saved 'LinuxDataPath' $script:LinuxDataPath) } elseif ($legacy) { [string]$legacy.LinuxDataPath } else { $script:LinuxDataPath }
        KiloLinkImage = if ($saved) { [string](Get-PropertyValue $saved 'KiloLinkImage' $script:KiloImage) } elseif ($legacy) { [string]$legacy.KiloLinkImage } else { $script:KiloImage }
        UpdatedAt = (Get-Date).ToString('o')
    }
}

function Confirm-LicenseAcceptance {
    Write-Host ''
    Write-Host 'This downloads Kiloview and NDI software and performs unattended installation.' -ForegroundColor Yellow
    Write-Host 'You must accept the vendors license agreements to continue.' -ForegroundColor Yellow
    return (Read-Host 'Type YES to accept and continue') -ceq 'YES'
}

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
        if ($feature.State -ne 'Enabled') {
            Write-Host "Enabling $name"
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart
            if ($result.RestartNeeded) { $restart = $true }
        }
    }
    if ($restart) {
        Write-Host 'Restart Windows, rerun this script, then choose Repair / Reconfigure.' -ForegroundColor Yellow
        return $false
    }
    Invoke-Native wsl.exe @('--set-default-version', '2') -IgnoreExitCode
    Invoke-Native wsl.exe @('--update') -IgnoreExitCode
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
        Write-Step 'Installing Ubuntu under WSL 2'
        Invoke-Native wsl.exe @('--install', '--distribution', 'Ubuntu', '--no-launch')
        $distro = Get-UbuntuDistro 'Ubuntu'
        if (-not $distro) {
            Write-Host 'Ubuntu was requested but is not ready. Restart if prompted, then choose Repair / Reconfigure.' -ForegroundColor Yellow
            return $null
        }
    }
    $Config.DistroName = $distro
    Save-Config $Config
    Invoke-Native wsl.exe @('--set-version', $distro, '2') -IgnoreExitCode
    Invoke-Wsl $distro 'true'
    return $distro
}

function Ensure-Docker {
    param([string]$Distro)
    Write-Step 'Installing systemd, Docker Engine, and Avahi in Ubuntu'

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
mv /etc/wsl.conf.kilolink /etc/wsl.conf
'@
    Invoke-WslScript $Distro $enableSystemd
    Invoke-Native wsl.exe @('--shutdown') -IgnoreExitCode
    Start-Sleep -Seconds 2
    Invoke-Wsl $Distro 'true'

    $installDocker = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg avahi-daemon dbus iproute2 libnss-mdns

if ! command -v docker >/dev/null 2>&1; then
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
        Write-Host 'KiloLink Server Pro is already installed.' -ForegroundColor Green
        Invoke-Wsl $Config.DistroName "docker update --restart always '$script:ContainerName' >/dev/null; docker start '$script:ContainerName' >/dev/null || true"
        return
    }

    Write-Step 'Installing KiloLink Server Pro'
    $existsOutput = Invoke-Wsl $Config.DistroName "test -d '$($Config.LinuxDataPath)' && echo yes || echo no" -Capture
    $pathExists = (@($existsOutput | Select-Object -Last 1)[0]).Trim() -eq 'yes'
    $answers = New-Object Collections.Generic.List[string]
    $answers.Add('y')
    $answers.Add([string]$Config.LinuxDataPath)
    if ($pathExists) { $answers.Add('y') }
    $answers.Add([string]$Config.WebPort)
    $answers.Add([string]$Config.LinkPort)
    $answers.Add([string]$Config.PublicIp)
    $input = ($answers -join [Environment]::NewLine) + [Environment]::NewLine
    $answerBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($input))

    $template = @'
set -euo pipefail
export PAGER=cat
curl -fsSL "__INSTALL_URL__" -o /tmp/install-kilolink.sh
test -s /tmp/install-kilolink.sh
printf '%s' '__ANSWERS__' | base64 -d | bash /tmp/install-kilolink.sh
docker update --restart always "__CONTAINER__" >/dev/null
docker start "__CONTAINER__" >/dev/null || true
docker inspect "__CONTAINER__" >/dev/null
'@
    $content = $template.Replace('__INSTALL_URL__', $script:KiloInstallerUrl)
    $content = $content.Replace('__ANSWERS__', $answerBase64)
    $content = $content.Replace('__CONTAINER__', $script:ContainerName)
    Invoke-WslScript $Config.DistroName $content
    Write-Host 'KiloLink Server Pro installed.' -ForegroundColor Green
}

function Recreate-KiloContainer {
    param($Config, [switch]$Pull)
    $pullCommand = if ($Pull) { 'docker pull "__IMAGE__"' } else { 'docker image inspect "__IMAGE__" >/dev/null' }
    $template = @'
set -euo pipefail
__PULL_COMMAND__
docker rm -f "__CONTAINER__" >/dev/null 2>&1 || true
mkdir -p "__DATA_PATH__"
docker run -d --name "__CONTAINER__" --ulimit nofile=10000:10000 -e "web_port=__WEB__" -e "server_port=__LINK__" -e "stream_server_ip=__IP__" -e "stream_server_port=__LINK_PLUS_ONE__" -v /var/run/avahi-daemon:/var/run/avahi-daemon -v /var/run/dbus:/var/run/dbus -v "__DATA_PATH__":/data --restart=always --network host --privileged=true "__IMAGE__" /bin/bash /start_server.sh
docker inspect "__CONTAINER__" >/dev/null
'@
    $content = $template.Replace('__PULL_COMMAND__', $pullCommand)
    $content = $content.Replace('__CONTAINER__', $script:ContainerName)
    $content = $content.Replace('__DATA_PATH__', [string]$Config.LinuxDataPath)
    $content = $content.Replace('__WEB__', [string]$Config.WebPort)
    $content = $content.Replace('__LINK_PLUS_ONE__', [string]([int]$Config.LinkPort + 1))
    $content = $content.Replace('__LINK__', [string]$Config.LinkPort)
    $content = $content.Replace('__IP__', [string]$Config.PublicIp)
    $content = $content.Replace('__IMAGE__', [string]$Config.KiloLinkImage)
    Invoke-WslScript $Config.DistroName $content
}

function Sync-KiloConfig {
    param($Old, $New)
    if (-not (Test-KiloContainer $New.DistroName)) {
        Install-KiloLink $New
        return
    }
    $changed =
        ([string](Get-PropertyValue $Old 'PublicIp' '') -ne [string]$New.PublicIp) -or
        ([int](Get-PropertyValue $Old 'WebPort' 0) -ne [int]$New.WebPort) -or
        ([int](Get-PropertyValue $Old 'LinkPort' 0) -ne [int]$New.LinkPort)
    if ($changed) {
        Write-Step 'Applying the changed KiloLink network configuration'
        Recreate-KiloContainer $New
    } else {
        Invoke-Wsl $New.DistroName "docker update --restart always '$script:ContainerName' >/dev/null; docker start '$script:ContainerName' >/dev/null || true"
    }
}

function Convert-ToVersion {
    param([string]$Value)
    if (-not $Value) { return $null }
    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')
    if (-not $match.Success) { return $null }
    try { return [version]$match.Value } catch { return $null }
}

function Install-NdiTools {
    param([switch]$UpdateOnly)
    $registration = Get-NdiRegistration
    if ($UpdateOnly -and -not $registration) {
        Write-Host 'NDI Tools is missing. Choose Repair / Reconfigure to install it.' -ForegroundColor Yellow
        return
    }

    Write-Step 'Checking the current NDI Tools package'
    $downloadDir = Join-Path $env:TEMP 'KiloLinkSuite'
    $installer = Join-Path $downloadDir 'NDI-Tools.exe'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri $script:NdiToolsUrl -OutFile $installer

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
        throw "NDI installer signature validation failed: $($signature.Status)"
    }
    $installedVersion = if ($registration) { Convert-ToVersion ([string](Get-PropertyValue $registration 'DisplayVersion' '')) } else { $null }
    $packageVersion = Convert-ToVersion ((Get-Item -LiteralPath $installer).VersionInfo.ProductVersion)
    $install = -not $registration -or -not $installedVersion -or -not $packageVersion -or $packageVersion -gt $installedVersion
    if (-not $install) {
        Write-Host "NDI Tools $installedVersion is current." -ForegroundColor Green
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        return
    }

    $process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-') -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "NDI Tools installer failed with exit code $($process.ExitCode)."
    }
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if (-not (Get-NdiRegistration)) {
        throw 'NDI Tools finished installing but was not detected in Programs and Features.'
    }
    Write-Host 'NDI Tools installed or updated.' -ForegroundColor Green
}

function Configure-NdiServer {
    param($Config)
    Write-Step 'Configuring NDI Discovery Server on all physical adapters'
    $exe = Get-NdiDiscoveryExe
    if (-not $exe) {
        throw 'NDI Discovery Service.exe was not found in the NDI Tools installation.'
    }

    $ndiConfigDir = Join-Path $env:ProgramData 'NDI'
    New-Item -ItemType Directory -Path $ndiConfigDir -Force | Out-Null
    [pscustomobject]@{
        binding = '0.0.0.0'
        port_no = [string]$Config.NdiDiscoveryPort
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ndiConfigDir 'ndi-discovery-service.v1.json') -Encoding UTF8

    $service = Get-NdiDiscoveryService
    if (-not $service) {
        try {
            $process = Start-Process -FilePath $exe -ArgumentList @('install') -PassThru -WindowStyle Hidden
            if (-not $process.WaitForExit(15000)) { $process.Kill() }
        } catch {
            Write-Warning "NDI service registration was unavailable: $($_.Exception.Message)"
        }
        $service = Get-NdiDiscoveryService
    }

    if ($service) {
        Unregister-ScheduledTask -TaskName $script:NdiTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Set-Service -Name $service.Name -StartupType Automatic
        if ($service.Status -eq 'Running') {
            Restart-Service -Name $service.Name -Force
        } else {
            Start-Service -Name $service.Name
        }
        Write-Host "NDI Discovery Server is running as $($service.DisplayName)." -ForegroundColor Green
        return
    }

    $action = New-ScheduledTaskAction -Execute $exe -Argument "-bind 0.0.0.0 -port $($Config.NdiDiscoveryPort)"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT20S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:NdiTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $script:NdiTaskName
    Write-Host 'NDI Discovery Server startup task installed.' -ForegroundColor Green
}

function Install-FirewallRules {
    param($Config)
    Write-Step 'Opening the required Windows and WSL firewall ports'
    Get-NetFirewallRule -DisplayGroup $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $tcpPorts = @([string]$Config.WebPort, '30000-30300', '5960-7961')
    $udpPorts = @([string]$Config.LinkPort, [string]([int]$Config.LinkPort + 1), '30000-30300', '5353', '5960-7961')
    New-NetFirewallRule -DisplayName 'KiloLink Suite TCP' -DisplayGroup $script:FirewallGroup -Direction Inbound -Action Allow -Protocol TCP -LocalPort $tcpPorts | Out-Null
    New-NetFirewallRule -DisplayName 'KiloLink Suite UDP' -DisplayGroup $script:FirewallGroup -Direction Inbound -Action Allow -Protocol UDP -LocalPort $udpPorts | Out-Null
    New-NetFirewallRule -DisplayName 'NDI Discovery Server TCP' -DisplayGroup $script:FirewallGroup -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([string]$Config.NdiDiscoveryPort) | Out-Null
    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        foreach ($name in @("$($script:HyperVPrefix)TCP", "$($script:HyperVPrefix)UDP")) {
            Get-NetFirewallHyperVRule -Name $name -ErrorAction SilentlyContinue | Remove-NetFirewallHyperVRule
        }
        New-NetFirewallHyperVRule -Name "$($script:HyperVPrefix)TCP" -DisplayName 'KiloLink WSL TCP' -Direction Inbound -VMCreatorId $script:WslVmCreatorId -Protocol TCP -LocalPorts $tcpPorts -Action Allow | Out-Null
        New-NetFirewallHyperVRule -Name "$($script:HyperVPrefix)UDP" -DisplayName 'KiloLink WSL UDP' -Direction Inbound -VMCreatorId $script:WslVmCreatorId -Protocol UDP -LocalPorts $udpPorts -Action Allow | Out-Null
    } else {
        Write-Warning 'Hyper-V firewall cmdlets are unavailable. Install current Windows updates if LAN clients cannot reach KiloLink.'
    }
}

function Install-Shortcuts {
    param($Config)
    Write-Step 'Creating KiloLink browser shortcuts'
    $url = "http://$($Config.PublicIp):$($Config.WebPort)/"
    $nl = [Environment]::NewLine
    $content = (@('[InternetShortcut]', "URL=$url", "IconFile=$env:SystemRoot\System32\SHELL32.dll", 'IconIndex=14') -join $nl) + $nl
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $programs = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Kiloview'
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    New-Item -ItemType Directory -Path $programs -Force | Out-Null
    $content | Set-Content -LiteralPath (Join-Path $desktop 'KiloLink Server Pro.url') -Encoding ASCII
    $content | Set-Content -LiteralPath (Join-Path $programs 'KiloLink Server Pro.url') -Encoding ASCII
    Write-Host "Shortcut target: $url" -ForegroundColor Green
}

function Install-StartupTask {
    param($Config)
    Write-Step 'Installing the KiloLink startup and watchdog task'
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $template = @'
$ErrorActionPreference = 'Continue'
$Distro = '__DISTRO__'
$Container = '__CONTAINER__'
$LogPath = '__LOG__'
Start-Transcript -Path $LogPath -Append | Out-Null
Write-Host ('KiloLink watchdog ' + [DateTime]::Now.ToString('o'))
$linux = "systemctl start docker; systemctl start avahi-daemon; docker update --restart always '$Container' >/dev/null 2>&1 || true; docker start '$Container' >/dev/null 2>&1 || true; docker ps --filter name='$Container'"
& wsl.exe -d $Distro -u root -- bash -lc $linux
Stop-Transcript | Out-Null
'@
    $helper = $template.Replace('__DISTRO__', [string]$Config.DistroName)
    $helper = $helper.Replace('__CONTAINER__', $script:ContainerName)
    $helper = $helper.Replace('__LOG__', (Join-Path $script:StateRoot 'startup.log'))
    $helper | Set-Content -LiteralPath $script:StartupScriptPath -Encoding UTF8
    $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:StartupScriptPath + '"'
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument $taskArguments
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT30S'
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $logon.Delay = 'PT30S'
    $watchdog = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -StartWhenAvailable
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType S4U -RunLevel Highest
        Register-ScheduledTask -TaskName $script:StartupTaskName -Action $action -Trigger @($boot, $logon, $watchdog) -Principal $principal -Settings $settings -Force | Out-Null
    } catch {
        Write-Warning 'A boot-time S4U task was blocked. Installing logon and watchdog triggers instead.'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $script:StartupTaskName -Action $action -Trigger @($logon, $watchdog) -Principal $principal -Settings $settings -Force | Out-Null
    }
    Start-ScheduledTask -TaskName $script:StartupTaskName
}

function Test-SuiteHealth {
    param($Config)
    Write-Step 'Verifying installed components'
    $statusOutput = Invoke-Wsl $Config.DistroName "docker inspect -f '{{.State.Status}}' '$script:ContainerName'" -IgnoreExitCode -Capture
    $status = @($statusOutput | Select-Object -Last 1)[0]
    if ($status -ne 'running') {
        throw "KiloLink container state is '$status' instead of 'running'."
    }
    if (-not (Get-NdiDiscoveryService) -and -not (Get-ScheduledTask -TaskName $script:NdiTaskName -ErrorAction SilentlyContinue)) {
        throw 'NDI Discovery Server has no service or startup task.'
    }
    $url = "http://$($Config.PublicIp):$($Config.WebPort)/"
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -TimeoutSec 15
        Write-Host "KiloLink web response: HTTP $($response.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Warning "KiloLink is running, but the web check failed: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host 'Suite configuration is complete.' -ForegroundColor Green
    Write-Host "Primary adapter:       $($Config.PrimaryInterfaceAlias) / $($Config.PublicIp)"
    Write-Host 'Listening adapters:    all active physical adapters (0.0.0.0)'
    Write-Host "KiloLink web UI:       $url"
    Write-Host "KiloLink device link:  $($Config.PublicIp):$($Config.LinkPort)-$([int]$Config.LinkPort + 1) UDP"
    Write-Host "NDI Discovery Server:  $($Config.PublicIp):$($Config.NdiDiscoveryPort) TCP"
}

function Repair-Suite {
    $old = Get-SavedConfig
    $config = Read-SuiteConfig -UseSaved
    Save-Config $config
    if (-not (Confirm-LicenseAcceptance)) {
        Write-Host 'Operation cancelled.' -ForegroundColor Yellow
        return
    }
    if (-not (Ensure-WslFeatures)) { return }
    Ensure-MirroredNetworking
    $distro = Ensure-Ubuntu $config
    if (-not $distro) { return }
    Ensure-Docker $distro
    if ($old -and (Test-KiloContainer $distro)) {
        Sync-KiloConfig $old $config
    } else {
        Install-KiloLink $config
    }
    Install-NdiTools
    Configure-NdiServer $config
    Install-FirewallRules $config
    Install-Shortcuts $config
    Install-StartupTask $config
    Save-Config $config
    Test-SuiteHealth $config
}

function Update-KiloLink {
    param($Config)
    if (-not (Test-KiloContainer $Config.DistroName)) {
        Write-Host 'KiloLink is missing. Choose Repair / Reconfigure.' -ForegroundColor Yellow
        return
    }
    Write-Step 'Checking the current KiloLink image'
    $template = @'
set -euo pipefail
old_id=$(docker inspect -f '{{.Image}}' "__CONTAINER__")
docker pull "__IMAGE__"
new_id=$(docker image inspect -f '{{.Id}}' "__IMAGE__")
if [ "$old_id" = "$new_id" ]; then
    echo KILOLINK_CURRENT
else
    echo KILOLINK_UPDATE
fi
'@
    $content = $template.Replace('__CONTAINER__', $script:ContainerName).Replace('__IMAGE__', [string]$Config.KiloLinkImage)
    $output = Invoke-WslScript $Config.DistroName $content -Capture
    if ($output -contains 'KILOLINK_UPDATE') {
        Write-Host 'A newer image was found. Recreating the container while retaining its data.' -ForegroundColor Yellow
        Recreate-KiloContainer $Config
        Write-Host 'KiloLink updated.' -ForegroundColor Green
    } else {
        Write-Host 'KiloLink is current.' -ForegroundColor Green
    }
}

function Update-Suite {
    $config = Get-SavedConfig
    if (-not $config) {
        Write-Host 'No saved configuration exists. Choose Repair / Reconfigure.' -ForegroundColor Yellow
        return
    }
    if (-not (Ensure-WslFeatures)) { return }
    $distro = Get-UbuntuDistro ([string]$config.DistroName)
    if (-not $distro) {
        Write-Host 'Ubuntu is missing. Choose Repair / Reconfigure.' -ForegroundColor Yellow
        return
    }
    $config.DistroName = $distro
    Invoke-Wsl $distro 'systemctl start docker; systemctl start avahi-daemon'
    $oldConfig = ($config | ConvertTo-Json -Depth 5) | ConvertFrom-Json
    $currentAdapter = @(Get-LanCandidates | Where-Object {
        $_.Alias -eq $config.PrimaryInterfaceAlias -and $_.Dhcp
    } | Select-Object -First 1)[0]
    if ($currentAdapter -and $currentAdapter.Address -ne $config.PublicIp) {
        Write-Host "DHCP changed $($config.PrimaryInterfaceAlias) from $($config.PublicIp) to $($currentAdapter.Address)." -ForegroundColor Yellow
        $config.PublicIp = $currentAdapter.Address
        Sync-KiloConfig $oldConfig $config
    }
    Write-Step 'Updating Ubuntu and Docker packages'
    $linuxUpdate = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
systemctl enable --now docker
systemctl enable --now avahi-daemon
'@
    Invoke-WslScript $distro $linuxUpdate
    Update-KiloLink $config
    Install-NdiTools -UpdateOnly
    Configure-NdiServer $config
    Install-FirewallRules $config
    Install-Shortcuts $config
    Install-StartupTask $config
    Save-Config $config
    Test-SuiteHealth $config
}

function Invoke-UninstallCommand {
    param([string]$CommandLine)
    $exe = $null
    $arguments = ''
    if ($CommandLine -match '^\s*"([^"]+\.exe)"\s*(.*)$') {
        $exe = $matches[1]
        $arguments = $matches[2]
    } elseif ($CommandLine -match '^\s*([^\s]+\.exe)\s*(.*)$') {
        $exe = $matches[1]
        $arguments = $matches[2]
    }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        throw "Could not locate the NDI uninstaller from: $CommandLine"
    }
    if ($exe -match '(?i)msiexec\.exe$') {
        $arguments = $arguments -replace '(?i)(^|\s)/I(?=\s|\{)', '$1/X'
        $arguments += ' /qn /norestart'
    } else {
        $arguments += ' /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 1605, 3010)) {
        throw "NDI uninstaller failed with exit code $($process.ExitCode)."
    }
}

function Remove-LegacyPortProxies {
    param($Config)
    if (-not $Config) { return }
    $address = [string](Get-PropertyValue $Config 'PublicIp' '')
    $web = [int](Get-PropertyValue $Config 'WebPort' 0)
    $link = [int](Get-PropertyValue $Config 'LinkPort' 0)
    if (-not $address) { return }
    $ports = New-Object Collections.Generic.List[int]
    if ($web -gt 0) { $ports.Add($web) }
    if ($link -gt 0) {
        $ports.Add($link)
        $ports.Add($link + 1)
    }
    foreach ($port in $ports) {
        & netsh.exe interface portproxy delete v4tov4 "listenaddress=$address" "listenport=$port" 2>$null | Out-Null
    }
}

function Uninstall-Suite {
    Write-Heading 'Uninstall KiloLink Suite'
    Write-Host 'This removes KiloLink and its persisted data, NDI Tools/Discovery Server,' -ForegroundColor Yellow
    Write-Host 'scheduled tasks, installer firewall rules, and browser shortcuts.' -ForegroundColor Yellow
    Write-Host 'WSL, Ubuntu, and the shared .wslconfig file will be retained.' -ForegroundColor Yellow
    if ((Read-Host 'Type UNINSTALL to continue') -cne 'UNINSTALL') {
        Write-Host 'Uninstall cancelled.' -ForegroundColor Yellow
        return
    }

    $config = Get-SavedConfig
    $preferred = if ($config) { [string](Get-PropertyValue $config 'DistroName' '') } else { '' }
    $distro = Get-UbuntuDistro $preferred
    Unregister-ScheduledTask -TaskName $script:StartupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:NdiTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $ndiService = Get-NdiDiscoveryService
    if ($ndiService) {
        Stop-Service -Name $ndiService.Name -Force -ErrorAction SilentlyContinue
    }

    if ($distro -and (Test-KiloContainer $distro)) {
        Write-Step 'Removing KiloLink container and data'
        $inspectLines = Invoke-Wsl $distro "docker inspect '$script:ContainerName'" -Capture
        $inspection = ($inspectLines -join [Environment]::NewLine) | ConvertFrom-Json
        $container = @($inspection)[0]
        $mount = @($container.Mounts | Where-Object { $_.Destination -eq '/data' } | Select-Object -First 1)[0]
        $dataPath = if ($mount) { [string]$mount.Source } else { '' }
        Invoke-Wsl $distro "docker rm -f '$script:ContainerName' >/dev/null"
        if ($dataPath -match '^/(?:opt|root|home/[^/]+)/kilolink-server/?$') {
            Invoke-Wsl $distro "rm -rf -- '$dataPath'"
        } elseif ($dataPath) {
            Write-Warning "Data was retained because its path was outside the expected safe locations: $dataPath"
        }
    }

    $ndi = Get-NdiRegistration
    if ($ndi) {
        Write-Step 'Uninstalling NDI Tools and Discovery Server'
        $command = [string](Get-PropertyValue $ndi 'QuietUninstallString' '')
        if (-not $command) { $command = [string](Get-PropertyValue $ndi 'UninstallString' '') }
        if ($command) {
            Invoke-UninstallCommand $command
        } else {
            Write-Warning 'NDI Tools is installed, but its uninstaller entry is missing.'
        }
    }

    Write-Step 'Removing firewall rules and shortcuts'
    Get-NetFirewallRule -DisplayGroup $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$($script:HyperVPrefix)*" } | Remove-NetFirewallHyperVRule
    }
    Remove-LegacyPortProxies $config
    $desktop = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'KiloLink Server Pro.url'
    $programs = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Kiloview'
    Remove-Item -LiteralPath $desktop -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $programs 'KiloLink Server Pro.url') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $programs) {
        if (@(Get-ChildItem -LiteralPath $programs -Force).Count -eq 0) {
            Remove-Item -LiteralPath $programs -Force
        }
    }
    Remove-Item -LiteralPath $script:StateRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Uninstall complete. WSL and Ubuntu were retained.' -ForegroundColor Green
}

function Show-State {
    param($State)
    Write-Host ("KiloLink Server Pro:  " + $(if ($State.KiloLink) { 'Installed' } else { 'Not detected' }))
    Write-Host ("NDI Tools:            " + $(if ($State.NDITools) { 'Installed' } else { 'Not detected' }))
    Write-Host ("NDI Discovery Server: " + $(if ($State.NDIServer) { 'Configured' } else { 'Not detected' }))
    Write-Host ("Ubuntu WSL:           " + $(if ($State.Distro) { $State.Distro } else { 'Not detected' }))
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Heading 'KiloLink Server Pro + NDI deployment for Windows 11'
        $state = Get-InstallState
        Show-State $state
        if ($state.Any) {
            Write-Host ''
            Write-Host 'A previous or partial installation was detected.' -ForegroundColor Green
            Write-Host '  1. Check for and install updates'
            Write-Host '  2. Repair / reconfigure'
            Write-Host '  3. Uninstall'
            Write-Host '  4. Exit'
            $choice = Read-Host 'Choose an option'
            try {
                switch ($choice) {
                    '1' { Update-Suite }
                    '2' { Repair-Suite }
                    '3' { Uninstall-Suite }
                    '4' { return }
                    default { Write-Host 'Invalid selection.' -ForegroundColor Red }
                }
            } catch {
                Write-Host "Operation failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "State and logs are under $script:StateRoot" -ForegroundColor Yellow
            }
        } else {
            Write-Host ''
            Write-Host '  1. Install KiloLink Server Pro, NDI Tools, and NDI Discovery Server'
            Write-Host '  2. Exit'
            $choice = Read-Host 'Choose an option'
            try {
                switch ($choice) {
                    '1' { Repair-Suite }
                    '2' { return }
                    default { Write-Host 'Invalid selection.' -ForegroundColor Red }
                }
            } catch {
                Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host 'Rerun the script and choose Repair / Reconfigure after correcting the problem.' -ForegroundColor Yellow
            }
        }
        Write-Host ''
        Read-Host 'Press Enter to return to the menu' | Out-Null
    }
}

Ensure-Administrator
Show-Menu
