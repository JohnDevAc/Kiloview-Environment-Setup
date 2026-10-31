#Requires -Version 5.1
# Isolated policy/path/WSL-argument tests. The only real host probe reads capacity.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-storage-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Pattern){
    $failure='';try{& $Body|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-True ($failure -match $Pattern) "Expected '$Pattern', received '$failure'."
}
function Import-Functions([string]$Name){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('src\Provisioner\'+$Name)),[ref]$tokens,[ref]$errors)
    Assert-True (-not $errors.Count) ('Parse failed: '+$Name)
    [scriptblock]::Create((@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object {$_.Extent.Text})) -join "`n")
}
$storage=Import-Functions '35-Storage.ps1'
$linux=Import-Functions '40-Linux.ps1'
$core=Import-Functions '10-Core.ps1'
Add-Type -Path (Join-Path $root 'launcher\LifecycleProtocol.cs') -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
function Test-Case([string]$Name,[scriptblock]$Body){
    try{& {
        . $storage
        $script:ManagedDistroName='KiloLink-Ubuntu';$script:PlannedDistroPath=$null
        $script:StateRoot='C:\fixture-state';$script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:LifecycleRecoveryRequired=$false
        $script:Logs=New-Object 'Collections.Generic.List[string]'
        function Write-InstallerLog([string]$Message){$script:Logs.Add($Message)}
        function Get-WslStorageRegistrations {@()}
        function Get-NdiToolsRoots {@()}
        function Get-PropertyValue($Object,$Name,$Default){if($Object.PSObject.Properties[$Name]){$Object.$Name}else{$Default}}
        function Invoke-Native {throw 'Unexpected native command'}
        & $Body
    };$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}
    catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}
}
$config=[pscustomobject]@{DistroName='KiloLink-Ubuntu'}
Test-Case 'Native Windows probe resolves a nonexistent child to real available host capacity' {
    $space=Get-WindowsStorageVolume (Join-Path $testRoot 'future\distro')
    Assert-True ($space.VolumeId -match '^\\\\\?\\Volume\{' -and $space.VolumePath -and $space.AvailableBytes -gt 0) 'Native volume identity or available-to-caller was missing.'
    $direct=[KiloLink.Storage.VolumeProbe]::Read($testRoot)
    Assert-True ($direct.VolumeId -eq $space.VolumeId -and [Math]::Abs([decimal]$direct.AvailableBytes-$space.AvailableBytes) -lt 1GB) 'Nearest ancestor changed the volume or capacity.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'future'))) 'Capacity probing created a directory.'
}
Test-Case 'Extended drive prefixes normalize without falling back to the boot drive' {
    foreach($path in @('C:\data\wsl','\\?\C:\data\wsl','\??\C:\data\wsl')){
        Assert-True ((Get-LocalStoragePath $path) -eq 'C:\data\wsl') ('Wrong normalized path: '+$path)
    }
    foreach($path in @('relative','C:relative','\\server\share','\\?\Volume{unknown}\','\Device\HarddiskVolume1')){
        Assert-Throws {Get-LocalStoragePath $path} 'absolute local drive'
    }
}
Test-Case 'Native capacity resolves a junction while new distro creation refuses that parent' {
    $target=Join-Path $testRoot 'junction-target';$link=Join-Path $testRoot 'junction'
    New-Item -ItemType Directory -Path $target|Out-Null
    New-Item -ItemType Junction -Path $link -Target $target|Out-Null
    $direct=Get-WindowsStorageVolume $target;$throughLink=Get-WindowsStorageVolume (Join-Path $link 'future')
    Assert-True ($direct.VolumeId -eq $throughLink.VolumeId) 'Probe did not resolve the junction volume.'
    $script:PlannedDistroPath=Join-Path $link 'new-distro'
    function Invoke-Native {$global:LASTEXITCODE=0;'--location'}
    function Initialize-LifecycleProtocol {}
    Assert-Throws {Get-NewWslInstallArguments} 'unsupported link|reparse'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'new-distro'))) 'Untrusted parent was used for installation.'
}
Test-Case 'Planning a new distro is stable within an attempt and writes nothing' {
    $first=Get-NewManagedDistroPath;$second=Get-NewManagedDistroPath
    Assert-True ($first -eq $second -and $first -like ($env:LOCALAPPDATA+'\Kiloview Environment Setup\WSL\KiloLink-Ubuntu-*')) 'Planned storage location was unstable or outside its owner root.'
    Assert-True (-not (Test-Path -LiteralPath $first)) 'Planning created a distro folder.'
    $script:PlannedDistroPath=$null
    Assert-True ((Get-NewManagedDistroPath) -ne $first) 'A new attempt reused an orphan-prone fixed folder.'
}
Test-Case 'Preferred and fallback registered distros retain their actual moved paths' {
    function Get-WslStorageRegistrations { @([pscustomobject]@{Name='Moved';Path='D:\VMs\Moved'},[pscustomobject]@{Name='KiloLink-Ubuntu';Path='E:\Retained'}) }
    $targets=@(Get-ServerStorageTargets ([pscustomobject]@{DistroName='Moved'}))
    Assert-True ($targets[0].Path -eq 'D:\VMs\Moved') 'Preferred moved distro was replaced.'
    $targets=@(Get-ServerStorageTargets ([pscustomobject]@{DistroName='Missing'}))
    Assert-True ($targets[0].Path -eq 'E:\Retained' -and -not $script:PlannedDistroPath) 'Existing fallback was moved or replaced.'
}
Test-Case 'Ambiguous or incomplete registrations fail instead of reserving an unrelated default path' {
    function Get-WslStorageRegistrations { @([pscustomobject]@{Name='KiloLink-Ubuntu';Path='D:\one'},[pscustomobject]@{Name='KiloLink-Ubuntu';Path='E:\two'}) }
    Assert-Throws {Get-ServerStorageTargets $config} 'ambiguous'
    function Get-WslStorageRegistrations { [pscustomobject]@{Name='KiloLink-Ubuntu';Path=''} }
    Assert-Throws {Get-ServerStorageTargets $config} 'no disk location'
}
$policyTargets={
    [pscustomobject]@{Path='D:\moved';Purpose='WSL disk';Budget='distro';Bytes=16GB}
    [pscustomobject]@{Path='C:\Windows';Purpose='Windows/NDI';Budget='windows';Bytes=2GB}
    [pscustomobject]@{Path='C:\Programs';Purpose='Windows/NDI';Budget='windows';Bytes=2GB}
    [pscustomobject]@{Path='C:\Temp';Purpose='Downloads/state';Budget='staging';Bytes=2GB}
    [pscustomobject]@{Path='C:\State';Purpose='Downloads/state';Budget='staging';Bytes=2GB}
}
Test-Case 'Shared-volume purposes sum to 20 GiB without duplicate target inflation' {
    function Get-ServerStorageTargets {& $policyTargets}
    function Get-WindowsStorageVolume { [pscustomobject]@{VolumeId='same';VolumePath='C:\';AvailableBytes=20GB} }
    Assert-ServerStorage $config
    Assert-True (($script:Logs -join "`n") -match 'policyReserve=21474836480 bytes' -and $script:Logs.Count -eq 6) 'Shared-volume budget or diagnostic calculation was incorrect.'
}
Test-Case 'One byte below the shared threshold fails with a rounded deficit and no recovery latch' {
    function Get-ServerStorageTargets {& $policyTargets}
    function Get-WindowsStorageVolume { [pscustomobject]@{VolumeId='same';VolumePath='C:\';AvailableBytes=(20GB-1)} }
    Assert-Throws {Assert-ServerStorage $config} 'Free at least 1 GiB on C:\\'
    Assert-True ($script:LifecycleErrorCode -eq 'insufficient-disk-space' -and -not $script:LifecycleRecoveryRequired) 'Low space lost its actionable error or latched recovery.'
}
foreach($case in @(@{Name='Moved distro';C=100GB;D=15GB;Path='D'},@{Name='Staging and Windows';C=3GB;D=100GB;Path='C'})){
    Test-Case "$($case.Name) capacity is checked on its actual separate volume" {
        function Get-ServerStorageTargets {& $policyTargets}
        function Get-WindowsStorageVolume($Path) { $drive=$Path.Substring(0,1);[pscustomobject]@{VolumeId=$drive;VolumePath=($drive+':\');AvailableBytes=$case[$drive]} }
        Assert-Throws {Assert-ServerStorage $config} ('on '+$case.Path+':\\')
    }
}
Test-Case 'Mounted path volume identity overrides the apparent drive letter' {
    function Get-ServerStorageTargets { [pscustomobject]@{Path='C:\Mount\distro';Purpose='WSL disk';Budget='distro';Bytes=16GB};[pscustomobject]@{Path='C:\Temp';Purpose='Downloads';Budget='staging';Bytes=2GB} }
    function Get-WindowsStorageVolume($Path) {if($Path -like '*Mount*'){[pscustomobject]@{VolumeId='mounted';VolumePath='C:\Mount\';AvailableBytes=15GB}}else{[pscustomobject]@{VolumeId='boot';VolumePath='C:\';AvailableBytes=100GB}}}
    Assert-Throws {Assert-ServerStorage $config} 'on C:\\Mount\\'
}
Test-Case 'Quota-available zero is authoritative regardless of reported total capacity' {
    function Get-ServerStorageTargets {& $policyTargets}
    function Get-WindowsStorageVolume { [pscustomobject]@{VolumeId='same';VolumePath='C:\';AvailableBytes=0;TotalBytes=1TB;TotalFreeBytes=900GB} }
    Assert-Throws {Assert-ServerStorage $config} 'Free at least 20 GiB'
}
Test-Case 'Unknown volume capacity fails closed without creating recovery state' {
    function Get-WindowsStorageVolume { throw 'fixture access denied' }
    Assert-Throws {Assert-ServerStorage $config} 'Cannot verify Server disk space'
    Assert-True ($script:LifecycleErrorCode -eq 'storage-preflight-unavailable' -and -not $script:LifecycleRecoveryRequired -and ($script:Logs -join '') -match 'fixture access denied') 'Unknown capacity was hidden or allowed.'
}
Test-Case 'Supported WSL receives the exact checked new location and only creates its parent' {
    $script:PlannedDistroPath=Join-Path $testRoot 'new-owner\distro'
    $script:ApplicationManifest=@{runtime=@{ubuntuDistribution='Ubuntu-24.04'}}
    function Initialize-LifecycleProtocol {}
    function Invoke-Native($File,$Arguments,[switch]$Capture,[switch]$IgnoreExitCode,[switch]$ReadOnly,$TimeoutSeconds,$StallSeconds){
        Assert-True ($File -eq 'wsl.exe' -and ($Arguments -join '') -eq '--help' -and $ReadOnly -and $TimeoutSeconds -eq 30) 'Support probe was not bounded/read-only.'
        $global:LASTEXITCODE=0;'    --location <Location>'
    }
    $argsList=@(Get-NewWslInstallArguments)
    Assert-True (($argsList -join '|') -eq ('--install|Ubuntu-24.04|--name|KiloLink-Ubuntu|--version|2|--no-launch|--web-download|--location|'+$script:PlannedDistroPath)) 'Actual install location/arguments differ from preflight.'
    Assert-True ((Test-Path -LiteralPath (Split-Path $script:PlannedDistroPath -Parent)) -and -not (Test-Path -LiteralPath $script:PlannedDistroPath)) 'Helper created the distro itself.'
}
Test-Case 'Unsupported WSL cannot silently install into a different location' {
    $script:PlannedDistroPath=Join-Path $testRoot 'unsupported\distro'
    function Invoke-Native {$global:LASTEXITCODE=0;'--install --web-download'}
    Assert-Throws {Get-NewWslInstallArguments} 'does not advertise install-location support'
    Assert-True (-not (Test-Path -LiteralPath (Split-Path $script:PlannedDistroPath -Parent))) 'Unsupported runtime changed disk state.'
}
Test-Case 'Colliding orphan storage is retained and never adopted' {
    $script:PlannedDistroPath=Join-Path $testRoot 'orphan'
    New-Item -ItemType Directory -Path $script:PlannedDistroPath|Out-Null
    $sentinel=Join-Path $script:PlannedDistroPath 'ext4.vhdx';[IO.File]::WriteAllText($sentinel,'retained')
    function Initialize-LifecycleProtocol {}
    function Invoke-Native {$global:LASTEXITCODE=0;'--location'}
    Assert-Throws {Get-NewWslInstallArguments} 'already exists'
    Assert-True ([IO.File]::ReadAllText($sentinel) -eq 'retained') 'Orphan data changed.'
}
foreach($existing in @($true,$false)){
    Test-Case "Ensure-Ubuntu keeps existing=$existing registration and applies location only for new installs" {
        . $linux
        $script:Calls=New-Object 'Collections.Generic.List[string]'
        $script:ProgressPercent=0
        function Get-UbuntuDistro {if($existing){'Moved'}}
        function Get-NewWslInstallArguments {$script:Calls.Add('location');@('--install','Fixture','--location','D:\fixture path')}
        function Invoke-Native($File,$Arguments){$script:Calls.Add(($Arguments -join '|'))}
        function Wait-WslDistroRegistration {$true}
        function Write-Step {}
        function Set-SuiteProgress {}
        function Save-Config {}
        function Get-WslDistroLaunchProbe {@{Success=$true}}
        function Get-WslDistroVersion {2}
        function Wait-WslDistroReady {$true}
        $localConfig=[pscustomobject]@{DistroName='Moved'}
        $name=Ensure-Ubuntu $localConfig
        if($existing){Assert-True ($name -eq 'Moved' -and $script:Calls.Count -eq 0) 'Existing registration was reinstalled/moved.'}
        else{Assert-True ($name -eq 'KiloLink-Ubuntu' -and ($script:Calls -join ';') -eq 'location;--install|Fixture|--location|D:\fixture path') 'New install discarded its planned location.'}
    }
}
$failed=@($results|Where-Object {-not $_.Passed})
$results|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("{0}/{1} storage checks passed. Evidence: {2}" -f ($results.Count-$failed.Count),$results.Count,$testRoot)
if($failed.Count){exit 1}
exit 0
