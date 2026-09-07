# Loaded by Installer.Regression.ps1 after its NDI fixtures. Exercise the real
# server update orchestration, package preflight and NDI/KiloLink decisions;
# system operations remain isolated behind the existing fixture boundaries.
$serverUpdateMocks = {
    . $repairMocks
    . $ndiMocks
    foreach ($name in @('Install-NdiTools','Assert-ServerDownloads','Get-CurrentNdiToolsVersion')) {
        Invoke-Expression ($ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true).Extent.Text)
    }
    $Action = 'Update'
    $LauncherMode = $true
    $script:NdiInstalled = $true
    $script:ServerSteps = New-Object Collections.Generic.List[string]
    $script:FixtureImageChanged = $false
    Save-Config (New-Config)
    function Get-UbuntuDistro { 'KiloLink-Ubuntu' }
    function Invoke-RestMethod {
        param($Uri)
        Assert-True ($Uri -eq 'https://api.github.com/repos/microsoft/WSL/releases/latest') 'Unexpected server metadata source.'
        [pscustomobject]@{assets=@([pscustomobject]@{name='wsl.x64.msi';browser_download_url='https://example.invalid/wsl.x64.msi'})}
    }
    function Invoke-WebRequest {
        param($Uri)
        Assert-True ($Uri -eq 'https://ndi.video/tools/') 'Unexpected NDI metadata source.'
        $script:NdiVersionChecks++
        [pscustomobject]@{Links=@([pscustomobject]@{href=$script:NdiToolsUrl});Content='<div>Version 6.0.0</div>'}
    }
    function Ensure-WslFeatures { $script:ServerSteps.Add('Features'); $true }
    function Invoke-WslScript {
        param($Distro, $Script, [switch]$Capture)
        Assert-True ($Distro -eq 'KiloLink-Ubuntu') 'Update targeted a different Linux distribution.'
        if ($Script -match 'apt-get upgrade -y') { $script:ServerSteps.Add('Linux'); return }
        Assert-True ($Capture -and $Script -match 'docker pull "kiloview/klnk-pro:latest"') 'Unexpected Linux update script.'
        $script:ServerSteps.Add('Image')
        if ($script:FixtureImageChanged) { 'KILOLINK_UPDATE' } else { 'KILOLINK_CURRENT' }
    }
    function Configure-NdiServer { $script:ServerSteps.Add('Discovery') }
    function Test-SuiteHealth { $script:ServerSteps.Add('Health') }
    function Show-SuiteSummary { $script:ServerSteps.Add('Summary') }
}

