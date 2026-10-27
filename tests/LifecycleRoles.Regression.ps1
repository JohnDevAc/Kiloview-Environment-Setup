#Requires -Version 5.1
# Native role/review regression with temp state and a read-only network fixture.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-role-routing-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$fixtureEngine=Join-Path $testRoot 'engine.ps1';[IO.File]::WriteAllText($fixtureEngine,'exit 0')
$fixtureExe=Join-Path $testRoot 'RoleFixture.exe'
$launcher=[IO.File]::ReadAllText((Join-Path $root 'launcher\SetupLauncher.cs'))
$start=$launcher.IndexOf('        private static List<NetworkAdapterChoice> GetNetworkAdapterChoices()')
$end=$launcher.IndexOf('        private void LoadNetworkAdapters()', $start)
Assert-True ($start -ge 0 -and $end -gt $start) 'Cannot isolate native network inventory.'
$launcher=$launcher.Substring(0,$start)+@'
        private static List<NetworkAdapterChoice> GetNetworkAdapterChoices() {
            return new List<NetworkAdapterChoice>{new NetworkAdapterChoice{Alias="Fixture Ethernet",Description="Owned fixture",Address="192.0.2.10",PrefixLength=24,Connected=true,Wired=true}};
        }

'@+$launcher.Substring($end)
$fixtureSource=Join-Path $testRoot 'SetupLauncher.cs';[IO.File]::WriteAllText($fixtureSource,$launcher)
$compilerArguments=@('/nologo','/target:winexe','/reference:System.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',('/out:'+$fixtureExe))
foreach($resource in @(@($fixtureEngine,'Install-KiloLinkSuite.ps1'),@((Join-Path $root 'launcher\QuietInstaller.cs'),'QuietInstaller.cs'),@((Join-Path $root 'LICENSE'),'LICENSE'),@((Join-Path $root 'EULA.md'),'EULA.md'),@((Join-Path $root 'THIRD_PARTY_NOTICES.md'),'THIRD_PARTY_NOTICES.md'),@((Join-Path $root 'assets\setup-icon.png'),'setup-icon.png'),@((Join-Path $root 'assets\setup.ico'),'setup.ico'))){$compilerArguments+='/resource:'+$resource[0]+',KiloLink.Setup.'+$resource[1]}
$compilerArguments+=$fixtureSource
foreach($source in @('SetupWizard.cs','SetupLayout.cs','SetupPackage.cs','LifecycleProtocol.cs','SetupLifecycle.cs')){$compilerArguments+=Join-Path $root ('launcher\'+$source)}
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" @compilerArguments
Assert-True ($LASTEXITCODE -eq 0) 'Native role fixture compilation failed.'
$assembly=[Reflection.Assembly]::LoadFile($fixtureExe)
$formType=$assembly.GetType('KiloLink.Setup.SetupForm')
$hostType=$assembly.GetType('KiloLink.Setup.SetupLauncher')
$requestType=$assembly.GetType('KiloLink.Lifecycle.Request')
$flags=[Reflection.BindingFlags]'Instance,NonPublic,Public'
$static=[Reflection.BindingFlags]'Static,NonPublic,Public'
$results=New-Object Collections.Generic.List[object]
foreach($case in @(
    @{Name='Partial Client retry';Choice='client';Roles=@('client');Explicit=$false},
    @{Name='Server retry';Choice='server';Roles=@('server');Explicit=$false},
    @{Name='Combined roles choosing Client';Choice='client';Roles=@('client','server');Explicit=$false},
    @{Name='Combined roles choosing Server';Choice='server';Roles=@('client','server');Explicit=$false},
    @{Name='Explicit Client repair';Choice='client';Roles=@('client','server');Explicit=$true},
    @{Name='Explicit Server repair';Choice='server';Roles=@('client','server');Explicit=$true},
    @{Name='Server removal selection and retained-data consent';Choice='server';Roles=@('client','server');Explicit=$false;Action='uninstall'},
    @{Name='Client removal selection and retained-tools consent';Choice='client';Roles=@('client','server');Explicit=$false;Action='remove-role'},
    @{Name='Explicit Server purge choice and fresh consent';Choice='server';Roles=@('client','server');Explicit=$true;Action='remove-role';Preserve=$false},
    @{Name='Standalone Server purge choice and fresh consent';Choice='server';Roles=@('server');Explicit=$true;Action='uninstall';Standalone=$true;Preserve=$false},
    @{Name='App-only removal has no purge option';Choice='server';Roles=@('client','server');Explicit=$false;Action='remove-app'}
)){
    $form=$null
    try{
        $directory=Join-Path $testRoot ([guid]::NewGuid().ToString('D'))
        New-Item -ItemType Directory -Path $directory|Out-Null
        $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
        foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
        Set-Acl -LiteralPath $directory -AclObject $acl
        $removal=$case.ContainsKey('Action')
        $data=@{schemaVersion=1;operationId=[IO.Path]::GetFileName($directory);productId='environment';action=$(if($removal){$case.Action}else{'repair'});resultPath=(Join-Path $directory 'result.json');preserveData=$true}
        if($case.ContainsKey('Preserve')){$data.preserveData=$case.Preserve}
        if($case.Explicit){$data.role=$case.Choice}
        $requestPath=Join-Path $directory 'request.json'
        [IO.File]::WriteAllText($requestPath,($data|ConvertTo-Json))
        $request=$requestType.GetMethod('Load',$static).Invoke($null,@([string]$requestPath))
        if($case.Standalone){$request=$null}
        $hostType.GetField('LifecycleRequest',$static).SetValue($null,$request)
        $hostType.GetField('LifecycleRequestHash',$static).SetValue($null,(Get-FileHash -LiteralPath $requestPath).Hash)
        $state=Join-Path $directory 'state';New-Item -ItemType Directory -Path $state|Out-Null
        [IO.File]::WriteAllText((Join-Path $state 'installation-components.json'),(@{schemaVersion=1;roles=$case.Roles}|ConvertTo-Json))
        if('server' -in $case.Roles){[IO.File]::WriteAllText((Join-Path $state 'installer-config.json'),(@{SchemaVersion=1;PrimaryInterfaceAlias='Fixture Ethernet';PublicIp='192.0.2.10';WebPort=80;LinkPort=50000;NdiDiscoveryPort=5959}|ConvertTo-Json))}
        $form=$formType.GetConstructor($flags,$null,@([bool]),$null).Invoke(@($false))
        $formType.GetField('launcherDirectory',$flags).SetValue($form,[string](Join-Path $state 'Launcher'))
        $form.Opacity=0;$form.ShowInTaskbar=$false;$form.Show();[Windows.Forms.Application]::DoEvents()
        if($case.Standalone){
            $formType.GetField('selectedAction',$flags).SetValue($form,'Uninstall')
            $formType.GetField('serverChoice',$flags).GetValue($form).Checked=$true
            [void]$formType.GetMethod('ReviewSelectedAction',$flags).Invoke($form,@())
        }
        if(-not $case.Explicit -and $case.Action -ne 'remove-app'){
            Assert-True ($formType.GetField('currentView',$flags).GetValue($form).ToString() -eq 'Role') 'Omitted role skipped owner selection.'
            if($removal){
                $roleText=($formType.GetField('rolePanel',$flags).GetValue($form).Controls|ForEach-Object {$_.Text}) -join ' '
                Assert-True ($roleText -match 'Which role do you want to remove' -and $roleText -notmatch 'How will this computer be used|Install the latest|Set up or update') 'Removal chooser still describes installation.'
            }
            $choice=$formType.GetField(($case.Choice+'Choice'),$flags).GetValue($form)
            $choice.GetType().GetMethod('OnClick',$flags).Invoke($choice,@([EventArgs]::Empty))|Out-Null
            [Windows.Forms.Application]::DoEvents()
            Assert-True $choice.Checked 'Radio selection was not accepted before Next.'
            $formType.GetField('roleNextButton',$flags).GetValue($form).PerformClick()
            [Windows.Forms.Application]::DoEvents()
        }
        $isClient=$case.Choice -eq 'client'
        $action=$formType.GetField('selectedAction',$flags).GetValue($form)
        $review=$formType.GetField('reviewText',$flags).GetValue($form).Text
        $consent=$formType.GetField('acceptanceBox',$flags).GetValue($form)
        if($removal){
            Assert-True ($action -eq $(if($case.Action -eq 'remove-app'){'RemoveApp'}else{'Uninstall'})) 'Removal routed to the wrong action.'
            Assert-True (($review -match "Client role record") -eq $isClient) 'Removal review crossed roles.'
            Assert-True ($review -match $(if($isClient){'Shared NDI Tools and PC Agent remain'}elseif($case.Action -eq 'remove-app'){'Remove only the Kiloview Configuration application'}else{'keep data/environment'})) 'Default removal retention is missing.'
            $purge=$formType.GetField('purgeBox',$flags).GetValue($form)
            $purgeAvailable=$action -eq 'Uninstall' -and -not $isClient -and ($case.Standalone -or -not $data.preserveData)
            Assert-True ($purge.Visible -eq $purgeAvailable) 'Unavailable purge control is still rendered, or an authorised choice is hidden.'
            Assert-True (($review -match 'separate checkbox below') -eq $purgeAvailable) 'Review promises an unavailable purge choice.'
            Assert-True (($consent.Text -match 'permanent data deletion') -eq $purgeAvailable) 'Consent references unavailable data deletion.'
            Assert-True (-not $purge.Checked -and -not $consent.Checked -and -not $formType.GetField('purgeConfirmed',$flags).GetValue($form)) 'Review reused purge choice or acceptance.'
            $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
            try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save((Join-Path $directory 'removal-review.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
            [IO.File]::WriteAllText((Join-Path $directory 'removal-review.json'),(@{case=$case.Name;requestPreservesData=$data.preserveData;standalone=[bool]$case.Standalone;review=$review;purgeVisible=$purge.Visible;purgeEnabled=$purge.Enabled;purgeChecked=$purge.Checked;consent=$consent.Text}|ConvertTo-Json))
            if($purgeAvailable){
                Assert-True $purge.Enabled 'Available purge choice is disabled.'
                $consent.Checked=$true;$purge.Checked=$true
                Assert-True (-not $consent.Checked -and -not $formType.GetField('executeButton',$flags).GetValue($form).Enabled) 'Changing to purge reused previous acceptance.'
                $blocked=$false
                try{[void]$formType.GetMethod('BuildOperationArguments',$flags).Invoke($form,@())}catch{$blocked=$true}
                Assert-True $blocked 'Purge dispatch did not require fresh acceptance.'
                $consent.Checked=$true
                $purgeArguments=$formType.GetMethod('BuildOperationArguments',$flags).Invoke($form,@())
                Assert-True ($purgeArguments -match '-PurgeData' -and $purgeArguments -match '-ConfirmRemoval') 'Explicit purge choice was not dispatched after fresh acceptance.'
                [void]$formType.GetMethod('ReviewSelectedAction',$flags).Invoke($form,@())
                Assert-True (-not $purge.Checked -and -not $consent.Checked -and -not $formType.GetField('purgeConfirmed',$flags).GetValue($form)) 'Reopening review retained destructive choice or acceptance.'
            }
        }else{
            Assert-True ($action -eq $(if($isClient){'InstallClient'}else{'Repair'})) 'Reviewed role was routed to the wrong engine action.'
            Assert-True (($consent.Text -match 'this client') -eq $isClient) 'Consent describes the wrong role.'
            Assert-True (($review -match 'saved server configuration') -eq (-not $isClient)) 'Review describes the wrong repair scope.'
        }
        $consent.Checked=$true
        $arguments=$formType.GetMethod('BuildOperationArguments',$flags).Invoke($form,@())
        $arguments=$formType.GetMethod('AddLifecycleArguments',$flags).Invoke($form,@($arguments))
        Assert-True ($arguments -match ('-Role '+$case.Choice+'(?:\s|$)')) 'Dispatch lost the reviewed role.'
        if($removal){Assert-True ($arguments -match ('-Action '+$action) -and $arguments -notmatch '-PurgeData') 'Default removal dispatch lost retention.'}
        else{Assert-True (($arguments -match '-Action InstallClient') -eq $isClient) 'Client retry dispatches server provisioning.'}
        if(-not $case.Standalone){
            $intent=Get-Content -LiteralPath (Join-Path $directory 'intent.json') -Raw|ConvertFrom-Json
            Assert-True ($intent.role -eq $case.Choice -and $intent.engineAction -eq $action -and -not $intent.purgeData) 'Reviewed intent crossed roles or retained a stale purge choice.'
        }
        $formType.GetMethod('FinishWizardOperation',$flags).Invoke($form,@([int]1))|Out-Null
        if(-not $case.Standalone){Assert-True (-not $formType.GetField('returnButton',$flags).GetValue($form).Visible) 'Unavailable lifecycle Back to setup control remains visible.'}
        $results.Add(@{Name=$case.Name;Passed=$true});Write-Host ('PASS '+$case.Name)
    }catch{$results.Add(@{Name=$case.Name;Passed=$false});Write-Host ('FAIL '+$case.Name+': '+$_.Exception.Message);Write-Host $_.ScriptStackTrace}
    finally{if($form){$form.Dispose()};$hostType.GetField('LifecycleRequest',$static).SetValue($null,$null);[Environment]::ExitCode=0}
}
$passed=@($results|Where-Object{$_.Passed}).Count
Write-Output "$passed/$($results.Count) role-routing checks passed. Evidence: $testRoot"
if($passed -ne $results.Count){exit 1}
