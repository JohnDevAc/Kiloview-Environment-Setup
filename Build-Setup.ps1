#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'launcher\SetupLauncher.cs'
$manifest = Join-Path $root 'launcher\Setup.exe.manifest'
$installer = Join-Path $root 'Install-KiloLinkSuite.ps1'
$icon = Join-Path $root 'assets\setup.ico'
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

foreach ($requiredFile in @($source, $manifest, $installer, $icon)) {
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
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    ('/out:"{0}"' -f $output),
    ('"{0}"' -f $source)
)

& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) {
    throw "$outputName build failed with exit code $LASTEXITCODE."
}

$file = Get-Item -LiteralPath $output
Write-Host "Built $($file.FullName) ($($file.Length) bytes)" -ForegroundColor Green
