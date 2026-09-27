function Install-FirewallRules {
    param($Config)
    Write-Step 'Opening the required Windows and WSL firewall ports'
    Get-NetFirewallRule -Group $script:FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $tcpPorts = @([string]$Config.WebPort, '30000-30300', '5960-10000')
    $udpPorts = @([string]$Config.LinkPort, [string]([int]$Config.LinkPort + 1), '30000-30300', '5353', '5960-10000')
    New-NetFirewallRule -DisplayName 'KiloLink Suite TCP' -Group $script:FirewallGroup -Direction Inbound -Action Allow -Protocol TCP -LocalPort $tcpPorts -Profile Domain,Private -RemoteAddress LocalSubnet -LocalAddress $Config.PublicIp -EdgeTraversalPolicy Block | Out-Null
    New-NetFirewallRule -DisplayName 'KiloLink Suite UDP' -Group $script:FirewallGroup -Direction Inbound -Action Allow -Protocol UDP -LocalPort $udpPorts -Profile Domain,Private -RemoteAddress LocalSubnet -EdgeTraversalPolicy Block | Out-Null
    New-NetFirewallRule -DisplayName 'NDI Discovery Server TCP' -Group $script:FirewallGroup -Direction Inbound -Action Allow -Protocol TCP -LocalPort ([string]$Config.NdiDiscoveryPort) -Profile Domain,Private -RemoteAddress LocalSubnet -LocalAddress $Config.PublicIp -EdgeTraversalPolicy Block | Out-Null
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
    # Keep local shortcuts stable when DHCP or adapter configuration changes.
    $url = "http://127.0.0.1:$($Config.WebPort)/"
    $nl = [Environment]::NewLine
    $content = (@('[InternetShortcut]', "URL=$url", "IconFile=$env:SystemRoot\System32\SHELL32.dll", 'IconIndex=14') -join $nl) + $nl
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $programs = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Kiloview'
    New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    New-Item -ItemType Directory -Path $programs -Force | Out-Null
    $content | Set-Content -LiteralPath (Join-Path $desktop 'KiloLink Server Pro.url') -Encoding ASCII
    $content | Set-Content -LiteralPath (Join-Path $programs 'KiloLink Server Pro.url') -Encoding ASCII
    Write-Detail "Shortcut target: $url" Green
}

function Stop-ManagedTask {
    param([string]$TaskName, [int]$TimeoutSeconds = 20)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task -or $task.State -ne 'Running') { return }
    Stop-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if (-not $task -or $task.State -ne 'Running') { return }
        Wait-SuiteProgressInterval -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "The scheduled task '$TaskName' did not stop. Its configuration has not been replaced."
}

function Get-KiloWatchdogCommand {
    $linux = @'
set -euo pipefail
while true; do
    mkdir -p /var/lib/kilolink
    exec 9>/var/lib/kilolink/maintenance.lock
    flock -x 9
    test ! -e /var/lib/kilolink/recovery-required || { echo 'KiloLink needs recovery; automatic startup stopped.' >&2; exit 30; }
    systemctl start docker
    systemctl start avahi-daemon
    docker update --restart always '__CONTAINER__' >/dev/null
    docker start '__CONTAINER__' >/dev/null
    docker inspect -f '{{.State.Running}}' '__CONTAINER__' | grep -qx true
    flock -u 9
    sleep 30
done
'@
    return $linux.Replace('__CONTAINER__', $script:ContainerName).Replace("`r`n", "`n").Replace("`r", "`n")
}

