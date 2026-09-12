# Loaded after the compiled form and network mocks are available.
Test-Case 'Network rollback preserves independent address and DNS assignment modes' {
    foreach ($dhcp in @('Enabled','Disabled')) {
        foreach ($manualDns in @($false,$true)) {
            foreach ($addressState in @('Duplicate','Tentative')) {
                . $networkMocks
                $script:AddressState = $addressState
                $script:RestoredDhcp = $null; $script:RestoredDns = $null; $script:RestoredAddress = $null
                function Get-NetIPInterface { [pscustomobject]@{Dhcp=$dhcp} }
                function Get-ItemProperty { if ($manualDns) { [pscustomobject]@{NameServer='192.0.2.53, 192.0.2.54'} } else { [pscustomobject]@{} } }
                function Set-NetIPInterface { param($InterfaceIndex,$AddressFamily,$Dhcp) $script:RestoredDhcp=$Dhcp }
                function Set-DnsClientServerAddress {
                    param($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses)
                    $script:RestoredDns = if ($ResetServerAddresses) { 'Automatic' } else { $ServerAddresses -join ',' }
                }
                function New-NetIPAddress { param($IPAddress) $script:RestoredAddress=$IPAddress; $script:NetworkApplied=$true }
                Assert-Throws { & ([scriptblock]::Create($networkScript)) } 'already in use|did not become usable'
                Assert-True ($script:RestoredDhcp -eq $dhcp) 'The original address assignment mode was lost.'
                $expectedDns = if ($manualDns) { '192.0.2.53,192.0.2.54' } else { 'Automatic' }
                Assert-True ($script:RestoredDns -eq $expectedDns) "DNS rollback lost $expectedDns while DHCP was $dhcp."
                if ($dhcp -eq 'Disabled') { Assert-True ($script:RestoredAddress -eq '192.0.2.10') 'Original static address was not restored.' }
            }
        }
    }
}

Test-Case 'Unreadable DNS mode fails before network mutation and failed DNS restore is reported' {
    . $networkMocks
    function Get-ItemProperty { throw 'Fixture DNS snapshot denied' }
    function Set-NetIPInterface { throw 'Network mutation started without a snapshot' }
    Assert-Throws { & ([scriptblock]::Create($networkScript)) } 'Fixture DNS snapshot denied'
    Assert-True (-not $script:NetworkApplied) 'Snapshot failure changed the address.'
    . $networkMocks
    $script:AddressState = 'Duplicate'
    function Set-DnsClientServerAddress {
        param($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses)
        if ($ResetServerAddresses) { throw 'Fixture DNS restore denied' }
    }
    Assert-Throws { & ([scriptblock]::Create($networkScript)) } 'Rollback also failed: Fixture DNS restore denied'
}

