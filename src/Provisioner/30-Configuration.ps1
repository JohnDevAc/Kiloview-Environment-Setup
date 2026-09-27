function Get-NdiRegistration {
    param([switch]$All)
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
    }
    $registrations = @($items | Where-Object {
        $name = [string](Get-PropertyValue $_ 'DisplayName' '')
        $publisher = [string](Get-PropertyValue $_ 'Publisher' '')
        $name -match '^NDI\s+\d+\s+Tools' -or ($name -match 'NDI.*Tools' -and $publisher -match 'NDI|Vizrt|NewTek')
    })
    if ($All) { return $registrations }
    return @($registrations | Select-Object -First 1)[0]
}

function Get-NdiToolsRoots {
    $candidates = New-Object Collections.Generic.List[string]
    foreach ($registration in @(Get-NdiRegistration -All)) {
        $location = [string](Get-PropertyValue $registration 'InstallLocation' '')
        if (-not [string]::IsNullOrWhiteSpace($location)) { $candidates.Add($location) }
    }
    # Older registrations can omit InstallLocation; a registered Discovery service
    # can still identify a custom Tools root. Never execute its command line.
    $service = Get-NdiDiscoveryService
    if ($service) {
        $nativeService = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object Name -eq $service.Name | Select-Object -First 1)
        if ($nativeService.Count) {
            $command = [Environment]::ExpandEnvironmentVariables([string]$nativeService[0].PathName)
            if ($command -match '^\s*(?:"(?<exe>[A-Za-z]:\\[^"]+\.exe)"|(?<exe>[A-Za-z]:\\.+?\.exe))(?:\s|$)') {
                $exe = $Matches['exe']
                if ([IO.Path]::GetFileName($exe) -ieq 'NDI Discovery Service.exe') {
                    $directory = [IO.Path]::GetDirectoryName($exe)
                    if ([IO.Path]::GetFileName($directory) -in @('Discovery','Discovery Service')) { $directory = [IO.Path]::GetDirectoryName($directory) }
                    $candidates.Add($directory)
                }
            }
        }
    }
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Select-Object -Unique) {
        if (-not $programRoot) { continue }
        $ndiRoot = Join-Path $programRoot 'NDI'
        if (Test-Path -LiteralPath $ndiRoot -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $ndiRoot -Directory -Filter 'NDI * Tools' -ErrorAction Stop)) { $candidates.Add($directory.FullName) }
        }
    }
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"'))
        if ($expanded -notmatch '^[A-Za-z]:[\\/]') { throw "Invalid NDI Tools installation location: $candidate" }
        $path = [IO.Path]::GetFullPath($expanded).TrimEnd('\','/')
        $broadRoots = @([IO.Path]::GetPathRoot($path), $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:WINDIR, $env:USERPROFILE)
        if (@($broadRoots | Where-Object { $_ -and $_.TrimEnd('\','/') -ieq $path }).Count) { throw "NDI Tools installation location is too broad to inspect: $candidate" }
        if (-not $seen.Add($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        if ((Get-Item -LiteralPath $path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "NDI Tools installation location is a link: $path" }
        $path
    }
}

function Get-NdiToolsFiles {
    # Do not recurse through links into unrelated directories, even when a
    # registered custom root contains a junction. Both consumers use this walk.
    foreach ($root in @(Get-NdiToolsRoots)) {
        $pending = New-Object 'Collections.Generic.Stack[string]'
        $pending.Push($root)
        while ($pending.Count) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
                else { $entry }
            }
        }
    }
}

function Get-NdiDiscoveryExe {
    $found = Get-NdiToolsFiles | Where-Object Name -eq 'NDI Discovery Service.exe' | Select-Object -First 1
    if ($found) { return $found.FullName }
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
    param(
        $Saved,
        [string]$PreferredAlias,
        [string]$PreferredAddress
    )
    $candidates = @(Get-LanCandidates)
    if ($candidates.Count -eq 0) {
        throw 'No physical Ethernet or Wi-Fi IPv4 address was detected. Connect the PC to the network and retry.'
    }
    $savedAlias = if ($Saved) { [string](Get-PropertyValue $Saved 'PrimaryInterfaceAlias' '') } else { '' }
    $defaultIndex = 0
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $preferredAliasMatches = $PreferredAlias -and
            $candidates[$i].Alias -eq $PreferredAlias
        $preferredAddressMatches = -not $PreferredAddress -or
            $candidates[$i].Address -eq $PreferredAddress
        if ($preferredAliasMatches -and $preferredAddressMatches) {
            Write-Host "Using the adapter selected in the launcher: $($candidates[$i].Alias) / $($candidates[$i].Address)" -ForegroundColor Cyan
            return $candidates[$i]
        }
        if ($savedAlias -and $candidates[$i].Alias -eq $savedAlias) {
            $defaultIndex = $i
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
        $answer = Read-InstallerInput "Primary advertised adapter [$($defaultIndex + 1)]"
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

function Sync-PrimaryLanAddress {
    param($Config)
    $alias = if ($PreferredInterfaceAlias) { $PreferredInterfaceAlias } else { $Config.PrimaryInterfaceAlias }
    $candidates = @(Get-LanCandidates | Where-Object { $_.Alias -eq $alias })
    if ($candidates.Count -eq 0) {
        throw "The selected adapter '$alias' has no usable IPv4 address. Connect it or choose Repair / reconfigure."
    }
    $address = if ($PreferredInterfaceAlias -and $PreferredIpAddress) { $PreferredIpAddress } else { $Config.PublicIp }
    $matching = @($candidates | Where-Object { $_.Address -eq $address })
    if ($matching.Count -gt 0) {
        $adapter = $matching[0]
    } elseif ($PreferredInterfaceAlias -and $PreferredIpAddress) {
        throw "The address selected in the launcher ($PreferredIpAddress) is no longer available on '$alias'. Refresh the launcher and retry."
    } elseif ($candidates.Count -eq 1) {
        $adapter = $candidates[0]
    } else {
        throw "The saved address is no longer available on '$alias', which has multiple IPv4 addresses. Choose Repair / reconfigure to select one."
    }
    if ($Config.PublicIp -ne $adapter.Address -or $Config.PrimaryInterfaceAlias -ne $adapter.Alias) {
        Write-Detail "Using current server address $($adapter.Alias) / $($adapter.Address)." Yellow
        $Config.PublicIp = $adapter.Address
        $Config.PrimaryInterfaceAlias = $adapter.Alias
    }
}

function Read-Port {
    param([string]$Prompt, [int]$Default, [switch]$EvenPair)
    while ($true) {
        $answer = Read-InstallerInput "$Prompt [$Default]"
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
            KiloLinkImage = Get-PropertyValue (Get-PropertyValue $container.Config 'Labels' $null) 'org.kiloview.source-image' ([string]$container.Config.Image)
        }
    } catch {
        Write-Warning "Could not import the existing KiloLink container settings: $($_.Exception.Message)"
        return $null
    }
}

function Read-SuiteConfig {
    param([switch]$UseSaved)
    $saved = if ($UseSaved) { Get-SavedConfig } else { $null }
    $savedDistro = if ($saved) { [string](Get-PropertyValue $saved 'DistroName' '') } else { '' }
    $savedDistroHasKiloLink = $savedDistro -and
        ((Get-WslDistroNames) -contains $savedDistro) -and
        (Test-KiloContainer $savedDistro)
    $preferredDistro = if ($savedDistroHasKiloLink) { $savedDistro } else { $script:ManagedDistroName }
    if ($savedDistro -and $savedDistro -ne $preferredDistro) {
        Write-Host "Using dedicated WSL distribution '$($script:ManagedDistroName)'; '$savedDistro' will not be modified." -ForegroundColor Yellow
    }
    $distro = Get-UbuntuDistro $preferredDistro
    if (-not $distro) { $distro = $preferredDistro }
    $legacy = if (-not $saved -and (Get-WslDistroNames) -contains $distro) { Get-LegacyKiloConfig $distro } else { $null }
    $adapter = Select-PrimaryLanAddress `
        -Saved $saved `
        -PreferredAlias $PreferredInterfaceAlias `
        -PreferredAddress $PreferredIpAddress
    $webDefault = if ($saved) { [int](Get-PropertyValue $saved 'WebPort' 80) } elseif ($legacy -and $legacy.WebPort) { [int]$legacy.WebPort } else { 80 }
    $linkDefault = if ($saved) { [int](Get-PropertyValue $saved 'LinkPort' 50000) } elseif ($legacy -and $legacy.LinkPort) { [int]$legacy.LinkPort } else { 50000 }
    $ndiDefault = if ($saved) { [int](Get-PropertyValue $saved 'NdiDiscoveryPort' 5959) } else { 5959 }
    if ($adapter.Dhcp) {
        Write-Host 'Warning: this server is using DHCP. Configure a DHCP reservation or rerun the launcher to set a static address.' -ForegroundColor Yellow
    } else {
        Write-Host 'Using a stable static/manual IPv4 address for this server.' -ForegroundColor Green
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
    Write-Host "Kiloview's current licence is published in its official installer: $($script:KiloInstallerUrl)" -ForegroundColor Yellow
    Write-Host 'You must accept the vendors license agreements to continue.' -ForegroundColor Yellow
    return (Read-InstallerInput 'Type YES to accept and continue') -ieq 'YES'
}
