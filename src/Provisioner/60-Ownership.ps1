function Get-InteractiveUserSid {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $owners = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $session } | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0 -or -not $owner.Sid) { throw 'The desktop owner could not be verified.' }
        $owner.Sid
    } | Select-Object -Unique)
    if ($owners.Count -gt 1) { throw 'Multiple desktop owners were found; sign into the intended account before setup.' }
    if ($owners.Count -eq 1) { return $owners[0] }
    return $current
}

function Get-CurrentUserSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Get-ServerOwnerSid {
    $path = Join-Path $script:StateRoot 'installation-components.json'
    $serverSelected = $false
    if (Test-Path -LiteralPath $path) {
        $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($receipt.schemaVersion -ne 1) { throw 'The installation ownership receipt has an unsupported schema.' }
        $serverSelected = @($receipt.roles) -contains 'server'
        $owner = [string](Get-PropertyValue $receipt 'serverOwnerSid' '')
        if ($serverSelected -and $owner) {
            if ($owner -notmatch '^S-1-\d+(?:-\d+)+$') { throw 'The recorded server owner SID is invalid.' }
            return $owner
        }
    }
    # Migrate a legacy installation from its OS-owned startup task.
    $task = Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue
    if ($task) {
        $owner = [string]$task.Principal.UserId
        if ($owner -notmatch '^S-1-') {
            $owner = ([Security.Principal.NTAccount]::new($owner)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        return $owner
    }
    if ($serverSelected -or (Test-Path -LiteralPath $script:ConfigPath)) {
        throw 'Existing server ownership cannot be verified. Restore its original startup task or ownership receipt before server maintenance.'
    }
    return $null
}

function Assert-ServerOwner {
    $current = Get-CurrentUserSid
    if ((Get-InteractiveUserSid) -ne $current) {
        throw 'Server setup must run from the signed-in administrator desktop because WSL and startup belong to that account. Sign into the intended server administrator account and retry. Client PCs can use remote server components.'
    }
    $owner = Get-ServerOwnerSid
    if ($owner -and $owner -ne $current) {
        throw "This server installation belongs to Windows account $owner. Sign into that account before repairing, updating or removing its server components."
    }
}

function Assert-ServerDownloads($Config, [switch]$SourcesOnly) {
    Assert-ServerOwner
    Assert-NoPendingKiloRecovery
    Assert-SuitePorts $Config
    if (-not $SourcesOnly) {
        $networkIssue = Get-SuiteNetworkAccessIssue $Config
        if ($networkIssue) { throw $networkIssue }
    }
    Set-SuiteProgress -Percent 2 -Status 'Checking required server package sources'
    # An existing healthy local runtime does not need an online currency check during repair.
    if ($Action -in @('Setup','MaintainRuntime') -or -not (Test-WslRuntime)) {
        try {
            $wslRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/WSL/releases/latest' -TimeoutSec 12 -Headers @{'User-Agent'='Kiloview-Environment-Setup'}
            $wslAsset = @($wslRelease.assets | Where-Object { $_.name -match '\.x64\.msi$' }) | Select-Object -First 1
            if (-not $wslAsset) { throw 'The WSL runtime package could not be resolved.' }
            Assert-PackageSource $wslAsset.browser_download_url
        } catch { throw "Windows/WSL prerequisites cannot be downloaded. Check internet access and retry before changing Windows features. $($_.Exception.Message)" }
    }
    if ($SourcesOnly) {
        if (-not (Get-NdiRegistration) -or -not (Get-NdiDiscoveryExe)) { Assert-PackageSource $script:NdiToolsUrl }
    } else { Install-NdiTools -PrepareOnly -EnsureLatest:($Action -eq 'Setup') }
    if (-not (Get-UbuntuDistro ([string]$Config.DistroName))) {
        try {
            $catalog = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json' -TimeoutSec 12
            $ubuntu = @($catalog.ModernDistributions.Ubuntu | Where-Object { $_.Name -eq $script:ApplicationManifest.runtime.ubuntuDistribution }) | Select-Object -First 1
            if (-not $ubuntu -or ([uri]$ubuntu.Amd64Url.Url).Scheme -ne 'https') { throw 'The Ubuntu download could not be resolved.' }
            Assert-PackageSource $ubuntu.Amd64Url.Url
        } catch { throw "Ubuntu cannot be downloaded. Check its required source before changing Windows features. $($_.Exception.Message)" }
    }
}

function Assert-LinuxDownloads([string]$Distro) {
    # Run inside the same distribution/network context used by apt and Docker.
    $probe = @'
set -eu
if command -v curl >/dev/null; then
  curl --connect-timeout 8 --max-time 15 -fsSI https://download.docker.com/linux/ubuntu/gpg >/dev/null
  code=$(curl --connect-timeout 8 --max-time 15 -sS -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/)
  test "$code" = 200 || test "$code" = 401
fi
# Only refresh package metadata here; never install or upgrade as a probe.
timeout 60 apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=12 -o Acquire::https::Timeout=12 update --error-on=any >/dev/null
'@
    try { Invoke-WslScript $Distro $probe }
    catch { throw "Required Linux package sources are unavailable inside WSL. Windows internet access alone is insufficient. Existing application services were retained; retry when sources are reachable. $($_.Exception.Message)" }
}

function Save-ComponentReceipt([string]$Role, [switch]$Remove) {
    $path = Join-Path $script:StateRoot 'installation-components.json'
    $roles = @()
    $owner = $null
    if (Test-Path -LiteralPath $path) {
        $previous = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($previous.schemaVersion -ne 1) { throw 'Unsupported component receipt. Existing deployment ownership was preserved.' }
        if (@($previous.roles | Where-Object { $_ -notin @('client', 'server') }).Count -gt 0) {
            throw 'Unknown component role. Existing deployment ownership was preserved.'
        }
        $roles = @($previous.roles)
        $owner = Get-PropertyValue $previous 'serverOwnerSid' $null
    }
    if ($Role -eq 'server' -and -not $Remove) { Assert-ServerOwner; $owner = Get-CurrentUserSid }
    if ($Role -eq 'server' -and $Remove) { $owner = $null }
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $selected = if ($Remove) { @($roles | Where-Object { $_ -ne $Role }) } else { @(($roles + $Role) | Select-Object -Unique) }
    $receipt = @{schemaVersion=1; roles=@($selected); serverOwnerSid=$owner; updatedUtc=[datetime]::UtcNow.ToString('o')}
    $receipt | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath ($path + '.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
}

function Assert-SuitePorts($Config) {
    if ([int]$Config.NdiDiscoveryPort -ne 5959) { throw 'Suite clients require NDI Discovery on TCP 5959. Custom Discovery ports are not supported by the PC/device contract.' }
    if ([int]$Config.WebPort -in @(8080, 8091, 8094)) { throw 'TCP 8080, 8091 and 8094 are reserved for Arena, Job Configurator and PC Agent. Choose another KiloLink web port.' }
}

function Install-ClientTools {
    if (-not $AcceptLicenses) { throw 'Review and accept the NDI Tools licence before installing client tools.' }
    Set-OperationOutcome 'Running' 'Installing NDI Tools and PC Agent for this client.'
    Start-DeploymentJournal 'InstallClient' $null
    Start-SuiteProgress -Activity 'Installing client tools' -Status 'Checking the current official download'
    $ndiInstalled = $false
    try {
        Invoke-DeploymentStep 'Verify and stage client packages' { Prepare-ClientPackages }
        Save-ComponentReceipt 'client'
        Invoke-DeploymentStep 'NDI Tools' { Install-NdiTools -ClientOnly }
        $ndiInstalled = $true
        $ndiNeedsRestart = $script:NdiRestartRequired
        $agentCompleted = Invoke-DeploymentStep 'PC Agent' { Install-PcAgent }
        if (-not $agentCompleted) {
            if ($ndiNeedsRestart) {
                Set-OperationOutcome 'RestartRequired' 'NDI Tools needs a Windows restart. PC Agent setup was not completed; run Client setup again afterwards.'
            } else {
                Set-OperationOutcome 'Cancelled' 'NDI Tools is installed. PC Agent setup was not completed; run Client setup again to finish.'
            }
            return
        }
        Set-SuiteProgress -Percent 100 -Status 'Client installation finished'
        if ($ndiNeedsRestart) {
            Set-OperationOutcome 'RestartRequired' 'NDI Tools and PC Agent are installed. Restart Windows to finish NDI Tools installation.'
        } else {
            Set-OperationOutcome 'Completed' 'NDI Tools and NDI Configurator PC Agent are installed.'
        }
    } catch {
        if (-not $ndiInstalled) { throw }
        $failure = $_.Exception.Message
        $evidence = 'PC Agent installed state could not be verified.'
        try {
            $install = Join-Path $env:ProgramFiles 'NDI Configurator\PC Agent'
            $agentVersion = Get-PcAgentBinaryVersion (Join-Path $install 'NDI Configurator PC Agent.exe') 'NDI Configurator PC Agent'
            $setupVersion = Get-PcAgentBinaryVersion (Join-Path $install 'NDI Configurator PC Agent Setup.exe') 'NDI Configurator PC Agent'
            $configured = Test-PcAgentConfigured
            $evidence = "Detected PC Agent: $(if ($agentVersion) { $agentVersion } else { 'missing/unknown' }); Setup: $(if ($setupVersion) { $setupVersion } else { 'missing/unknown' }); configured: $configured."
        } catch { Write-InstallerLog "Could not read PC Agent state after failure: $($_.Exception.Message)" }
        $restart = if ($script:NdiRestartRequired) { ' Restart Windows to finish NDI Tools installation.' } else { '' }
        # File replacement can precede configuration/startup failure. Preserve the
        # real failure while explaining exactly what survived for repair/retry.
        throw "NDI Tools installation completed.$restart PC Agent setup did not finish successfully. $evidence $failure"
    } finally { Stop-SuiteProgress }
}
