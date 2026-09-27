function Convert-ToVersion {
    param([string]$Value)
    if (-not $Value) { return $null }
    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')
    if (-not $match.Success) { return $null }
    try { return [version]$match.Value } catch { return $null }
}

function Download-FileWithProgress {
    param(
        [string]$Uri,
        [string]$Destination,
        [int]$BasePercent,
        [int]$PercentSpan,
        [string]$Status
    )
    if ($PackageDirectory) {
        $name = if (([uri]$Uri).Host -eq 'downloads.ndi.tv') { 'NDI-Tools.exe' }
            elseif ($Uri -like 'https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/download/*') { 'PC-Agent.zip' }
            else { throw 'This package source has no supported offline package mapping.' }
        $source = Join-Path ([IO.Path]::GetFullPath($PackageDirectory)) $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required offline package is missing: $name" }
        Copy-Item -LiteralPath $source -Destination $Destination -Force
        return
    }
    Assert-PackageSource $Uri
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if (-not $script:ProgressActive -or -not (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)) {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec 1800
        return
    }

    $job = $null
    try {
        $job = Start-BitsTransfer -Source $Uri -Destination $Destination -DisplayName 'KiloLink Suite package download' -Asynchronous
        if (-not $job.JobId) {
            throw 'BITS did not return a job identifier.'
        }
        $transferDeadline = [datetime]::UtcNow.AddMinutes(30)
        $lastTransfer = [datetime]::UtcNow
        $lastBytes = 0
        while ($true) {
            $job = Get-BitsTransfer -JobId $job.JobId
            if ($job.BytesTransferred -ne $lastBytes) { $lastBytes = $job.BytesTransferred; $lastTransfer = [datetime]::UtcNow }
            if ([datetime]::UtcNow -gt $transferDeadline -or ([datetime]::UtcNow - $lastTransfer).TotalSeconds -gt 45) { throw 'The required package transfer timed out. Check the package source and retry.' }
            if ($job.JobState -eq 'Transferred') { break }
            if ($job.JobState -in @('Error', 'TransientError', 'Cancelled')) {
                throw "BITS download entered state $($job.JobState): $($job.ErrorDescription)"
            }
            # BITS reports UInt64.MaxValue until the server supplies the content length.
            # Treat that sentinel as unknown so the UI never displays an absurd total.
            if ($job.BytesTotal -gt 0 -and [uint64]$job.BytesTotal -ne [uint64]::MaxValue) {
                $fraction = [Math]::Min(1, [double]$job.BytesTransferred / [double]$job.BytesTotal)
                $percent = $BasePercent + [int]([Math]::Floor($fraction * $PercentSpan))
                $downloaded = [Math]::Round($job.BytesTransferred / 1MB, 1)
                $total = [Math]::Round($job.BytesTotal / 1MB, 1)
                Set-SuiteProgress -Percent $percent -Status ("{0}: {1} MB / {2} MB" -f $Status, $downloaded, $total)
            } else {
                Update-SuiteProgressPulse
            }
            Start-Sleep -Milliseconds 300
        }
        Complete-BitsTransfer -BitsJob $job
    } catch {
        if ($job) {
            Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-InstallerLog "BITS download failed; falling back to Invoke-WebRequest: $($_.Exception.Message)"
        Set-SuiteProgress -Percent $BasePercent -Status "$Status (fallback download)"
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -TimeoutSec 1800
    }
}

function Get-InstallerSignatureWithProgress {
    param([string]$Path)
    if (-not $script:ProgressActive) {
        return Get-AuthenticodeSignature -LiteralPath $Path
    }
    $job = Start-Job -ScriptBlock {
        param($InstallerPath)
        Get-AuthenticodeSignature -LiteralPath $InstallerPath
    } -ArgumentList $Path
    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            Update-SuiteProgressPulse
            Start-Sleep -Milliseconds 300
            $job = Get-Job -Id $job.Id
        }
        if ($job.State -ne 'Completed') {
            $reason = [string]$job.ChildJobs[0].JobStateInfo.Reason
            throw "Signature verification failed to complete: $reason"
        }
        return Receive-Job -Job $job
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-CurrentNdiToolsUrl {
    param($Page = $null)
    if (-not $Page) {
        $Page = Invoke-WebRequest -UseBasicParsing -Uri 'https://ndi.video/tools/' -TimeoutSec 60
        $script:NdiDownloadPage = $Page
    }
    $candidates = @($page.Links | ForEach-Object {
        $url = $null
        if ([Uri]::TryCreate([string](Get-PropertyValue $_ 'href' ''), [UriKind]::Absolute, [ref]$url) -and
            $url.Scheme -eq 'https' -and $url.Host -eq 'downloads.ndi.tv' -and
            [Uri]::UnescapeDataString($url.AbsolutePath) -match '^/Tools/NDI[^/]*Tools\.exe$') {
            $url.AbsoluteUri
        }
    } | Select-Object -Unique)
    if ($candidates.Count -ne 1) {
        throw 'The current Windows NDI Tools download could not be identified on ndi.video/tools/. Try again later.'
    }
    return $candidates[0]
}

function Convert-ToNdiToolsVersion {
    param([string]$Value)
    $Value = $Value.Trim()
    # A label or prerelease suffix is insufficient evidence to skip an update.
    if ($Value -notmatch '^\d+(?:\.\d+){1,3}$') { return $null }
    $version = Convert-ToVersion $Value
    if (-not $version) { return $null }
    return [version]::new($version.Major, $version.Minor, [Math]::Max(0, $version.Build), [Math]::Max(0, $version.Revision))
}

function Get-CurrentNdiToolsVersion {
    param([string]$Uri)
    try {
        $page = if ($script:NdiDownloadPage) { $script:NdiDownloadPage } else { Invoke-WebRequest -UseBasicParsing -Uri 'https://ndi.video/tools/' -TimeoutSec 20 -Headers @{'Cache-Control'='no-cache'} }
        $script:NdiDownloadPage = $null
        # The advertised version must belong to the package this operation uses.
        if ((Get-CurrentNdiToolsUrl -Page $page) -ne $Uri) { return $null }
        $content = [string](Get-PropertyValue $page 'Content' '')
        $content = [regex]::Replace($content, '(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>', '')
        $versions = @([regex]::Matches($content, '(?i)>\s*Version\s+(\d+\.\d+\.\d+(?:\.\d+)?)\s*<') | ForEach-Object {
            $version = Convert-ToNdiToolsVersion $_.Groups[1].Value
            if ($version) { $version }
        } | Select-Object -Unique)
        if ($versions.Count -eq 1) { return $versions[0] }
    } catch {
        Write-InstallerLog "NDI version metadata is unavailable; checking the signed installer instead: $($_.Exception.Message)"
    }
    return $null
}

function Initialize-QuietInstaller {
    if (-not ('KiloLink.Setup.QuietInstaller' -as [type])) {
        $source = Join-Path $PSScriptRoot 'QuietInstaller.cs'
        if (-not (Test-Path -LiteralPath $source)) { $source = Join-Path $PSScriptRoot 'launcher\QuietInstaller.cs' }
        Add-Type -Path $source
    }
}

function Assert-NdiToolsFilesAvailable {
    $files = @(Get-NdiToolsFiles | Where-Object { $_.Extension -in @('.exe','.dll') } | Select-Object -ExpandProperty FullName -Unique)
    if ($files.Count -eq 0) { return }
    Initialize-QuietInstaller
    $applications = @([KiloLink.Setup.QuietInstaller]::GetLockingApplications([string[]]$files))
    if ($applications.Count -gt 0) {
        throw "NDI Tools files are in use by: $($applications -join ', '). Close these applications or stop their background tasks, then retry Setup. No NDI installation was started."
    }
}

function Start-QuietInstaller {
    param([string]$FilePath, [string[]]$ArgumentList)
    Initialize-QuietInstaller
    return [KiloLink.Setup.QuietInstaller]::Start($FilePath, ($ArgumentList -join ' '))
}

function Install-NdiTools {
    param([switch]$UpdateOnly, [switch]$ClientOnly, [switch]$PrepareOnly, [switch]$EnsureLatest)
    $script:NdiRestartRequired = $false
    $preparedCheck = if (-not $PrepareOnly) { $script:PreparedNdiCheck } else { $null }
    $script:PreparedNdiCheck = $null
    $registration = Get-NdiRegistration
    if ($EnsureLatest -and $registration) { $UpdateOnly = $true }
    if ($UpdateOnly -and -not $registration) {
        throw 'NDI Tools is missing. Choose Repair / Reconfigure to install it.'
    }
    $componentsMissing = -not $ClientOnly -and -not (Get-NdiDiscoveryExe)
    $installedVersion = if ($registration) { Convert-ToNdiToolsVersion ([string](Get-PropertyValue $registration 'DisplayVersion' '')) } else { $null }
    if ($registration -and -not $UpdateOnly -and -not $ClientOnly -and -not $componentsMissing) {
        Write-Detail "NDI Tools $installedVersion is already installed." Green
        return
    }

    Write-Step 'Checking the current NDI Tools package'
    $downloadUrl = if ($script:PreparedNdiInstaller) { $script:PreparedNdiSource }
        elseif ($preparedCheck) { $preparedCheck.Url }
        elseif (-not $PackageDirectory) { Get-CurrentNdiToolsUrl }
        else { $script:NdiToolsUrl }
    if ($UpdateOnly -and -not $ClientOnly -and -not $componentsMissing -and $installedVersion -and
        -not $PackageDirectory -and -not $script:PreparedNdiInstaller) {
        $currentVersion = if ($preparedCheck -and $preparedCheck.Url -eq $downloadUrl) { $preparedCheck.Version } else { Get-CurrentNdiToolsVersion -Uri $downloadUrl }
        if ($currentVersion -and $installedVersion -ge $currentVersion) {
            # Keep the preflight result for this operation, then recheck local files
            # and registration when consuming it. A later operation checks again.
            if ($PrepareOnly) { $script:PreparedNdiCheck = [pscustomobject]@{Url=$downloadUrl;Version=$currentVersion} }
            Write-Detail "NDI Tools $installedVersion is current. Download skipped." Green
            return
        }
    }
    $downloadDir = Join-Path $env:TEMP 'KiloLinkSuite'
    $installer = Join-Path $downloadDir 'NDI-Tools.exe'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $downloadSpan = if ($ClientOnly) { 35 } else { 8 }
    if ($script:PreparedNdiInstaller) { $installer = $script:PreparedNdiInstaller }
    else {
        Download-FileWithProgress -Uri $downloadUrl -Destination $installer -BasePercent $script:ProgressPercent -PercentSpan $downloadSpan -Status 'Downloading NDI Tools'
        $script:PreparedNdiSource = $downloadUrl
    }

    Set-SuiteProgress -Percent ([Math]::Min(90, $script:ProgressPercent + 1)) -Status 'Verifying the NDI Tools signature'
    $signature = Get-InstallerSignatureWithProgress -Path $installer
    if ([string]$signature.Status -ne 'Valid') {
        throw "NDI installer signature validation failed: $($signature.Status)"
    }
    if ([string]$signature.SignerCertificate.Subject -notmatch '(?i)(Vizrt|NDI|NewTek)') {
        throw 'NDI installer publisher validation failed. Use the official NDI package.'
    }
    $packageVersion = Convert-ToNdiToolsVersion ((Get-Item -LiteralPath $installer).VersionInfo.ProductVersion)
    Save-ResolvedPackage 'ndiTools' ([string]$packageVersion) $downloadUrl $installer
    if ($componentsMissing -and $installedVersion -and $packageVersion -and $installedVersion -gt $packageVersion) { throw 'A newer NDI Tools installation is incomplete. Repair it with its matching vendor installer.' }
    $install = $componentsMissing -or -not $registration -or -not $installedVersion -or -not $packageVersion -or $packageVersion -gt $installedVersion
    # Re-running client setup repairs the current package without requiring any server components.
    if ($ClientOnly -and $packageVersion -eq $installedVersion) { $install = $true }
    if ($install) { Assert-NdiToolsFilesAvailable }
    if ($PrepareOnly) { $script:PreparedNdiInstaller = $installer; return }
    $script:PreparedNdiInstaller = $null
    if (-not $install) {
        Write-Detail "NDI Tools $installedVersion is current." Green
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        return
    }

    Set-SuiteProgress -Percent ([Math]::Min(92, $script:ProgressPercent + 2)) -Status 'Installing NDI Tools'
    $vendorLogDirectory = Join-Path $script:StateRoot 'Logs'
    New-Item -ItemType Directory -Path $vendorLogDirectory -Force | Out-Null
    $vendorLog = Join-Path $vendorLogDirectory ('ndi-tools-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.log')
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NORESTARTAPPLICATIONS', '/NOCLOSEAPPLICATIONS', '/RESTARTEXITCODE=3010', '/SP-', ('/LOG="' + $vendorLog + '"'))
    Write-InstallerLog "Starting NDI Tools setup. Vendor log: $vendorLog"
    $process = Start-QuietInstaller -FilePath $installer -ArgumentList $arguments
    try {
        while (-not $process.HasExited) {
            Update-SuiteProgressPulse
            Start-Sleep -Milliseconds 300
            $process.Refresh()
        }
        $exitCode = $process.ExitCode
        Write-InstallerLog "NDI Tools setup exited with code $exitCode. Vendor log: $vendorLog"
        if ($exitCode -notin @(0, 3010)) { throw "NDI Tools installer failed with exit code $exitCode. Vendor log: $vendorLog" }
    } finally { $process.Dispose() }
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if (-not (Get-NdiRegistration)) {
        throw 'NDI Tools finished installing but was not detected in Programs and Features.'
    }
    if (-not $ClientOnly -and -not (Get-NdiDiscoveryExe)) {
        throw 'NDI Tools finished installing but its Discovery Service executable is still missing.'
    }
    $script:NdiRestartRequired = $exitCode -eq 3010
    Write-Detail 'NDI Tools installed or updated.' Green
}



function Get-PcAgentPublicRelease {
    # GitHub's public latest-release redirect and the publisher's checksum asset
    # remain available when the unauthenticated API quota is exhausted (HTTP 403).
    $base = 'https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/'
    $page = Invoke-WebRequest -UseBasicParsing -Uri ($base + 'latest') -TimeoutSec 60
    $response = $page.BaseResponse
    $uri = Get-PropertyValue $response 'ResponseUri' $null # Windows PowerShell 5.1
    if (-not $uri) {
        $request = Get-PropertyValue $response 'RequestMessage' $null
        if ($request) { $uri = Get-PropertyValue $request 'RequestUri' $null } # PowerShell 7
    }
    if (-not $uri -or $uri.AbsoluteUri -cnotmatch ('^' + [regex]::Escape($base) + 'tag/v(\d+\.\d+\.\d+)$')) {
        throw 'The PC Agent public production release could not be verified.'
    }
    $version = [version]$Matches[1]
    $name = 'NDI-Configurator-PC-Agent-win-x64.zip'
    $url = $base + 'download/v' + $version + '/' + $name
    $checksum = Invoke-WebRequest -UseBasicParsing -Uri ($url + '.sha256') -TimeoutSec 60
    $content = if ($checksum.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($checksum.Content) } else { [string]$checksum.Content }
    if ($content.Length -gt 4096 -or $content -cnotmatch ('\A([a-fA-F0-9]{64})[ \t]+\*?' + [regex]::Escape($name) + '\s*\z')) {
        throw 'The PC Agent release checksum is missing or invalid.'
    }
    $hash = $Matches[1]
    $asset = Invoke-WebRequest -UseBasicParsing -Uri $url -Method Head -TimeoutSec 60
    $size = 0L
    if (-not [long]::TryParse([string]$asset.Headers['Content-Length'], [ref]$size) -or $size -le 0 -or $size -gt 512MB) {
        throw 'The PC Agent release download size is invalid.'
    }
    return [pscustomobject]@{ Version = $version; Url = $url; Size = $size; Hash = $hash }
}

function Get-PcAgentRelease {
    try {
        if ($PackageDirectory) { $release = Get-Content -LiteralPath (Join-Path $PackageDirectory 'pc-agent-release.json') -Raw | ConvertFrom-Json }
        else { $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/JohnDevAc/Kiloview-PC-Onboarding/releases/latest' -TimeoutSec 15 -Headers @{
            'User-Agent' = 'Kiloview-Environment-Setup'; Accept = 'application/vnd.github+json'
        } }
    } catch {
        if ($PackageDirectory) { throw "Offline PC Agent release metadata could not be read. Supply pc-agent-release.json from the production release. $($_.Exception.Message)" }
        Write-InstallerLog ('PC Agent API lookup failed; checking the public release and checksum: ' + $_.Exception.Message)
        return Get-PcAgentPublicRelease
    }
    if ($release.draft -or $release.prerelease -or $release.target_commitish -ne 'main' -or
        $release.tag_name -notmatch '^v(\d+\.\d+\.\d+)$') { throw 'The PC Agent production release could not be verified.' }
    $version = [version]$Matches[1]
    $name = 'NDI-Configurator-PC-Agent-win-x64.zip'
    $assets = @($release.assets | Where-Object name -eq $name)
    if ($assets.Count -ne 1) { throw 'The complete PC Agent Windows package is missing from its production release.' }
    $asset = $assets[0]
    $expectedUrl = 'https://github.com/JohnDevAc/Kiloview-PC-Onboarding/releases/download/' + $release.tag_name + '/' + $name
    if ($asset.browser_download_url -cne $expectedUrl -or $asset.size -le 0 -or $asset.size -gt 512MB -or
        (Get-PropertyValue $asset 'digest' '') -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw 'The PC Agent download URL, size or SHA-256 digest is invalid.'
    }
    return [pscustomobject]@{ Version = $version; Url = $expectedUrl; Size = [long]$asset.size; Hash = $Matches[1] }
}