# Use the exact launcher sources but replace the embedded engine with a harmless
# marker writer. Even a broken busy guard cannot invoke a real install/network task.
$operationFixtureRoot = Join-Path $testRoot 'operation-fixture'
New-Item -ItemType Directory -Path $operationFixtureRoot | Out-Null
$fixtureEngine = Join-Path $operationFixtureRoot 'fixture-engine.ps1'
$payload = @'
param($Action,[switch]$AcceptLicenses,[switch]$LauncherMode,$LogPath,$ConfigurationPath)
Add-Content -LiteralPath $LogPath -Value 'OWNED_FIXTURE_RUN'
[Console]::Out.WriteLine('@@KILOVIEW_EVENT@@{"type":"outcome","outcome":"Completed","message":"Owned fixture completed."}')
exit 0
'@
[IO.File]::WriteAllText($fixtureEngine,$payload)
$fixtureExe = Join-Path $operationFixtureRoot 'OperationFixture.exe'
$compilerArguments = @('/nologo','/target:winexe','/reference:System.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',('/out:' + $fixtureExe))
foreach ($resource in @(
    @($fixtureEngine,'Install-KiloLinkSuite.ps1'),
    @((Join-Path $root 'launcher\QuietInstaller.cs'),'QuietInstaller.cs'),
    @((Join-Path $root 'LICENSE'),'LICENSE'),
    @((Join-Path $root 'THIRD_PARTY_NOTICES.md'),'THIRD_PARTY_NOTICES.md'),
    @((Join-Path $root 'assets\setup-icon.png'),'setup-icon.png'),
    @((Join-Path $root 'assets\setup.ico'),'setup.ico')
)) { $compilerArguments += '/resource:' + $resource[0] + ',KiloLink.Setup.' + $resource[1] }
foreach ($sourceName in @('SetupLauncher.cs','SetupWizard.cs','SetupLayout.cs')) { $compilerArguments += Join-Path $root ('launcher\' + $sourceName) }
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" @compilerArguments
Assert-True ($LASTEXITCODE -eq 0) 'Harmless operation fixture compilation failed.'
$operationAssembly = [Reflection.Assembly]::LoadFile($fixtureExe)
$operationFormType = $operationAssembly.GetType('KiloLink.Setup.SetupForm')
function New-OperationFixtureForm {
    $form = $operationFormType.GetConstructor($instanceFlags,$null,@([bool]),$null).Invoke(@($false))
    $staging = Join-Path $operationFixtureRoot ([guid]::NewGuid().ToString('N'))
    foreach ($field in @('launcherDirectory','persistentLauncherPath','legacyPersistentLauncherPath','installerPath','logPath')) {
        $value = switch ($field) {
            launcherDirectory { $staging }
            persistentLauncherPath { Join-Path $staging 'persisted.exe' }
            legacyPersistentLauncherPath { Join-Path $staging 'legacy.exe' }
            installerPath { Join-Path $staging 'engine.ps1' }
            logPath { Join-Path $staging 'fixture.log' }
        }
        Assert-True ($value.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture staging path.'
        $operationFormType.GetField($field,$instanceFlags).SetValue($form,$value)
    }
    $form.Opacity=0; $form.ShowInTaskbar=$false; $form.Show()
    return $form
}
function Wait-OperationFixture($Form) {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    do {
        [Windows.Forms.Application]::DoEvents()
        if (-not $operationFormType.GetField('installerOperationInProgress',$instanceFlags).GetValue($Form)) { return }
        Start-Sleep -Milliseconds 20
    } while ([datetime]::UtcNow -lt $deadline)
    throw 'Owned operation fixture did not finish.'
}
$click = [Windows.Forms.Button].GetMethod('OnClick',$instanceFlags)
Test-Case 'Active network worker blocks Back, queued clicks, role changes and installer launch' {
    $form = New-OperationFixtureForm
    try {
        [void]$operationFormType.GetMethod('ShowNetworkPage',$instanceFlags).Invoke($form,@())
        $operationFormType.GetField('networkConfigurationInProgress',$instanceFlags).SetValue($form,$true)
        [void]$operationFormType.GetMethod('SetNetworkControlsEnabled',$instanceFlags).Invoke($form,@($false))
        $back = $operationFormType.GetField('networkCloseButton',$instanceFlags).GetValue($form)
        Assert-True (-not $back.Enabled) 'Back is enabled during network configuration.'
        $click.Invoke($back,@([EventArgs]::Empty)) | Out-Null
        foreach ($method in @('ShowHome','ChooseRole','ShowServerHome','BeginSelectedAction','ShowNetworkPage','ReviewSelectedAction','ShowProgressView','StartInstaller')) {
            [void]$operationFormType.GetMethod($method,$instanceFlags).Invoke($form,@())
        }
        foreach ($method in @('ApplyNetworkButtonClick','SkipNetworkButtonClick')) {
            [void]$operationFormType.GetMethod($method,$instanceFlags).Invoke($form,@($null,[EventArgs]::Empty))
        }
        $operationFormType.GetField('acceptanceBox',$instanceFlags).GetValue($form).Checked = $true
        $execute = $operationFormType.GetField('executeButton',$instanceFlags).GetValue($form)
        Assert-True (-not $execute.Enabled) 'Acceptance enabled execution during network work.'
        $click.Invoke($execute,@([EventArgs]::Empty)) | Out-Null
        Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Network') 'A busy navigation handler changed the page.'
        Assert-True ($operationFormType.GetField('selectedAction',$instanceFlags).GetValue($form) -eq 'Install') 'A busy handler changed the action.'
        Assert-True ($null -eq $operationFormType.GetField('installerProcess',$instanceFlags).GetValue($form)) 'A second operation started.'
        Assert-True (-not (Test-Path -LiteralPath $operationFormType.GetField('launcherDirectory',$instanceFlags).GetValue($form))) 'Blocked operation staged files.'
    } finally { Wait-OperationFixture $form; $form.Dispose() }
}

Test-Case 'Stale network completion is ignored and current completion restores normal navigation' {
    $form = New-OperationFixtureForm
    try {
        [void]$operationFormType.GetMethod('ShowNetworkPage',$instanceFlags).Invoke($form,@())
        $operationFormType.GetField('networkConfigurationInProgress',$instanceFlags).SetValue($form,$true)
        $operationFormType.GetField('networkOperationGeneration',$instanceFlags).SetValue($form,2)
        [void]$operationFormType.GetMethod('SetNetworkControlsEnabled',$instanceFlags).Invoke($form,@($false))
        $complete = $operationFormType.GetMethod('CompleteNetworkConfiguration',$instanceFlags)
        [void]$complete.Invoke($form,@(1,'Old adapter','192.0.2.1','stale',$null))
        Assert-True ($operationFormType.GetField('networkConfigurationInProgress',$instanceFlags).GetValue($form)) 'Stale callback released the active worker.'
        Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Network') 'Stale callback navigated the form.'
        [void]$complete.Invoke($form,@(2,'Fixture Ethernet','192.0.2.20','done',$null))
        Assert-True (-not $operationFormType.GetField('networkConfigurationInProgress',$instanceFlags).GetValue($form)) 'Completion did not release busy state.'
        Assert-True ($operationFormType.GetField('networkCloseButton',$instanceFlags).GetValue($form).Enabled) 'Back was not restored.'
        Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Settings') 'Current completion did not advance.'
        [void]$operationFormType.GetMethod('ShowHome',$instanceFlags).Invoke($form,@())
        Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Role') 'Navigation did not recover.'
    } finally { $form.Dispose() }
}

Test-Case 'Installer ownership blocks overlapping work and releases after real harmless completion' {
    $form = New-OperationFixtureForm
    try {
        foreach ($run in @(1,2)) {
            $operationFormType.GetField('clientChoice',$instanceFlags).GetValue($form).Checked = $true
            [void]$operationFormType.GetMethod('ChooseRole',$instanceFlags).Invoke($form,@())
            $operationFormType.GetField('acceptanceBox',$instanceFlags).GetValue($form).Checked = $true
            $execute = $operationFormType.GetField('executeButton',$instanceFlags).GetValue($form)
            Assert-True $execute.Enabled 'Normal/retry execution was not restored.'
            $click.Invoke($execute,@([EventArgs]::Empty)) | Out-Null
            Assert-True ($operationFormType.GetField('installerOperationInProgress',$instanceFlags).GetValue($form)) 'Worker ownership was not acquired.'
            $first = $operationFormType.GetField('installerProcess',$instanceFlags).GetValue($form)
            [void]$operationFormType.GetMethod('ShowHome',$instanceFlags).Invoke($form,@())
            [void]$operationFormType.GetMethod('StartInstaller',$instanceFlags).Invoke($form,@())
            [void]$operationFormType.GetMethod('ApplyNetworkButtonClick',$instanceFlags).Invoke($form,@($null,[EventArgs]::Empty))
            $click.Invoke($execute,@([EventArgs]::Empty)) | Out-Null
            Assert-True ([Object]::ReferenceEquals($first,$operationFormType.GetField('installerProcess',$instanceFlags).GetValue($form))) 'A queued click replaced the active worker.'
            Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Progress') 'Navigation escaped an active installation.'
            Wait-OperationFixture $form
            $log = $operationFormType.GetField('logPath',$instanceFlags).GetValue($form)
            Assert-True (@(Get-Content -LiteralPath $log | Where-Object { $_ -eq 'OWNED_FIXTURE_RUN' }).Count -eq $run) 'A duplicate worker ran or a retry was lost.'
            [void]$operationFormType.GetMethod('ShowHome',$instanceFlags).Invoke($form,@())
            Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Role') 'Completed worker kept navigation blocked.'
        }
    } finally { Wait-OperationFixture $form; $form.Dispose(); [Environment]::ExitCode=0 }
}
