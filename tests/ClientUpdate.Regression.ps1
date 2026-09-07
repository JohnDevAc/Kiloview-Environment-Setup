# Loaded only inside Installer.Regression.ps1. Exercise the real archive, binary
# identity, process wait, configuration verification and installed-pair checks.
$clientFixturePackage = Join-Path $testRoot 'client-update-package'
New-Item -ItemType Directory -Path (Join-Path $clientFixturePackage 'Agent') -Force | Out-Null
$clientFixtureExe = Join-Path $clientFixturePackage 'NDI Configurator PC Agent Setup.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe ("/out:$clientFixtureExe") (Join-Path $PSScriptRoot 'ClientUpdate.Fixture.cs')
Assert-True ($LASTEXITCODE -eq 0) 'Harmless update fixture compilation failed.'
Copy-Item -LiteralPath $clientFixtureExe -Destination (Join-Path $clientFixturePackage 'Agent\NDI Configurator PC Agent.exe')
Set-Content -LiteralPath (Join-Path $clientFixturePackage 'LICENSE.md') -Value 'Test fixture only'
$clientFixtureArchive = Join-Path $testRoot 'client-update.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($clientFixturePackage, $clientFixtureArchive)
$clientFixtureRelease = [pscustomobject]@{Version='0.7.2';Url='https://example.invalid/fixture';Size=(Get-Item $clientFixtureArchive).Length;Hash=(Get-FileHash $clientFixtureArchive -Algorithm SHA256).Hash}
$oldFixtureSource = Join-Path $testRoot 'old-agent.cs'
'[assembly: System.Reflection.AssemblyProduct("NDI Configurator PC Agent")] [assembly: System.Reflection.AssemblyInformationalVersion("0.7.1")] class Old { static void Main() {} }' | Set-Content -LiteralPath $oldFixtureSource
$oldFixtureExe = Join-Path $testRoot 'old-agent.exe'
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe ("/out:$oldFixtureExe") $oldFixtureSource
Assert-True ($LASTEXITCODE -eq 0) 'Installed-version fixture compilation failed.'