function Expand-PcAgentPackage {
    param([string]$Archive, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $paths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $total = 0L
        if ($zip.Entries.Count -gt 4096) { throw 'The PC Agent archive has too many entries.' }
        # Validate every destination before extracting any package content.
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('/', '\')
            $parts = $relative.TrimEnd('\').Split('\')
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative))
            # Spaces within normal filenames are supported; trailing spaces and device paths are not.
            $unsafePart = @($parts | Where-Object {
                $_ -in @('', '.', '..') -or $_ -match '[:*?"<>|]|[. ]$' -or
                $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$'
            })
            $total += $entry.Length
            if ($relative.StartsWith('\') -or $unsafePart.Count -gt 0 -or
                -not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
                -not $paths.Add($target) -or $total -gt 1GB -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw 'The PC Agent archive contains unsafe or duplicate paths.'
            }
        }
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if ([string]::IsNullOrEmpty($entry.Name)) { [IO.Directory]::CreateDirectory($target) | Out-Null }
            else {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
            }
        }
    } finally { $zip.Dispose() }
}

function Compare-PcAgentVersion([string]$Left, [string]$Right) {
    if (-not $Left) { return -1 }
    if (-not $Right) { return 1 }
    $a = $Left.Split('+')[0].Split('-', 2)
    $b = $Right.Split('+')[0].Split('-', 2)
    $av = [version]$a[0]; $bv = [version]$b[0]
    $order = ([version]::new($av.Major,$av.Minor,[Math]::Max(0,$av.Build),[Math]::Max(0,$av.Revision))).CompareTo(
        [version]::new($bv.Major,$bv.Minor,[Math]::Max(0,$bv.Build),[Math]::Max(0,$bv.Revision)))
    if ($order) { return $order }
    if ($a.Count -eq 1) { if ($b.Count -eq 1) { return 0 }; return 1 }
    if ($b.Count -eq 1) { return -1 }
    $ap = $a[1].Split('.'); $bp = $b[1].Split('.')
    for ($i = 0; $i -lt [Math]::Max($ap.Count,$bp.Count); $i++) {
        if ($i -ge $ap.Count) { return -1 }
        if ($i -ge $bp.Count) { return 1 }
        [long]$an = 0; [long]$bn = 0
        $na = [long]::TryParse($ap[$i],[ref]$an); $nb = [long]::TryParse($bp[$i],[ref]$bn)
        $order = if ($na -and $nb) { $an.CompareTo($bn) } elseif ($na) { -1 } elseif ($nb) { 1 } else { [StringComparer]::Ordinal.Compare($ap[$i],$bp[$i]) }
        if ($order) { return $order }
    }
    return 0
}

