# No vendor installation, registry change, visible desktop switch or elevation.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $env:TEMP ('kiloview-quiet-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$exe = Join-Path $fixtureRoot 'Fixture.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /reference:System.Windows.Forms.dll ("/out:$exe") (Join-Path $PSScriptRoot 'QuietInstaller.Fixture.cs')
if ($LASTEXITCODE -ne 0) { throw 'Fixture compilation failed.' }
Add-Type -Path (Join-Path $root 'launcher\QuietInstaller.cs')
$first = $null; $second = $null
try {
    $first = [KiloLink.Setup.QuietInstaller]::Start($exe, ('"' + (Join-Path $fixtureRoot 'first') + '"'))
    $second = [KiloLink.Setup.QuietInstaller]::Start($exe, ('"' + (Join-Path $fixtureRoot 'second') + '"'))
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while ((-not $first.HasExited -or -not $second.HasExited) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not $first.HasExited -or -not $second.HasExited -or $first.ExitCode -ne 3010 -or $second.ExitCode -ne 3010) { throw 'Installer wait/exit code was lost.' }
    $one = Get-Content -LiteralPath (Join-Path $fixtureRoot 'first.child')
    $two = Get-Content -LiteralPath (Join-Path $fixtureRoot 'second.child')
    if ($one[1] -notmatch '^KiloviewSetup_' -or $two[1] -eq $one[1] -or $one[2] -ne 'True') { throw 'GUI descendants did not remain on their own private desktops.' }
    $child = Get-Process -Id ([int]$one[0])
    $other = Get-Process -Id ([int]$two[0])
    $locks = [KiloLink.Setup.QuietInstaller]::GetLockingApplications(@($exe))
    if (-not ($locks -match ('PID ' + $child.Id + '\)'))) { throw 'Restart Manager did not identify the process holding the fixture executable.' }
    $child.Refresh(); $other.Refresh()
    if ($child.HasExited -or $other.HasExited) { throw 'The lock check closed a running application.' }
    $first.Dispose(); $first = $null
    if (-not $child.WaitForExit(5000)) { throw 'The installation completion window was left running.' }
    $other.Refresh()
    if ($other.HasExited) { throw 'Disposal affected another process tree.' }
    $second.Dispose(); $second = $null
    if (-not $other.WaitForExit(5000)) { throw 'The second fixture did not clean up.' }
    if ([KiloLink.Setup.QuietInstaller]::GetLockingApplications(@($exe)).Length -ne 0) { throw 'Restart Manager retained stale locks after fixture cleanup.' }
    $failed = $false
    try { [KiloLink.Setup.QuietInstaller]::Start((Join-Path $fixtureRoot 'missing.exe'), '') | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'A failed hidden start silently succeeded.' }
    Write-Output 'PASS: private desktop inheritance, GUI isolation, restart exit code, read-only lock detection, scoped child cleanup and failed start.'
} finally {
    if ($first) { $first.Dispose() }; if ($second) { $second.Dispose() }
}
