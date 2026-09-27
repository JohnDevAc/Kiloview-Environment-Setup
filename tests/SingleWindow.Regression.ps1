# Loaded by the isolated native harness. The embedded package is a harmless
# executable that only records arguments and returns the requested fixture code.
$singleRoot = Join-Path $testRoot 'single-window'
$installedFixture = Join-Path $singleRoot 'installed'
New-Item -ItemType Directory -Path $installedFixture -Force | Out-Null
$escapedRoot = $singleRoot.Replace('\','\\').Replace('"','\"')
$fakePackageSource = @'
using System;
using System.IO;
class PackageFixture {
    static int Main(string[] args) {
        string root = "__ROOT__";
        string command = String.Join(" ", args);
        File.AppendAllText(Path.Combine(root,"package-runs.log"), command + Environment.NewLine);
        if (!command.Contains("/repair /quiet /norestart /log")) return 87;
        System.Threading.Thread.Sleep(150);
        return Int32.Parse(File.ReadAllText(Path.Combine(root,"exit-code.txt")));
    }
}
'@
$fakePackageCs = Join-Path $singleRoot 'PackageFixture.cs'
$fakePackageExe = Join-Path $singleRoot 'PackageFixture.exe'
[IO.File]::WriteAllText($fakePackageCs, $fakePackageSource.Replace('__ROOT__',$escapedRoot))
$compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $compiler /nologo /target:winexe ("/out:$fakePackageExe") $fakePackageCs
Assert-True ($LASTEXITCODE -eq 0) 'Package fixture did not compile.'
$fixturePackageSource = Join-Path $singleRoot 'SetupPackage.cs'
$packageSource = [IO.File]::ReadAllText((Join-Path $root 'launcher\SetupPackage.cs'))
$originalDirectory = 'return Path.Combine(Environment.GetEnvironmentVariable("ProgramW6432") ?? Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Kiloview", "Environment Setup");'
Assert-True ($packageSource.Contains($originalDirectory)) 'Fixture must replace the production installation directory before use.'
$packageSource = $packageSource.Replace($originalDirectory, 'return "' + $installedFixture.Replace('\','\\') + '";')
[IO.File]::WriteAllText($fixturePackageSource,$packageSource)
$singleExe = Join-Path $singleRoot 'SingleWindowFixture.exe'
$argsList = @('/nologo','/target:winexe','/reference:System.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',('/out:' + $singleExe))
foreach ($resource in @(
    @($fakePackageExe,'ConfigurationPackage.exe'), @($fixtureEngine,'Install-KiloLinkSuite.ps1'),
    @((Join-Path $root 'launcher\QuietInstaller.cs'),'QuietInstaller.cs'),
    @((Join-Path $root 'LICENSE'),'LICENSE'), @((Join-Path $root 'EULA.md'),'EULA.md'),
    @((Join-Path $root 'THIRD_PARTY_NOTICES.md'),'THIRD_PARTY_NOTICES.md'),
    @((Join-Path $root 'assets\setup-icon.png'),'setup-icon.png'), @((Join-Path $root 'assets\setup.ico'),'setup.ico')
)) { $argsList += '/resource:' + $resource[0] + ',KiloLink.Setup.' + $resource[1] }
foreach ($name in @('SetupLauncher.cs','SetupWizard.cs','SetupLayout.cs')) { $argsList += Join-Path $root ('launcher\' + $name) }
$argsList += $fixturePackageSource
& $compiler @argsList
Assert-True ($LASTEXITCODE -eq 0) 'Single-window fixture did not compile.'
Copy-Item -LiteralPath $singleExe -Destination (Join-Path $installedFixture 'Kiloview-Environment-Setup.exe')
Copy-Item -LiteralPath $fixtureEngine -Destination (Join-Path $installedFixture 'Install-KiloLinkSuite.ps1')
Copy-Item -LiteralPath (Join-Path $root 'launcher\QuietInstaller.cs') -Destination $installedFixture
Set-Content -LiteralPath (Join-Path $installedFixture 'managed-installation.json') -Value '{"installer":"msi"}'
$singleAssembly = [Reflection.Assembly]::LoadFile($singleExe)
$operationFormType = $singleAssembly.GetType('KiloLink.Setup.SetupForm')

foreach ($fixtureExit in @(0,1,3010)) {
    Test-Case "Single-window package stage handles exit $fixtureExit before provisioning" {
        Set-Content -LiteralPath (Join-Path $singleRoot 'exit-code.txt') -Value $fixtureExit
        $form = New-OperationFixtureForm
        try {
            $operationFormType.GetField('clientChoice',$instanceFlags).GetValue($form).Checked = $true
            [void]$operationFormType.GetMethod('ChooseRole',$instanceFlags).Invoke($form,@())
            $operationFormType.GetField('acceptanceBox',$instanceFlags).GetValue($form).Checked = $true
            $execute = $operationFormType.GetField('executeButton',$instanceFlags).GetValue($form)
            $click.Invoke($execute,@([EventArgs]::Empty)) | Out-Null
            $first = $operationFormType.GetField('installerProcess',$instanceFlags).GetValue($form)
            [void]$operationFormType.GetMethod('ShowHome',$instanceFlags).Invoke($form,@())
            [void]$operationFormType.GetMethod('StartInstaller',$instanceFlags).Invoke($form,@())
            Assert-True ([Object]::ReferenceEquals($first,$operationFormType.GetField('installerProcess',$instanceFlags).GetValue($form))) 'A second click overlapped Windows package work.'
            Wait-OperationFixture $form
            $log = $operationFormType.GetField('logPath',$instanceFlags).GetValue($form)
            $outcome = $operationFormType.GetField('operationOutcome',$instanceFlags).GetValue($form)
            if ($fixtureExit -eq 0) {
                Assert-True ($outcome -eq 'Completed' -and (Get-Content -LiteralPath $log) -eq 'OWNED_FIXTURE_RUN') 'Successful package setup did not continue directly to provisioning.'
                Assert-True ($operationFormType.GetField('managedInstallation',$instanceFlags).GetValue($form)) 'Worker did not use installed files.'
            } else {
                Assert-True (-not (Test-Path -LiteralPath $log)) 'Failed or restart-required package setup still ran provisioning.'
                $expected = if ($fixtureExit -eq 3010) { 'RestartRequired' } else { 'Failed' }
                Assert-True ($outcome -eq $expected) 'Package result was hidden.'
                if ($fixtureExit -eq 3010) {
                    $message = $operationFormType.GetField('progressStatusLabel',$instanceFlags).GetValue($form).Text
                    Assert-True ($message -match 'reopen this installer' -and $message -notmatch 'sign back in to continue') 'Package restart falsely promised automatic continuation.'
                }
            }
            Assert-True ($operationFormType.GetField('currentView',$instanceFlags).GetValue($form).ToString() -eq 'Progress') 'The package stage switched to a second wizard.'
        } finally { Wait-OperationFixture $form; $form.Dispose(); [Environment]::ExitCode = 0 }
    }
}
Test-Case 'Installed payload mismatch is rejected before service provisioning' {
    $type = $singleAssembly.GetType('KiloLink.Setup.SetupPackage')
    $enginePath = Join-Path $installedFixture 'Install-KiloLinkSuite.ps1'
    Set-Content -LiteralPath $enginePath -Value 'wrong payload'
    try { Assert-Throws { $type.GetMethod('ValidateInstallation',$staticFlags).Invoke($null,@([string]$installedFixture)) } 'incomplete' }
    finally { Copy-Item -LiteralPath $fixtureEngine -Destination $enginePath -Force }
}