function Get-PcAgentBinaryVersion {
    param([string]$Path, [string]$Product)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    if ($info.ProductName -ne $Product) { return $null }
    $version = Convert-ToVersion $info.ProductVersion
    if (-not $version) { return $null }
    $suffix = ([string]$info.ProductVersion).Split('+')[0].Split('-', 2)
    return ([version]::new($version.Major, $version.Minor, [Math]::Max(0, $version.Build))).ToString() + $(if ($suffix.Count -gt 1) { '-' + $suffix[1] } else { '' })
}

function Test-PcAgentConfigured {
    $sid = Get-InteractiveUserSid
    $profile = Get-ItemProperty -LiteralPath ("Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + $sid) -Name ProfileImagePath
    $local = Join-Path ([Environment]::ExpandEnvironmentVariables($profile.ProfileImagePath)) 'AppData\Local'
    $statePath = Join-Path $local 'NDI Configurator\PC Agent\agent-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $false }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        return Test-PcAgentState $state
    } catch { return $false }
}

function Test-PcAgentState($State) {
    try {
        $address = $null
        $endpoint = [guid]::Empty
        $adapter = [guid]::Empty
        $prefix = [int](Get-PropertyValue $State 'prefixLength' 0)
        if ([int](Get-PropertyValue $State 'schemaVersion' 0) -ne 1 -or
            -not [guid]::TryParse([string](Get-PropertyValue $State 'endpointId' ''), [ref]$endpoint) -or $endpoint -eq [guid]::Empty -or
            -not [guid]::TryParse([string](Get-PropertyValue $State 'adapterId' ''), [ref]$adapter) -or $adapter -eq [guid]::Empty -or
            $prefix -lt 1 -or $prefix -gt 30 -or
            -not [Net.IPAddress]::TryParse([string](Get-PropertyValue $State 'address' ''), [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($address)) { return $false }
        $bytes = $address.GetAddressBytes()
        if ($bytes[0] -eq 0 -or $bytes[0] -ge 224 -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254)) { return $false }
        [uint64]$number = ([uint64]$bytes[0] -shl 24) -bor ([uint64]$bytes[1] -shl 16) -bor ([uint64]$bytes[2] -shl 8) -bor $bytes[3]
        [uint64]$hostMask = [math]::Pow(2, 32 - $prefix) - 1
        return ($number -band $hostMask) -ne 0 -and ($number -band $hostMask) -ne $hostMask
    } catch { return $false }
}

function Invoke-PcAgentSetup {
    param([string]$Path)
    Set-SuiteProgress -Percent 90 -Status 'Complete the PC Agent setup window, then close it to return here'
    Write-InstallerLog "Starting verified PC Agent setup: $Path"
    $process = Start-Process -FilePath $Path -WorkingDirectory (Split-Path -Parent $Path) -PassThru -WindowStyle Normal
    try {
        while (-not $process.HasExited) {
            Update-SuiteProgressPulse
            Start-Sleep -Milliseconds 300
            $process.Refresh()
        }
        Write-InstallerLog "PC Agent setup exited with code $($process.ExitCode)."
        if ($process.ExitCode -eq 2) { return $false }
        if ($process.ExitCode -ne 0) { throw "PC Agent setup failed with exit code $($process.ExitCode)." }
        return Test-PcAgentConfigured
    } finally { $process.Dispose() }
}

function Install-PcAgent {
    param([switch]$PrepareOnly)
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'NDI Configurator PC Agent requires 64-bit Windows.' }
    Set-SuiteProgress -Percent 50 -Status 'Checking the PC Agent production release'
    $release = if ($script:PreparedPcAgentRelease) { $script:PreparedPcAgentRelease } else { Get-PcAgentRelease }
    $installRoot = Join-Path $env:ProgramFiles 'NDI Configurator\PC Agent'
    $installedSetup = Join-Path $installRoot 'NDI Configurator PC Agent Setup.exe'
    $installedAgent = Join-Path $installRoot 'NDI Configurator PC Agent.exe'
    $setupVersion = Get-PcAgentBinaryVersion $installedSetup 'NDI Configurator PC Agent'
    $agentVersion = Get-PcAgentBinaryVersion $installedAgent 'NDI Configurator PC Agent'
    if ($setupVersion -and $agentVersion -and (Compare-PcAgentVersion $setupVersion $agentVersion) -eq 0 -and (Compare-PcAgentVersion $agentVersion $release.Version) -ge 0) {
        if ($PrepareOnly) { $script:PreparedPcAgentRelease = $release; return $true }
        if (Test-PcAgentConfigured) {
            Write-Detail "PC Agent $agentVersion is already installed and configured." Green
            return $true
        }
        return Invoke-PcAgentSetup $installedSetup
    }
    # Never overwrite one half of a newer independent installation with an older release.
    if (($setupVersion -and (Compare-PcAgentVersion $setupVersion $release.Version) -gt 0) -or ($agentVersion -and (Compare-PcAgentVersion $agentVersion $release.Version) -gt 0)) {
        throw 'A newer PC Agent installation is incomplete. Repair it using its own matching release package.'
    }
    $cacheRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'KiloLinkSuite'))
    $packageRoot = if ($script:PreparedPcAgentRoot) { $script:PreparedPcAgentRoot } else { Join-Path $cacheRoot ('PC-Agent-' + [guid]::NewGuid().ToString('N')) }
    $prepared = $false
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    try {
        $archive = Join-Path $packageRoot 'PC-Agent.zip'
        if (-not $script:PreparedPcAgentRoot) { Download-FileWithProgress -Uri $release.Url -Destination $archive -BasePercent 52 -PercentSpan 30 -Status 'Downloading NDI Configurator PC Agent' }
        if ((Get-Item -LiteralPath $archive).Length -ne $release.Size -or
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $release.Hash) {
            throw 'The PC Agent package size or SHA-256 did not match its production release.'
        }
        # Re-extract from the reverified archive before launch; do not trust staged loose files.
        Save-ResolvedPackage 'pcAgent' ([string]$release.Version) $release.Url $archive
        $payload = Join-Path $packageRoot ('Payload-' + [guid]::NewGuid().ToString('N'))
        Expand-PcAgentPackage -Archive $archive -Destination $payload
        $setup = Join-Path $payload 'NDI Configurator PC Agent Setup.exe'
        $agent = Join-Path $payload 'Agent\NDI Configurator PC Agent.exe'
        if ((Compare-PcAgentVersion (Get-PcAgentBinaryVersion $setup 'NDI Configurator PC Agent') $release.Version) -ne 0 -or
            (Compare-PcAgentVersion (Get-PcAgentBinaryVersion $agent 'NDI Configurator PC Agent') $release.Version) -ne 0 -or
            -not (Test-Path -LiteralPath (Join-Path $payload 'LICENSE.md') -PathType Leaf)) {
            throw 'The PC Agent package is incomplete or its product/version does not match the release.'
        }
        if ($PrepareOnly) {
            $script:PreparedPcAgentRoot = $packageRoot
            $script:PreparedPcAgentRelease = $release
            $prepared = $true
            return $true
        }
        $completed = Invoke-PcAgentSetup $setup
        if (-not $completed) { return $false }
        $setupVersion = Get-PcAgentBinaryVersion $installedSetup 'NDI Configurator PC Agent'
        $agentVersion = Get-PcAgentBinaryVersion $installedAgent 'NDI Configurator PC Agent'
        if (-not $setupVersion -or -not $agentVersion -or (Compare-PcAgentVersion $setupVersion $agentVersion) -ne 0 -or (Compare-PcAgentVersion $agentVersion $release.Version) -lt 0) {
            throw 'PC Agent setup closed before the expected application files were installed.'
        }
        return $true
    } finally {
        $resolvedPackage = [IO.Path]::GetFullPath($packageRoot)
        if (-not $resolvedPackage.StartsWith($cacheRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'PC Agent cleanup path is outside the download cache.'
        }
        if (-not $prepared) {
            Remove-Item -LiteralPath $resolvedPackage -Recurse -Force -ErrorAction SilentlyContinue
            $script:PreparedPcAgentRoot = $null
            $script:PreparedPcAgentRelease = $null
        }
    }
}