foreach ($updateMode in @('success','fast','restart','cancel','unconfigured','mixed','fail-before','fail-after','fail-after-restart','concurrent-newer','staged-corrupt')) {
    Test-Case "Client update with real native setup process: $updateMode" {
        $previousProgramFiles = $env:ProgramFiles
        $previousFixtureRoot = $env:KILOLINK_CLIENT_UPDATE_FIXTURE
        try {
            $fixture = Join-Path $script:StateRoot 'client-update'
            New-Item -ItemType Directory -Path $fixture -Force | Out-Null
            $env:KILOLINK_CLIENT_UPDATE_FIXTURE = $fixture
            $env:ProgramFiles = Join-Path $fixture 'program-files'
            Set-Content -LiteralPath (Join-Path $fixture 'fixture-only') -Value 'isolated'
            Set-Content -LiteralPath (Join-Path $fixture 'mode') -Value $updateMode -NoNewline
            $valid = @{schemaVersion=1;endpointId=[guid]::NewGuid().ToString();adapterId=[guid]::NewGuid().ToString();address='192.0.2.20';prefixLength=24}
            $valid | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fixture 'valid-state.json')
            $profilePath = Join-Path $fixture 'profile'
            $oldInstall = Join-Path $env:ProgramFiles 'NDI Configurator\PC Agent'
            New-Item -ItemType Directory -Path $oldInstall -Force | Out-Null
            Copy-Item -LiteralPath $oldFixtureExe -Destination (Join-Path $oldInstall 'NDI Configurator PC Agent.exe')
            Copy-Item -LiteralPath $oldFixtureExe -Destination (Join-Path $oldInstall 'NDI Configurator PC Agent Setup.exe')
            $oldState = Join-Path $profilePath 'AppData\Local\NDI Configurator\PC Agent'
            New-Item -ItemType Directory -Path $oldState -Force | Out-Null
            if ($updateMode -ne 'unconfigured') { Copy-Item -LiteralPath (Join-Path $fixture 'valid-state.json') -Destination (Join-Path $oldState 'agent-state.json') }
            function Get-InteractiveUserSid { 'S-1-5-21-123-fixture' }
            function Get-ItemProperty {
                param($LiteralPath, $Name)
                Assert-True ($LiteralPath -like '*ProfileList\S-1-5-21-123-fixture' -and $Name -eq 'ProfileImagePath') 'Unexpected registry query.'
                [pscustomobject]@{ProfileImagePath=$profilePath}
            }
            function Get-PcAgentRelease { $clientFixtureRelease }
            function Download-FileWithProgress {
                param($Uri, $Destination)
                Assert-True ($Uri -eq $clientFixtureRelease.Url) 'Unexpected download.'
                Copy-Item -LiteralPath $clientFixtureArchive -Destination $Destination
            }
            $script:FixtureLaunches = 0
            function Start-Process {
                param($FilePath, $WorkingDirectory, [switch]$PassThru, $WindowStyle)
                Assert-True ($FilePath.StartsWith($testRoot + '\', [StringComparison]::OrdinalIgnoreCase)) 'Attempted a non-fixture process.'
                Assert-True ($WindowStyle -eq 'Normal') 'Production Agent setup lost its interactive window.'
                $script:FixtureLaunches++
                # This compiled fixture has no UI; the actual production setup stays interactive.
                Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden
            }
            Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Prepare-ClientPackages' }, $true).Extent.Text)
            function Install-NdiTools {
                param([switch]$ClientOnly, [switch]$PrepareOnly)
                Assert-True $ClientOnly 'Client update crossed into Server setup.'
                Assert-True ([bool]$script:PreparedPcAgentRoot) 'NDI mutation preceded Agent staging.'
                if ($PrepareOnly) { return }
                Set-Content -LiteralPath (Join-Path $fixture 'ndi-installed') -Value 'fixture'
                $script:NdiRestartRequired = $updateMode -in @('restart','fail-after-restart')
                if ($updateMode -eq 'staged-corrupt') {
                    Set-Content -LiteralPath (Join-Path $script:PreparedPcAgentRoot 'PC-Agent.zip') -Value 'corrupt'
                }
                if ($updateMode -eq 'concurrent-newer') {
                    $install = Join-Path $env:ProgramFiles 'NDI Configurator\PC Agent'
                    New-Item -ItemType Directory -Path $install -Force | Out-Null
                    $source = Join-Path $fixture 'newer.cs'
                    '[assembly: System.Reflection.AssemblyProduct("NDI Configurator PC Agent")] [assembly: System.Reflection.AssemblyInformationalVersion("0.8.0")] class Newer { static void Main() {} }' | Set-Content -LiteralPath $source
                    $exe = Join-Path $install 'NDI Configurator PC Agent.exe'
                    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe ("/out:$exe") $source | Out-Null
                    Assert-True ($LASTEXITCODE -eq 0) 'Newer fixture compilation failed.'
                    Copy-Item -LiteralPath $exe -Destination (Join-Path $install 'NDI Configurator PC Agent Setup.exe')
                    $state = Join-Path $profilePath 'AppData\Local\NDI Configurator\PC Agent'
                    New-Item -ItemType Directory -Path $state -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $fixture 'valid-state.json') -Destination (Join-Path $state 'agent-state.json')
                }
            }
            $AcceptLicenses = $true
            if ($updateMode -in @('mixed','fail-before','fail-after','fail-after-restart','staged-corrupt')) {
                $pattern = if ($updateMode -eq 'mixed') { 'expected application files' } elseif ($updateMode -eq 'staged-corrupt') { 'size or SHA-256' } else { 'failed with exit code 1' }
                $failure = $null
                try { Install-ClientTools } catch { $failure = $_.Exception.Message }
                Assert-True ($failure -match $pattern -and $failure.Contains('NDI Tools installation completed.')) 'The failure lost its original error or completed NDI phase.'
                if ($updateMode -like 'fail-after*') {
                    Assert-True ($failure.Contains('PC Agent: 0.7.2; Setup: 0.7.2; configured: True.')) 'Late failure did not report the surviving installed pair/configuration.'
                    Assert-True ($failure.Contains('Restart Windows') -eq ($updateMode -eq 'fail-after-restart')) 'Failure diagnostics lost or invented a restart requirement.'
                }
            } else {
                Install-ClientTools
                $expected = if ($updateMode -eq 'restart') { 'RestartRequired' } elseif ($updateMode -in @('cancel','unconfigured')) { 'Cancelled' } else { 'Completed' }
                Assert-True ($script:OperationOutcome -eq $expected) "Expected $expected; got $($script:OperationOutcome)."
            }
            Assert-True (Test-Path -LiteralPath (Join-Path $fixture 'ndi-installed')) 'The post-NDI phase was not exercised.'
            Assert-True ($script:FixtureLaunches -eq $(if ($updateMode -in @('concurrent-newer','staged-corrupt')) { 0 } else { 1 })) 'Incorrect setup launch count.'
            if ($updateMode -like 'fail-after*') {
                $install = Join-Path $env:ProgramFiles 'NDI Configurator\PC Agent'
                Assert-True ((Get-PcAgentBinaryVersion (Join-Path $install 'NDI Configurator PC Agent.exe') 'NDI Configurator PC Agent') -eq '0.7.2' -and (Test-PcAgentConfigured)) 'Updated files/configuration were not present alongside the genuine failure.'
            }
            if ($updateMode -in @('success','fast','restart')) {
                Assert-True ((Get-PcAgentBinaryVersion (Join-Path $oldInstall 'NDI Configurator PC Agent.exe') 'NDI Configurator PC Agent') -eq '0.7.2') 'The older Agent was not replaced.'
                $after = Get-Content -LiteralPath (Join-Path $oldState 'agent-state.json') -Raw | ConvertFrom-Json
                Assert-True ($after.endpointId -eq $valid.endpointId -and $after.adapterId -eq $valid.adapterId) 'The update changed the saved PC identity.'
            }
        } finally {
            $env:ProgramFiles = $previousProgramFiles
            $env:KILOLINK_CLIENT_UPDATE_FIXTURE = $previousFixtureRoot
        }
    }
}