function Install-StartupTask {
    param($Config)
    Write-Step 'Installing the KiloLink startup and watchdog task'
    Stop-ManagedTask $script:StartupTaskName
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $template = @'
$ErrorActionPreference = 'Continue'
$Distro = '__DISTRO__'
$LogPath = '__LOG__'
Start-Transcript -Path $LogPath -Append | Out-Null
Write-Host ('KiloLink watchdog ' + [DateTime]::Now.ToString('o'))
$linux = '__LINUX_BASE64__'
$code = 1
try {
    & wsl.exe -d $Distro -u root --cd / -- bash -lc "printf '%s' '$linux' | base64 -d | bash"
    $code = $LASTEXITCODE
} finally {
    Stop-Transcript | Out-Null
}
exit $code
'@
    $helper = $template.Replace('__DISTRO__', ([string]$Config.DistroName).Replace("'", "''"))
    $linuxBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-KiloWatchdogCommand)))
    $helper = $helper.Replace('__LINUX_BASE64__', $linuxBase64)
    $helper = $helper.Replace('__LOG__', (Join-Path $script:StateRoot 'startup.log').Replace("'", "''"))
    $helper | Set-Content -LiteralPath $script:StartupScriptPath -Encoding UTF8
    $taskArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script:StartupScriptPath + '"'
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument $taskArguments
    $boot = New-ScheduledTaskTrigger -AtStartup
    $boot.Delay = 'PT30S'
    $logon = New-ScheduledTaskTrigger -AtLogOn
    $logon.Delay = 'PT30S'
    $watchdog = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
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

