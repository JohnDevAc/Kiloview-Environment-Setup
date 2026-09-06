#Requires -Version 5.1
# Copyright (c) 2026 John Lightfoot
# SPDX-License-Identifier: MIT
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'launcher\SetupLauncher.cs'
$wizardSource = Join-Path $root 'launcher\SetupWizard.cs'
$layoutSource = Join-Path $root 'launcher\SetupLayout.cs'
$quietSource = Join-Path $root 'launcher\QuietInstaller.cs'
$manifest = Join-Path $root 'launcher\Setup.exe.manifest'
$installer = Join-Path $root 'Install-KiloLinkSuite.ps1'
$icon = Join-Path $root 'assets\setup.ico'
$iconArtwork = Join-Path $root 'assets\setup-icon.png'
$license = Join-Path $root 'LICENSE'
$thirdPartyNotices = Join-Path $root 'THIRD_PARTY_NOTICES.md'
$outputName = 'Kiloview-Environment-Setup.exe'
$output = Join-Path $root $outputName

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) {
    throw 'The Windows .NET Framework C# compiler was not found.'
}

foreach ($requiredFile in @($source, $wizardSource, $layoutSource, $quietSource, $manifest, $installer, $icon, $iconArtwork, $license, $thirdPartyNotices)) {
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
    ('/resource:"{0}",KiloLink.Setup.THIRD_PARTY_NOTICES.md' -f $thirdPartyNotices),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll',
    ('/out:"{0}"' -f $output),
    ('"{0}"' -f $source),
    ('"{0}"' -f $wizardSource),
    ('"{0}"' -f $layoutSource)
)

& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) {
    throw "$outputName build failed with exit code $LASTEXITCODE."
}

$file = Get-Item -LiteralPath $output
Write-Host "Built $($file.FullName) ($($file.Length) bytes)" -ForegroundColor Green
