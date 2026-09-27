#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
$payload = Join-Path $root 'artifacts\payload'
& (Join-Path $root 'Build-Setup.ps1') -OutputDirectory $payload
foreach ($file in @('Install-KiloLinkSuite.ps1','LICENSE','EULA.md','THIRD_PARTY_NOTICES.md')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $payload -Force }
$licensePayload = Join-Path $payload 'licenses'
New-Item -ItemType Directory -Path $licensePayload -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'licenses\WiX-5.0.2.txt') -Destination $licensePayload -Force
$sourceArchive = Join-Path $root '.build-cache\wix-5.0.2-source.zip'
New-Item -ItemType Directory -Path (Split-Path $sourceArchive) -Force | Out-Null
if (-not (Test-Path -LiteralPath $sourceArchive)) {
    Invoke-WebRequest -UseBasicParsing 'https://github.com/wixtoolset/wix/archive/refs/tags/v5.0.2.zip' -OutFile $sourceArchive
}
if ((Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash -ne '82A2297BE4FAC7E5CA771DAF9B10B1719CCA896045AB1510CF769CC333F48034') { throw 'WiX source archive checksum mismatch.' }
Copy-Item -LiteralPath $sourceArchive -Destination $licensePayload -Force
# Render the exact maintained agreement into WiX's embedded scrollable licence page.
$legalText = [IO.File]::ReadAllText((Join-Path $root 'EULA.md')) + "`n`n" + [IO.File]::ReadAllText((Join-Path $root 'THIRD_PARTY_NOTICES.md'))
$rtf = [Text.StringBuilder]::new('{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\f0\fs18 ')
foreach ($character in $legalText.ToCharArray()) {
    $code = [int]$character
    if ($character -eq "`r") { continue }
    if ($character -eq "`n") { [void]$rtf.Append('\par '); continue }
    if ($character -in @('\','{','}')) { [void]$rtf.Append('\').Append($character); continue }
    if ($code -gt 127) { if ($code -gt 32767) { $code -= 65536 }; [void]$rtf.Append('\u').Append($code).Append('?'); continue }
    [void]$rtf.Append($character)
}
[void]$rtf.Append('}')
[IO.File]::WriteAllText((Join-Path $payload 'EULA.rtf'), $rtf.ToString(), [Text.Encoding]::ASCII)
Copy-Item -LiteralPath (Join-Path $root 'launcher\QuietInstaller.cs') -Destination $payload -Force
Copy-Item -LiteralPath (Join-Path $root 'assets\setup.ico') -Destination $payload -Force
Copy-Item -LiteralPath (Join-Path $root 'packages\applications.json') -Destination $payload -Force
Copy-Item -LiteralPath (Join-Path $root 'docs\RECOVERY.md') -Destination $payload -Force
[IO.File]::WriteAllText((Join-Path $payload 'managed-installation.json'), '{"schemaVersion":1,"installer":"msi"}')
$msiOutput = Join-Path $root 'artifacts\msi'
& dotnet build (Join-Path $root 'installer\Application\Application.wixproj') -c Release "-p:ProductVersion=$version" "-p:PayloadDir=$payload" "-o:$msiOutput"
if ($LASTEXITCODE -ne 0) { throw 'MSI build failed.' }
$msi = Join-Path $msiOutput 'Kiloview-Configuration.msi'
$bundleOutput = Join-Path $root 'artifacts\package'
& dotnet build (Join-Path $root 'installer\Bundle\Bundle.wixproj') -c Release "-p:ProductVersion=$version" "-p:PayloadDir=$payload" "-p:ApplicationMsi=$msi" "-p:RepoRoot=$root" "-o:$bundleOutput"
if ($LASTEXITCODE -ne 0) { throw 'Setup bundle build failed.' }
$package = Join-Path $bundleOutput 'Kiloview-Environment-Setup.exe'
$releaseOutput = Join-Path $root 'artifacts\installer'
& (Join-Path $root 'Build-Setup.ps1') -OutputDirectory $releaseOutput -ConfigurationPackage $package
$bundle = Join-Path $releaseOutput 'Kiloview-Environment-Setup.exe'
Get-FileHash -LiteralPath $bundle -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLowerInvariant())  Kiloview-Environment-Setup.exe" } | Set-Content -LiteralPath ($bundle + '.sha256') -Encoding ASCII
Write-Output "Built installer: $bundle"
