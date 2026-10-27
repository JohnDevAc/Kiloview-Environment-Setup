# Use the exact launcher sources but replace the embedded engine with a harmless
# marker writer. Even a broken busy guard cannot invoke a real install/network task.
$operationFixtureRoot = Join-Path $testRoot 'operation-fixture'
New-Item -ItemType Directory -Path $operationFixtureRoot | Out-Null
$fixtureEngine = Join-Path $operationFixtureRoot 'fixture-engine.ps1'
$payload = @'
param($Action,[switch]$AcceptLicenses,[switch]$LauncherMode,$LogPath,$ConfigurationPath,$LifecycleRequestPath,$Role,[switch]$PackageRestartContinuation)
Add-Content -LiteralPath $LogPath -Value 'OWNED_FIXTURE_RUN'
if($LifecycleRequestPath){
    $request=Get-Content -LiteralPath $LifecycleRequestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $outcome=if($PackageRestartContinuation){'restart-required'}else{'succeeded'}
    $result=@{schemaVersion=1;operationId=$request.operationId;productId='environment';action=$request.action;outcome=$outcome;updatedUtc=[datetime]::UtcNow.ToString('o');message='Owned fixture completed';attempt=1}
    [IO.File]::WriteAllText($request.resultPath,($result|ConvertTo-Json))
    if($PackageRestartContinuation){[Console]::Out.WriteLine('@@KILOVIEW_EVENT@@{"type":"outcome","outcome":"RestartRequired","message":"Owned continuation fixture."}');exit 3010}
}
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
    @((Join-Path $root 'EULA.md'),'EULA.md'),
    @((Join-Path $root 'THIRD_PARTY_NOTICES.md'),'THIRD_PARTY_NOTICES.md'),
    @((Join-Path $root 'assets\setup-icon.png'),'setup-icon.png'),
    @((Join-Path $root 'assets\setup.ico'),'setup.ico')
)) { $compilerArguments += '/resource:' + $resource[0] + ',KiloLink.Setup.' + $resource[1] }
$fixtureLifecycleSource=Join-Path $operationFixtureRoot 'SetupLifecycle.cs'
$lifecycleCode=[IO.File]::ReadAllText((Join-Path $root 'launcher\SetupLifecycle.cs'))
$maintenanceStart=$lifecycleCode.IndexOf('        private void EnsureRetainedMaintenance()')
$maintenanceEnd=$lifecycleCode.IndexOf('        private void CompleteLifecycle(', $maintenanceStart)
Assert-True ($maintenanceStart -ge 0 -and $maintenanceEnd -gt $maintenanceStart) 'Cannot isolate the privileged maintenance filesystem boundary.'
$lifecycleCode=$lifecycleCode.Substring(0,$maintenanceStart)+"        private void EnsureRetainedMaintenance() { Directory.CreateDirectory(launcherDirectory); SetupLauncher.ExtractInstaller(installerPath); }`r`n"+$lifecycleCode.Substring($maintenanceEnd)
[IO.File]::WriteAllText($fixtureLifecycleSource,$lifecycleCode)
foreach ($sourceName in @('SetupLauncher.cs','SetupWizard.cs','SetupLayout.cs','SetupPackage.cs','LifecycleProtocol.cs')) { $compilerArguments += Join-Path $root ('launcher\' + $sourceName) }
$compilerArguments += $fixtureLifecycleSource
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
            installerPath { Join-Path $staging 'Install-KiloLinkSuite.ps1' }
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
            [void]$operationFormType.GetMethod('ContinueNetworkButtonClick',$instanceFlags).Invoke($form,@($null,[EventArgs]::Empty))
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