function Assert-PackageSource([string]$Uri) {
    try {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Head -TimeoutSec 12
            $contentType = $response.Headers['Content-Type']
        } catch {
            $status = Get-PropertyValue (Get-PropertyValue $_.Exception 'Response' $null) 'StatusCode' 0
            if ([int]$status -notin @(405, 501)) { throw }
            $request = [Net.HttpWebRequest]::CreateHttp($Uri)
            $request.Method = 'GET'
            $request.Timeout = 12000
            $request.ReadWriteTimeout = 12000
            $request.AddRange(0, 0)
            # Inspect headers only, including when a source ignores Range.
            $probe = $request.GetResponse()
            try { $contentType = $probe.ContentType } finally { $probe.Close() }
        }
        if ($contentType -match 'text/html') { throw 'The source returned a web page instead of a package.' }
    } catch {
        throw "Required download unavailable from $(([uri]$Uri).Host). Check internet access, proxy and package-source access, then retry. $($_.Exception.Message)"
    }
}

function Prepare-ClientPackages {
    Set-SuiteProgress -Percent 2 -Status 'Checking and acquiring both required client packages before installation'
    [void](Install-PcAgent -PrepareOnly)
    try { Install-NdiTools -ClientOnly -PrepareOnly }
    catch {
        if ($script:PreparedPcAgentRoot) {
            $cache = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'KiloLinkSuite')) + '\'
            $preparedPath = [IO.Path]::GetFullPath($script:PreparedPcAgentRoot)
            if (-not $preparedPath.StartsWith($cache, [StringComparison]::OrdinalIgnoreCase)) { throw 'Prepared package path is outside the cache.' }
            Remove-Item -LiteralPath $preparedPath -Recurse -Force -ErrorAction SilentlyContinue
            $script:PreparedPcAgentRoot = $null
        }
        throw
    }
}
