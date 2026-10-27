#Requires -Version 5.1
# Release identity gates against isolated native/engine fixtures; no installer runs.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-release-metadata-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object Collections.Generic.List[object]
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
}
function New-Request([string]$Version){
    $directory=Join-Path $testRoot ([guid]::NewGuid().ToString('D'))
    New-Item -ItemType Directory -Path $directory|Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    Set-Acl -LiteralPath $directory -AclObject $acl
    $path=Join-Path $directory 'request.json'
    $data=@{schemaVersion=1;operationId=[IO.Path]::GetFileName($directory);productId='environment';action='inspect';requestedVersion=$Version;resultPath=(Join-Path $directory 'result.json');preserveData=$true}
    [IO.File]::WriteAllText($path,($data|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    return $path
}
foreach($case in @(
    @{Version='3.1.0';Channel='stable';Release='3.1.0';Valid=$true},
    @{Version='3.1.0';Channel='development';Release='3.1.0-dev.1';Valid=$true},
    @{Version='3.1.0';Channel='stable';Release='3.1.0-dev.1';Valid=$false},
    @{Version='3.1.0';Channel='development';Release='3.1.0';Valid=$false},
    @{Version='3.1.0';Channel='development';Release='3.2.0-dev.1';Valid=$false},
    @{Version='3.1.0-dev.1';Channel='development';Release='3.1.0-dev.1';Valid=$false},
    @{Version='3.1.0';Channel='unknown';Release='3.1.0';Valid=$false}
)){
    Test-Case "Build metadata $($case.Version) / $($case.Channel) / $($case.Release)" {
        $path=Join-Path $testRoot 'version.json'
        [IO.File]::WriteAllText($path,(@{version=$case.Version;channel=$case.Channel;releaseVersion=$case.Release}|ConvertTo-Json))
        $metadata=$null;$failure=$null
        try{$metadata=& (Join-Path $root 'Get-BuildVersion.ps1') -Path $path}catch{$failure=$_}
        Assert-True (([bool]$failure) -ne $case.Valid) 'Invalid channel metadata was accepted or valid metadata rejected.'
        if($case.Valid){Assert-True ($metadata.Version -ceq $case.Version -and $metadata.ReleaseVersion -ceq $case.Release) 'Version identity was changed.'}
    }
}
$flags=[Reflection.BindingFlags]'Static,NonPublic,Public'
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'launcher\LifecycleProtocol.cs'))) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\Provisioner\12-Lifecycle.ps1'),[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'Lifecycle source did not parse.'
$engine=[scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Extent.Text})) -join "`n")
foreach($version in @('3.1.0','3.1.0-dev.1')){
    $fixtureRoot=Join-Path $testRoot $version
    New-Item -ItemType Directory -Path $fixtureRoot|Out-Null
    $fixture=Join-Path $fixtureRoot 'ReleaseFixture.exe'
    $assemblyInfo=Join-Path $fixtureRoot 'Version.cs'
    [IO.File]::WriteAllText($assemblyInfo,('[assembly:System.Reflection.AssemblyVersion("3.1.0.0")][assembly:System.Reflection.AssemblyFileVersion("3.1.0.0")][assembly:System.Reflection.AssemblyInformationalVersion("{0}")]' -f $version))
    $compilerArguments=@('/nologo','/target:winexe','/reference:System.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',('/out:'+$fixture),$assemblyInfo)
    foreach($source in @('SetupLauncher.cs','SetupWizard.cs','SetupLayout.cs','SetupPackage.cs','LifecycleProtocol.cs','SetupLifecycle.cs')){$compilerArguments+=Join-Path $root ('launcher\'+$source)}
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" @compilerArguments
    Assert-True ($LASTEXITCODE -eq 0) 'Native release fixture compilation failed.'
    $assembly=[Reflection.Assembly]::LoadFile($fixture)
    $hostType=$assembly.GetType('KiloLink.Setup.SetupLauncher')
    $opposite=if($version -eq '3.1.0'){'3.1.0-dev.1'}else{'3.1.0'}
    foreach($requested in @($version,$opposite)){
        Test-Case "Native $version requested $requested" {
            $requestPath=New-Request $requested
            $hostType.GetField('LifecycleRequest',$flags).SetValue($null,$null)
            $failure=$null
            try{[void]$hostType.GetMethod('LoadLifecycle',$flags).Invoke($null,@(,[string[]]@('--lifecycle-request',$requestPath)))}catch{$failure=$_}
            $matches=$requested -ceq $version
            Assert-True (([bool]$failure) -ne $matches) 'Native requestedVersion gate crossed channels.'
            if(-not $matches){
                $result=Get-Content -LiteralPath (Join-Path (Split-Path $requestPath) 'result.json') -Raw|ConvertFrom-Json
                Assert-True ($result.outcome -eq 'blocked' -and $result.errorCode -eq 'version-mismatch') 'Native mismatch result is not actionable.'
            }
        }
        Test-Case "Engine $version requested $requested" {
            . $engine
            $LifecycleRequestPath=New-Request $requested
            $script:Lifecycle=$null;$script:ProductVersion=$version;$Action='Inspect';$Role='';$PurgeData=$false;$ConfirmRemoval=$false
            $script:LifecycleEffects=@();$script:LifecycleComponents=@();$script:ActiveJournal=$null
            $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:InstallerLogPath=''
            $failure=$null
            try{Initialize-Lifecycle}catch{$failure=$_}
            $matches=$requested -ceq $version
            Assert-True (([bool]$failure) -ne $matches) 'Engine requestedVersion gate crossed channels.'
            $result=$script:Lifecycle.ReadResult()
            Assert-True ($result.outcome -eq $(if($matches){'running'}else{'blocked'})) 'Engine version gate emitted the wrong outcome.'
            if(-not $matches){Assert-True ($result.errorCode -eq 'version-mismatch') 'Engine mismatch result is not actionable.'}
        }
    }
    Test-Case "Installed component reports $version with numeric file version" {
        . $engine
        $originalProgramFiles=$env:ProgramFiles
        try{
            $env:ProgramFiles=Join-Path $fixtureRoot 'ProgramFiles'
            $installed=Join-Path $env:ProgramFiles 'Kiloview\Environment Setup\Kiloview-Environment-Setup.exe'
            New-Item -ItemType Directory -Path (Split-Path $installed) -Force|Out-Null
            Copy-Item -LiteralPath $fixture -Destination $installed
            $script:ProductVersion=$version;$script:ProductChannel=if($version -match '-dev\.'){'development'}else{'stable'}
            $script:StateRoot=Join-Path $fixtureRoot 'state'
            function Get-NdiRegistration { throw 'Isolated fixture' }
            function Get-NdiDiscoveryService { throw 'Isolated fixture' }
            function Get-RegisteredManagedDistro { throw 'Isolated fixture' }
            function Get-PcAgentLifecycleEntry { throw 'Isolated fixture' }
            $component=@(Get-ObservedComponents|Where-Object productId -eq 'environment')[0]
            Assert-True ($component.installed -and $component.configurationAppInstalled -and $component.version -ceq $version -and $component.inspectionVersion -ceq $version) 'Installed product identity lost its release channel.'
            Assert-True ((Get-Item -LiteralPath $installed).VersionInfo.FileVersion -eq '3.1.0.0') 'Numeric Windows file identity changed.'
        }finally{$env:ProgramFiles=$originalProgramFiles}
    }
}
$passed=@($results|Where-Object{$_.Passed}).Count
Write-Output "$passed/$($results.Count) release metadata checks passed. Evidence: $testRoot"
if($passed -ne $results.Count){exit 1}
