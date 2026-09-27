# Read-only verification of the built MSI and licence payload. Does not install it.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
$payload = Join-Path $root 'artifacts\payload'
$msi = Join-Path $root 'artifacts\msi\Kiloview-Configuration.msi'
function Assert-Packaging($Condition, $Message) { if (-not $Condition) { throw $Message } }
$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.OpenDatabase($msi, 0)
function Read-Table([string]$Query, [int]$ColumnCount = 2) {
    $view = $database.OpenView($Query)
    try {
        [void]$view.Execute()
        while ($record = $view.Fetch()) {
            try {
                $row = @()
                for ($i=1; $i -le $ColumnCount; $i++) { $row += $record.StringData($i) }
                ,$row
            } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($record) }
        }
    } finally { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view) }
}
try {
    $properties = @{}
    foreach ($row in (Read-Table 'SELECT `Property`, `Value` FROM `Property`')) { $properties[$row[0]] = $row[1] }
    Assert-Packaging ($properties.ProductVersion -eq $version -and $properties.Manufacturer -eq 'John Lightfoot') 'MSI version or publisher mismatch.'
    $files = @((Read-Table 'SELECT `FileName` FROM `File`' 1) | ForEach-Object { ($_ -join '').Split('|')[-1] })
    foreach ($name in @('Kiloview-Environment-Setup.exe','Install-KiloLinkSuite.ps1','EULA.md','EULA.rtf','LICENSE','THIRD_PARTY_NOTICES.md','WiX-5.0.2.txt','wix-5.0.2-source.zip','managed-installation.json')) {
        Assert-Packaging ($files -contains $name) "Required installed file missing: $name"
    }
    $tables = @((Read-Table 'SELECT `Name` FROM `_Tables`' 1) | ForEach-Object { $_ -join '' })
    Assert-Packaging ($tables -notcontains 'CustomAction' -and $tables -notcontains 'ServiceInstall') 'MSI must not provision WSL/services inside its transaction.'
    $search = Read-Table 'SELECT `Key`, `Name` FROM `RegLocator`'
    Assert-Packaging (($search | Out-String).Contains('CurrentBuildNumber')) 'MSI relies on compatibility-shim WindowsBuild.'
} finally {
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($database)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
}
Add-Type -AssemblyName System.Windows.Forms
$box = New-Object Windows.Forms.RichTextBox
try {
    $box.Rtf = [IO.File]::ReadAllText((Join-Path $payload 'EULA.rtf'))
    $expected = [IO.File]::ReadAllText((Join-Path $root 'EULA.md')) + "`n`n" + [IO.File]::ReadAllText((Join-Path $root 'THIRD_PARTY_NOTICES.md'))
    Assert-Packaging ($box.Text.Replace("`r",'').TrimEnd() -ceq $expected.Replace("`r",'').TrimEnd()) 'Displayed licence differs from maintained EULA/notices.'
    Assert-Packaging ($box.Text.Contains('Copyright (c) 2026 John Lightfoot') -and $box.Text.Contains('personal and commercial')) 'Free-use attribution is missing.'
} finally { $box.Dispose() }
$license = [IO.File]::ReadAllText((Join-Path $root 'LICENSE')).Replace("`r",'').Trim()
$eula = [IO.File]::ReadAllText((Join-Path $root 'EULA.md')).Replace("`r",'')
Assert-Packaging ($eula.EndsWith($license.Substring($license.IndexOf('Copyright')).Trim(),[StringComparison]::Ordinal) -or $eula.TrimEnd().EndsWith($license.Substring($license.IndexOf('Copyright')).Trim(),[StringComparison]::Ordinal)) 'MIT terms were altered in the EULA.'
$exe = Join-Path $payload 'Kiloview-Environment-Setup.exe'
Assert-Packaging ((Get-Item $exe).VersionInfo.FileVersion -eq ($version + '.0')) 'Application version differs from MSI.'
$bundle = Join-Path $root 'artifacts\installer\Kiloview-Environment-Setup.exe'
$recordedHash = (Get-Content ($bundle + '.sha256') -Raw).Split(' ')[0]
Assert-Packaging ((Get-FileHash $bundle).Hash -ieq $recordedHash) 'Bundle checksum is stale.'
$bundleAuthoring = [xml](Get-Content (Join-Path $root 'installer\Bundle\Bundle.wxs') -Raw)
$ba = $bundleAuthoring.SelectSingleNode('//*[local-name()="WixStandardBootstrapperApplication"]')
Assert-Packaging ($ba.LicenseFile.EndsWith('EULA.rtf')) 'Internal package must retain licence delivery.'
Assert-Packaging ($null -eq $bundleAuthoring.SelectSingleNode('//*[local-name()="Variable" and @Name="LaunchTarget"]')) 'A second configuration wizard could be launched.'
$releaseAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($bundle))
$installedAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
Assert-Packaging ($releaseAssembly.GetManifestResourceNames() -contains 'KiloLink.Setup.ConfigurationPackage.exe') 'Release does not start in the single native wizard.'
Assert-Packaging ($installedAssembly.GetManifestResourceNames() -notcontains 'KiloLink.Setup.ConfigurationPackage.exe') 'Installed app recursively includes its own installer.'
$stream = $releaseAssembly.GetManifestResourceStream('KiloLink.Setup.ConfigurationPackage.exe')
$sha = [Security.Cryptography.SHA256]::Create()
try { $embeddedHash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') } finally { $stream.Dispose(); $sha.Dispose() }
Assert-Packaging ($embeddedHash -eq (Get-FileHash (Join-Path $root 'artifacts\package\Kiloview-Environment-Setup.exe')).Hash) 'Embedded Windows package differs from the verified build.'
foreach ($name in @('EULA.md','THIRD_PARTY_NOTICES.md')) {
    $reader = [IO.StreamReader]::new($releaseAssembly.GetManifestResourceStream('KiloLink.Setup.' + $name))
    try { Assert-Packaging ($reader.ReadToEnd() -ceq [IO.File]::ReadAllText((Join-Path $root $name))) 'Native wizard licence is stale.' } finally { $reader.Dispose() }
}
Write-Output 'PASS: Single-window release, embedded Windows package, MSI ownership, payloads, version, publisher, EULA, source/licence delivery and checksum.'
