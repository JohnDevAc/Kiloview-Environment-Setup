function ConvertFrom-NdiToolsHtml {
    param([string]$Content)
    if ($Content.Length -gt 4MB) { throw 'The NDI download page exceeds the metadata size limit.' }
    $limit = [TimeSpan]::FromMilliseconds(500)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # Never use Windows PowerShell's lazy .Links parser: its regexes have no deadline.
    $hidden = [regex]::new('(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>', [Text.RegularExpressions.RegexOptions]::None, $limit)
    $content = $hidden.Replace($Content, '')
    $tags = [regex]::new('(?is)<a\b(?:"[^"]*"|''[^'']*''|[^''">])*>', [Text.RegularExpressions.RegexOptions]::None, $limit)
    $attributes = [regex]::new('(?is)(?<name>[^\s"''<>/=]+)(?:\s*=\s*(?:"(?<value>[^"]*)"|''(?<value>[^'']*)''|(?<value>[^\s"''=<>`]+)))?', [Text.RegularExpressions.RegexOptions]::None, $limit)
    $candidates = New-Object 'Collections.Generic.HashSet[string]'
    foreach ($tag in $tags.Matches($content)) {
        if ($watch.Elapsed.TotalSeconds -gt 5) { throw 'The NDI download page exceeded its parsing deadline.' }
        $href = $null; $hrefCount = 0
        foreach ($attribute in $attributes.Matches($tag.Value.Substring(2, $tag.Length - 3))) {
            if ($watch.Elapsed.TotalSeconds -gt 5) { throw 'The NDI download page exceeded its parsing deadline.' }
            if ($attribute.Groups['name'].Value -eq 'href') { $href = $attribute.Groups['value'].Value; $hrefCount++ }
        }
        if ($hrefCount -ne 1) { continue }
        $href = [Net.WebUtility]::HtmlDecode($href)
        $uri = $null
        if ([Uri]::TryCreate($href, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.Host -eq 'downloads.ndi.tv' -and $uri.Port -eq 443 -and -not $uri.UserInfo -and
            [Uri]::UnescapeDataString($uri.AbsolutePath) -match '^/Tools/NDI[^/]*Tools\.exe$') {
            [void]$candidates.Add($uri.AbsoluteUri)
        }
    }
    if ($candidates.Count -ne 1) { throw 'The current Windows NDI Tools download could not be identified on ndi.video/tools/. Try again later.' }
    $versions = New-Object 'Collections.Generic.HashSet[string]'
    $labels = [regex]::new('(?i)>\s*Version\s+(\d+\.\d+\.\d+(?:\.\d+)?)\s*<', [Text.RegularExpressions.RegexOptions]::None, $limit)
    foreach ($match in $labels.Matches($content)) {
        if ($watch.Elapsed.TotalSeconds -gt 5) { throw 'The NDI download page exceeded its parsing deadline.' }
        $version = [version]$match.Groups[1].Value
        [void]$versions.Add(([version]::new($version.Major, $version.Minor, $version.Build, [Math]::Max(0, $version.Revision))).ToString())
    }
    [pscustomobject]@{Url=@($candidates)[0];Version=$(if ($versions.Count -eq 1) { @($versions)[0] } else { $null })}
}

function Read-NdiToolsMetadata {
    param([string]$Uri = 'https://ndi.video/tools/')
    # This function runs only in the bounded read-only child. Its caller also
    # bounds the complete fetch/decode/parse lifetime, including DNS and TLS.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.Timeout = 20000
    $request.ReadWriteTimeout = 10000
    $request.MaximumAutomaticRedirections = 3
    $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $request.UserAgent = 'Kiloview-Environment-Setup'
    $request.Headers['Cache-Control'] = 'no-cache'
    $response = $null; $stream = $null; $buffer = $null
    try {
        $response = $request.GetResponse()
        if ($response.ContentLength -gt 4MB) { throw 'The NDI download page exceeds the metadata size limit.' }
        $stream = $response.GetResponseStream()
        $buffer = New-Object IO.MemoryStream
        $bytes = New-Object byte[] 16384
        while (($count = $stream.Read($bytes, 0, $bytes.Length)) -gt 0) {
            if ($buffer.Length + $count -gt 4MB) { throw 'The NDI download page exceeds the metadata size limit.' }
            $buffer.Write($bytes, 0, $count)
        }
        $encoding = [Text.Encoding]::UTF8
        if ($response.CharacterSet) { $encoding = [Text.Encoding]::GetEncoding($response.CharacterSet) }
        ConvertFrom-NdiToolsHtml ($encoding.GetString($buffer.ToArray()))
    } finally {
        if ($buffer) { $buffer.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Close() }
    }
}

function New-NdiMetadataProbeScript {
    $parser = (Get-Command ConvertFrom-NdiToolsHtml -CommandType Function).Definition
    $reader = (Get-Command Read-NdiToolsMetadata -CommandType Function).Definition
    return ('$ErrorActionPreference=''Stop''; $ProgressPreference=''SilentlyContinue''; function ConvertFrom-NdiToolsHtml {' + $parser +
        '}; function Read-NdiToolsMetadata {' + $reader +
        '}; try { Read-NdiToolsMetadata | ConvertTo-Json -Compress } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }')
}

function Get-NdiToolsMetadata {
    param([int]$TimeoutSeconds = 60)
    $previousMessage = $script:OperationMessage
    $previousStage = $script:LifecycleStage
    $script:OperationMessage = 'Checking the current NDI Tools package information.'
    Write-LifecycleResult 'running' $script:OperationMessage -Stage 'ndi-metadata'
    Set-SuiteProgress -Percent $script:ProgressPercent -Status $script:OperationMessage
    $shell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes((New-NdiMetadataProbeScript)))
    try {
        $output = Invoke-Native $shell @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -Capture -ReadOnly -TimeoutSeconds $TimeoutSeconds -StallSeconds 0
        $metadata = ($output -join "`n") | ConvertFrom-Json
        if (-not $metadata.Url) { throw 'The NDI metadata probe returned no verified download URL.' }
    } catch {
        if ($script:LifecycleErrorCode -eq 'lifecycle-result-write-failed') { throw }
        $timeout = $script:LifecycleErrorCode -eq 'command-timeout'
        $script:LifecycleErrorCode = if ($timeout) { 'ndi-metadata-timeout' } else { 'ndi-metadata-unavailable' }
        $script:LifecycleNextAction = 'Check access to ndi.video/tools/, then retry setup. No NDI installation or Windows feature change was started by this metadata check.'
        throw "NDI package information could not be checked within the metadata limits. $($script:LifecycleNextAction) $($_.Exception.Message)"
    }
    $script:OperationMessage = $previousMessage
    $script:LifecycleStage = $previousStage
    Write-LifecycleResult 'running' $previousMessage
    return $metadata
}
