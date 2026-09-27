#Requires -Version 5.1
# Copyright (c) 2026 John Lightfoot
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param([string]$OutputDirectory, [string]$ConfigurationPackage)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = $root }
& (Join-Path $root 'Build-Provisioner.ps1')
$version = (Get-Content -LiteralPath (Join-Path $root 'version.json') -Raw | ConvertFrom-Json).version
$generated = Join-Path $root 'artifacts\generated'
New-Item -ItemType Directory -Path $generated -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$assemblyInfo = Join-Path $generated 'Version.cs'
[IO.File]::WriteAllText($assemblyInfo, ('[assembly: System.Reflection.AssemblyVersion("{0}.0")]{1}[assembly: System.Reflection.AssemblyFileVersion("{0}.0")]' -f $version,[Environment]::NewLine))
$source = Join-Path $root 'launcher\SetupLauncher.cs'
$wizardSource = Join-Path $root 'launcher\SetupWizard.cs'
$layoutSource = Join-Path $root 'launcher\SetupLayout.cs'
$packageSource = Join-Path $root 'launcher\SetupPackage.cs'
$quietSource = Join-Path $root 'launcher\QuietInstaller.cs'
$manifest = Join-Path $generated 'Setup.exe.manifest'
[IO.File]::WriteAllText($manifest, ([IO.File]::ReadAllText((Join-Path $root 'launcher\Setup.exe.manifest')).Replace('__PRODUCT_VERSION__', $version)))
$installer = Join-Path $root 'Install-KiloLinkSuite.ps1'
$icon = Join-Path $root 'assets\setup.ico'
$iconArtwork = Join-Path $root 'assets\setup-icon.png'
$license = Join-Path $root 'LICENSE'
$eula = Join-Path $root 'EULA.md'
$thirdPartyNotices = Join-Path $root 'THIRD_PARTY_NOTICES.md'
$outputName = 'Kiloview-Environment-Setup.exe'
$output = Join-Path $OutputDirectory $outputName

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) {
    throw 'The Windows .NET Framework C# compiler was not found.'
}

foreach ($requiredFile in @($source, $wizardSource, $layoutSource, $packageSource, $quietSource, $manifest, $installer, $icon, $iconArtwork, $license, $eula, $thirdPartyNotices)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) {
        throw "Required build input is missing: $requiredFile"
    }
}

Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    ('/win32manifest:"{0}"' -f $manifest),
    ('/win32icon:"{0}"' -f $icon),
    ('/resource:"{0}",KiloLink.Setup.Install-KiloLinkSuite.ps1' -f $installer),
    ('/resource:"{0}",KiloLink.Setup.QuietInstaller.cs' -f $quietSource),
    ('/resource:"{0}",KiloLink.Setup.setup-icon.png' -f $iconArtwork),
    ('/resource:"{0}",KiloLink.Setup.setup.ico' -f $icon),
    ('/resource:"{0}",KiloLink.Setup.LICENSE' -f $license),
    ('/resource:"{0}",KiloLink.Setup.EULA.md' -f $eula),
    ('/resource:"{0}",KiloLink.Setup.THIRD_PARTY_NOTICES.md' -f $thirdPartyNotices),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll',
    ('/out:"{0}"' -f $output),
    ('"{0}"' -f $source),
    ('"{0}"' -f $wizardSource),
    ('"{0}"' -f $layoutSource),
    ('"{0}"' -f $packageSource),
    ('"{0}"' -f $assemblyInfo)
)
if ($ConfigurationPackage) {
    $ConfigurationPackage = (Resolve-Path -LiteralPath $ConfigurationPackage).Path
    $compilerArguments += '/resource:"' + $ConfigurationPackage + '",KiloLink.Setup.ConfigurationPackage.exe'
}

$responseFile = Join-Path $generated 'compiler.rsp'
[IO.File]::WriteAllLines($responseFile, $compilerArguments, [Text.UTF8Encoding]::new($false))
& $compiler "@$responseFile"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) {
    throw "$outputName build failed with exit code $LASTEXITCODE."
}

$file = Get-Item -LiteralPath $output
Write-Host "Built $($file.FullName) ($($file.Length) bytes)" -ForegroundColor Green