function Test-NdiServerReady {
    param($Config)
    $service = Get-NdiDiscoveryService
    $serviceProcessId = 0
    if ($service) {
        if ($service.Status -ne 'Running') { return $false }
        $serviceInfo = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $service.Name.Replace("'", "''"))
        if (-not $serviceInfo) { return $false }
        $serviceProcessId = [int]$serviceInfo.ProcessId
        if ($serviceProcessId -le 0) { return $false }
    } else {
        $task = Get-ScheduledTask -TaskName $script:NdiTaskName -ErrorAction SilentlyContinue
        if (-not $task -or $task.State -ne 'Running') { return $false }
    }
    $exe = Get-NdiDiscoveryExe
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Config.NdiDiscoveryPort -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        if ($listener.LocalAddress -notin @('0.0.0.0', '::')) { continue }
        if ($service) {
            if ([int]$listener.OwningProcess -eq $serviceProcessId) { return $true }
        } else {
            $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($exe -and $process -and [string]::Equals($process.Path, $exe, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Get-SuiteNetworkAccessIssue {
    param($Config)
    $alias = [string](Get-PropertyValue $Config 'PrimaryInterfaceAlias' '')
    if (-not $alias) { return 'Select a server network adapter before checking LAN access.' }
    try { $profiles = @(Get-NetConnectionProfile -InterfaceAlias $alias -ErrorAction Stop) }
    catch { return "Could not read the Windows network profile for '$alias'. Check Windows Network settings before continuing. $($_.Exception.Message)" }
    if ($profiles.Count -eq 0) { return "No active Windows network profile was found for '$alias'. Connect the selected server adapter and retry." }
    if (@($profiles | Where-Object { [string]$_.NetworkCategory -eq 'Public' }).Count -gt 0) {
        return "Windows marks '$alias' as a Public network. The suite's firewall rules allow Domain/Private networks, so LAN access is not ready. If this is a trusted home/office network, change its network profile to Private in Windows Settings and retry. Otherwise select a trusted server network. No firewall protection was disabled."
    }
    if (@($profiles | Where-Object { [string]$_.NetworkCategory -notin @('Private','DomainAuthenticated') }).Count -gt 0) {
        return "The Windows network profile for '$alias' could not be verified as Private or Domain authenticated."
    }
    return $null
}

function Test-SuiteHealth {
    param($Config, [int]$TimeoutSeconds = 120)
    Write-Step 'Verifying installed components and waiting for service readiness'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    # Host-to-WSL readiness uses localhost. A request from this host to its own
    # mirrored LAN address is not a reliable test of another device's LAN path.
    $url = "http://127.0.0.1:$($Config.WebPort)/"
    $lanUrl = "http://$($Config.PublicIp):$($Config.WebPort)/"
    Write-LauncherEvent -Type 'summary' -Data @{
        webUrl = $url; lanWebUrl = $lanUrl; lanVerification = 'Requires another device'
        ndiEndpoint = "$($Config.PublicIp):$($Config.NdiDiscoveryPort)"
        linkEndpoint = "$($Config.PublicIp):$($Config.LinkPort)-$([int]$Config.LinkPort + 1) UDP"
    }
    do {
        $failures = New-Object Collections.Generic.List[string]
        $startupTask = Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
        if (-not $startupTask -or $startupTask.State -ne 'Running') {
            $failures.Add('The KiloLink WSL watchdog is not running.')
        }
        try {
            $statusOutput = @(Invoke-Wsl $Config.DistroName "docker inspect -f '{{.State.Status}}' '$script:ContainerName'" -Capture)
            $status = [string]($statusOutput | Select-Object -Last 1)
            if ($status -ne 'running') { $failures.Add("KiloLink container state is '$status'.") }
        } catch { $failures.Add("Could not check KiloLink: $($_.Exception.Message)") }
        try {
            if (-not (Test-NdiServerReady $Config)) {
                $failures.Add("NDI Discovery Server is not running and listening on TCP port $($Config.NdiDiscoveryPort).")
            }
        } catch { $failures.Add("Could not check NDI Discovery Server: $($_.Exception.Message)") }
        try {
            $remainingSeconds = [Math]::Max(1, [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds))
            $response = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Get -TimeoutSec ([Math]::Min(5, $remainingSeconds))
            if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 400) {
                throw "HTTP $($response.StatusCode)"
            }
        } catch { $failures.Add("KiloLink web check failed at ${url}: $($_.Exception.Message)") }
        if ($failures.Count -eq 0) {
            $networkIssue = Get-SuiteNetworkAccessIssue $Config
            if ($networkIssue) { throw "KiloLink responds locally at $url and NDI Discovery is listening. $networkIssue" }
            Write-Detail "KiloLink web response: HTTP $($response.StatusCode); NDI Discovery Server is listening." Green
            Write-Detail "Check LAN access from another device at $lanUrl. Local readiness does not verify the external network path." Yellow
            return
        }
        if ((Get-Date) -ge $deadline) { break }
        Wait-SuiteProgressInterval -Milliseconds 2000
    } while ($true)
    throw ("Service readiness checks failed after $TimeoutSeconds seconds. " + ($failures -join ' '))
}

function Show-SuiteSummary {
    param($Config, [string]$Heading = 'Suite configuration is complete')
    $url = "http://$($Config.PublicIp):$($Config.WebPort)/"
    Write-Host ''
    Write-Heading $Heading
    Write-Host "Primary adapter:       $($Config.PrimaryInterfaceAlias) / $($Config.PublicIp)"
    Write-Host 'Listening adapters:    all active physical adapters (0.0.0.0)'
    Write-Host ''
    Write-Host 'Installed products and access details' -ForegroundColor Green
    Write-Host "KiloLink on this PC:   http://127.0.0.1:$($Config.WebPort)/"
    Write-Host "KiloLink LAN address:  $url (verify from another device)"
    Write-Host "  Default username:    $($script:KiloDefaultUsername)"
    Write-Host "  Default password:    $($script:KiloDefaultPassword)"
    Write-Host '  Change this password immediately after the first login.' -ForegroundColor Yellow
    Write-Host '  Existing installations retain their previously configured password.' -ForegroundColor DarkGray
    Write-Host 'NDI Tools:             Installed Windows applications (no web interface)'
    Write-Host "NDI Discovery Server:  tcp://$($Config.PublicIp):$($Config.NdiDiscoveryPort) (no web interface or login)"
    Write-Host "KiloLink device link:  $($Config.PublicIp):$($Config.LinkPort)-$([int]$Config.LinkPort + 1) UDP"
    Write-Host ''
    Write-Host "Detailed install log:  $($script:InstallerLogPath)" -ForegroundColor DarkGray
}
