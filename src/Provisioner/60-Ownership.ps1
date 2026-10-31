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
        $receipt = Get-Content -Encoding UTF8 -LiteralPath $path -Raw | ConvertFrom-Json
        if ($receipt.schemaVersion -ne 1) { throw 'The installation ownership receipt has an unsupported schema.' }
        $serverSelected = @($receipt.roles) -contains 'server'
        $owner = [string](Get-PropertyValue $receipt 'serverOwnerSid' '')
        if (($serverSelected -or (Get-PropertyValue $receipt 'retainedServer' $false)) -and $owner) {
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
        Assert-ServerStorage $Config
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

function Get-LinuxSourceCheckScript {
    return @'
set -eu
check_source() {
  stage="$1"
  shift
  printf 'KILOLINK_SOURCE_CHECK_START:%s\n' "$stage"
  code=0
  "$@" || code=$?
  if [ "$code" -ne 0 ]; then
    printf 'KILOLINK_SOURCE_CHECK_FAILED:%s:%s\n' "$stage" "$code" >&2
    exit "$code"
  fi
  printf 'KILOLINK_SOURCE_CHECK_OK:%s\n' "$stage"
}
check_registry() {
  response=$(curl --connect-timeout 8 --max-time 15 -sS -o /dev/null -w '%{http_code}' https://registry-1.docker.io/v2/) || return $?
  if [ "$response" != 200 ] && [ "$response" != 401 ]; then
    printf 'Docker registry returned unexpected HTTP %s\n' "$response" >&2
    return 22
  fi
}
if command -v curl >/dev/null; then
  check_source docker-download curl --connect-timeout 8 --max-time 15 -fsSI https://download.docker.com/linux/ubuntu/gpg
  check_source docker-registry check_registry
else
  echo 'Docker endpoint checks deferred until curl is installed.'
fi
# A clean distro must download and process its first package index. Allow four
# minutes, retaining strict source errors and all progress in the installer log.
# Linux owns the deadline; its termination grace stays below the Windows native
# runner's five-minute silence limit. Never install or upgrade as a probe.
check_source ubuntu-metadata timeout --kill-after=10s 240s apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=12 -o Acquire::https::Timeout=12 update --error-on=any
echo KILOLINK_LINUX_SOURCES_READY
'@
}

function Assert-LinuxDownloads([string]$Distro) {
    # Native output is logged while it arrives. Keep native observation/timeouts
    # and persistence failures intact: they may require recovery before retry.
    $output = @(Invoke-WslScript $Distro (Get-LinuxSourceCheckScript) -Capture -IgnoreExitCode)
    $code = $LASTEXITCODE
    if ($code -eq 0 -and $output -contains 'KILOLINK_LINUX_SOURCES_READY') { return }
    $stage = 'WSL package'
    foreach ($line in $output) {
        switch -Exact ([string]$line) {
            'KILOLINK_SOURCE_CHECK_START:docker-download' { $stage = 'Docker download' }
            'KILOLINK_SOURCE_CHECK_START:docker-registry' { $stage = 'Docker registry' }
            'KILOLINK_SOURCE_CHECK_START:ubuntu-metadata' { $stage = 'Ubuntu package' }
        }
    }
    $script:LifecycleNextAction = 'Review the installer diagnostics, then retry setup.'
    if ($stage -eq 'Ubuntu package' -and $code -eq 124) {
        $script:LifecycleErrorCode = 'linux-package-check-timeout'
        throw 'Ubuntu package checks exceeded the 4-minute limit. See diagnostics, then retry.'
    }
    $script:LifecycleErrorCode = 'linux-package-check-failed'
    if ($code -eq 0) { throw 'Linux package checks did not confirm completion. See diagnostics, then retry.' }
    throw "$stage check failed (exit $code). See diagnostics, then retry."
}

function Save-ComponentReceipt([string]$Role, [switch]$Remove) {
    $previous=$null
    $path = Join-Path $script:StateRoot 'installation-components.json'
    $roles = @()
    $owner = $null
    if (Test-Path -LiteralPath $path) {
        $previous = Get-Content -Encoding UTF8 -LiteralPath $path -Raw | ConvertFrom-Json
        if ($previous.schemaVersion -ne 1) { throw 'Unsupported component receipt. Existing deployment ownership was preserved.' }
        if (@($previous.roles | Where-Object { $_ -notin @('client', 'server') }).Count -gt 0) {
            throw 'Unknown component role. Existing deployment ownership was preserved.'
        }
        $roles = @($previous.roles)
        $owner = Get-PropertyValue $previous 'serverOwnerSid' $null
    }
    if ($Role -eq 'server' -and -not $Remove) { Assert-ServerOwner; $owner = Get-CurrentUserSid }
    $retained=Test-Path -LiteralPath (Join-Path $script:StateRoot 'retained-server.json')
    if($Role -eq 'server' -and -not $Remove -and $Action -ne 'Uninstall' -and $retained){
        Remove-OwnedFile (Join-Path $script:StateRoot 'retained-server.json');$retained=$false
    }
    if ($Role -eq 'server' -and $Remove -and -not $retained) { $owner = $null }
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $selected = if ($Remove) { @($roles | Where-Object { $_ -ne $Role }) } else { @(($roles + $Role) | Select-Object -Unique) }
    if(@($roles).Count -eq @($selected).Count -and (@($roles|Sort-Object)-join ',') -eq (@($selected|Sort-Object)-join ',') -and $previous -and
        (Get-PropertyValue $previous 'serverOwnerSid' $null) -eq $owner -and [bool](Get-PropertyValue $previous 'retainedServer' $false) -eq [bool]$retained){return}
    $receipt = @{schemaVersion=1; roles=@($selected); serverOwnerSid=$owner; retainedServer=$retained; updatedUtc=[datetime]::UtcNow.ToString('o')}
    Write-StateJson $path $receipt
    Add-LifecycleEffect "Environment $Role role record updated."
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
        Set-SuiteProgress -Percent 65 -Status 'Installing or validating NDI Tools'
        Invoke-DeploymentStep 'NDI Tools' { Install-NdiTools -ClientOnly }
        $ndiInstalled = $true
        $ndiNeedsRestart = $script:NdiRestartRequired
        Set-SuiteProgress -Percent 85 -Status 'Installing or validating PC Agent'
        $agentCompleted = Invoke-DeploymentStep 'PC Agent' { Install-PcAgent } -IncompleteOnFalse
        $ndiNeedsRestart=$ndiNeedsRestart -or $script:PcAgentRestartRequired
        if (-not $agentCompleted) {
            $script:LifecycleErrorCode='pc-agent-incomplete'
            $script:LifecycleNextAction='Run Client setup again to finish PC Agent and review its licence. Review the selected operation before applying; explicit repair may reinstall NDI Tools.'
            if ($ndiNeedsRestart) {
                Set-OperationOutcome 'RestartRequired' 'NDI Tools needs a Windows restart. PC Agent setup was not completed; run Client setup again afterwards.'
            } else {
                Set-OperationOutcome 'Cancelled' 'NDI Tools is installed. PC Agent setup was not completed; run Client setup again to finish.'
            }
            return
        }
        Set-SuiteProgress -Percent 98 -Status 'Verifying client installation'
        if ($ndiNeedsRestart) {
            Set-OperationOutcome 'RestartRequired' 'NDI Tools and PC Agent are installed. Restart Windows to finish NDI Tools installation.'
        } else {
            if($script:Lifecycle -and $script:LifecycleEffects.Count -eq 0){Set-OperationOutcome 'NoChange' 'NDI Tools and PC Agent are already current. Onboarding remains a separate Agent operation.'}
            else {Set-OperationOutcome 'Completed' 'NDI Tools and NDI Configurator PC Agent are installed. Onboarding is managed separately by PC Agent.'}
        }
    } catch {
        if ($script:LifecycleErrorCode -eq 'lifecycle-result-write-failed') { throw }
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