Test-Case 'Full server updates keep current NDI and KiloLink without redundant downloads or replacement' {
    . $serverUpdateMocks
    Update-Suite
    Assert-True ($script:OperationOutcome -eq 'Completed' -and ($script:ServerSteps -join ',') -eq 'Features,Linux,Image,Discovery,Health,Summary') 'The full server update did not complete its ordered stages.'
    Assert-True ($script:NdiDownloads -eq 0 -and $script:NdiInstallCalls -eq 0 -and $script:Recreated -eq 0 -and $script:NdiVersionChecks -eq 1) 'Current server components were downloaded/replaced or NDI metadata was checked twice.'
    Update-Suite
    Assert-True ($script:NdiDownloads -eq 0 -and $script:NdiVersionChecks -eq 2) 'The next complete update reused stale metadata or downloaded current NDI.'
}
Test-Case 'Full server update installs older NDI once and replaces a changed KiloLink image' {
    . $serverUpdateMocks
    $script:FixtureImageChanged = $true
    function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='5.0.0'} }
    $before = Get-SavedConfig
    Update-Suite
    $after = Get-SavedConfig
    Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 1 -and $script:NdiSignatureChecks -eq 2 -and $script:Recreated -eq 1) 'The full update lost single-download staging, signature verification, or image replacement.'
    Assert-True ($after.LinuxDataPath -eq $before.LinuxDataPath -and $after.KiloLinkImage -eq $before.KiloLinkImage -and $after.PublicIp -eq $before.PublicIp -and $after.WebPort -eq $before.WebPort) 'The update changed saved server data, image, address or ports.'
    Assert-True ($script:OperationOutcome -eq 'Completed') 'The component upgrade was not completed.'
}
Test-Case 'Full server update uses one verified fallback when NDI metadata is unavailable' {
    . $serverUpdateMocks
    function Invoke-WebRequest { throw 'Fixture NDI metadata unavailable' }
    Update-Suite
    Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiSignatureChecks -eq 2 -and $script:NdiInstallCalls -eq 0 -and $script:OperationOutcome -eq 'Completed') 'The full update did not retain its verified package fallback.'
}
Test-Case 'Blocked NDI update download stops the full server operation before configuration or system changes' {
    . $serverUpdateMocks
    function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='5.0.0'} }
    function Download-FileWithProgress { throw 'Fixture NDI download blocked' }
    $before = [IO.File]::ReadAllText($script:ConfigPath)
    Assert-Throws { Update-Suite } 'Fixture NDI download blocked'
    Assert-True ($script:ServerSteps.Count -eq 0 -and $script:NdiInstallCalls -eq 0 -and $script:OperationOutcome -ne 'Completed') 'Server changes continued after a blocked download.'
    Assert-True ([IO.File]::ReadAllText($script:ConfigPath) -ceq $before) 'Failed preflight rewrote saved configuration.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:StateRoot 'installation-components.json'))) 'Failed preflight wrote a component receipt.'
}
Test-Case 'Linux upgrade failure prevents later NDI installation and successful completion' {
    . $serverUpdateMocks
    function Get-NdiRegistration { [pscustomobject]@{DisplayVersion='5.0.0'} }
    function Invoke-WslScript { throw 'Fixture Linux upgrade failed' }
    Assert-Throws { Update-Suite } 'Fixture Linux upgrade failed'
    Assert-True ($script:NdiDownloads -eq 1 -and $script:NdiInstallCalls -eq 0 -and $script:Recreated -eq 0 -and $script:OperationOutcome -ne 'Completed') 'The failed Linux update ran later component installations or reported success.'
    Assert-True (($script:ServerSteps -join ',') -eq 'Features') 'The failed update reached final service refresh or health checks.'
}
Test-Case 'Full server update cannot report completion when final service health fails' {
    . $serverUpdateMocks
    function Test-SuiteHealth { $script:ServerSteps.Add('Health'); throw 'Fixture service health failed' }
    Assert-Throws { Update-Suite } 'Fixture service health failed'
    Assert-True ($script:OperationOutcome -ne 'Completed' -and ($script:ServerSteps -join ',') -eq 'Features,Linux,Image,Discovery,Health') 'A failed final readiness check reached the success summary.'
}
Test-Case 'Full server update preserves restart-required status and defers later update stages' {
    . $serverUpdateMocks
    function Ensure-WslFeatures { Set-OperationOutcome 'RestartRequired' 'Fixture restart required'; $false }
    Update-Suite
    Assert-True ((Get-InstallerExitCode) -eq 3010 -and $script:OperationOutcome -eq 'RestartRequired' -and $script:ServerSteps.Count -eq 0 -and $script:NdiInstallCalls -eq 0) 'A prerequisite restart was hidden or later update stages ran before restart.'
}
Test-Case 'Server repair and update defer configuration until an NDI-required restart' {
    foreach ($mode in @('Repair','Update')) {
        . $serverUpdateMocks
        $Action = $mode
        function Install-NdiTools { param([switch]$PrepareOnly) $script:NdiRestartRequired = -not $PrepareOnly }
        function Request-RestartAndResume { Set-OperationOutcome 'RestartRequired' 'NDI restart fixture' }
        if ($mode -eq 'Repair') { Repair-Suite -UseSavedConfiguration -LicenseAccepted } else { Update-Suite }
        Assert-True ((Get-InstallerExitCode) -eq 3010 -and $script:OperationOutcome -eq 'RestartRequired' -and $script:ServerSteps -notcontains 'Discovery' -and $script:ServerSteps -notcontains 'Health' -and $script:ServerSteps -notcontains 'Summary') 'Server ignored an NDI restart requirement and reported configuration complete.'
    }
}
