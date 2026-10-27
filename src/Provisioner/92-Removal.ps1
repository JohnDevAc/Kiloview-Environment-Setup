function Get-ConfigurationProducts {
    Initialize-LifecycleProtocol
    [KiloLink.Lifecycle.ConfigurationMsi]::InstalledProducts()
}

function Remove-ConfigurationApp {
    Set-OperationOutcome 'Running' 'Removing configuration app.'
    $products=@(Get-ConfigurationProducts)
    if(-not $products.Count){Set-OperationOutcome 'NoChange' 'The configuration MSI is not installed. Server services and shared components were retained.';return}
    $maintenance=Split-Path -Parent $script:PersistentLauncherPath
    Initialize-LifecycleProtocol
    foreach($file in @('Kiloview-Environment-Setup.exe','Install-KiloLinkSuite.ps1','QuietInstaller.cs','toolbox-lifecycle.json')) {
        $path=Join-Path $maintenance $file
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Retained maintenance is missing. Run the verified Environment executable before removing the configuration app.'}
        [KiloLink.Lifecycle.SafePath]::Check($path)
    }
    if((Get-FileHash -LiteralPath (Join-Path $maintenance 'Install-KiloLinkSuite.ps1')).Hash -ne (Get-FileHash -LiteralPath $PSCommandPath).Hash) {
        throw 'Retained maintenance does not match this engine. Run the verified Environment executable again.'
    }
    foreach($product in $products) {
        if($product -notmatch '^\{[A-Fa-f0-9-]{36}\}$'){throw 'Unexpected Windows Installer product identity.'}
        Add-LifecycleEffect 'Configuration app removal started; server services and data are retained.'
        $log=Join-Path $script:StateRoot ('remove-app-'+[guid]::NewGuid().ToString('N')+'.log')
        Invoke-Native msiexec.exe @('/x',$product,'/qn','/norestart','/L*v',$log) -IgnoreExitCode -StallSeconds 0
        if($LASTEXITCODE -eq 3010){Set-OperationOutcome 'RestartRequired' 'Restart Windows to complete configuration app removal. Server services and data remain.';return}
        if($LASTEXITCODE -eq 1602){Set-OperationOutcome 'Cancelled' 'Windows Installer cancelled configuration app removal.';return}
        if($LASTEXITCODE -ne 0){throw "Configuration app removal failed with code $LASTEXITCODE. See $log"}
    }
    if(@(Get-ConfigurationProducts).Count){throw 'Windows Installer still reports the configuration app installed. Removal needs attention.'}
    Set-OperationOutcome 'Completed' 'The configuration application was removed. Server services, data, shared components and the retained maintenance executable remain.'
}

function Remove-ClientRole {
    Set-OperationOutcome 'Running' 'Removing Client role.'
    Save-ComponentReceipt 'client' -Remove
    $receipt=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $script:StateRoot 'installation-components.json') -Raw|ConvertFrom-Json
    if(@($receipt.roles) -contains 'client'){throw 'Client role removal could not be verified.'}
    Add-LifecycleEffect 'Environment Client role record removed; shared NDI Tools and PC Agent retained.'
    Set-OperationOutcome 'Completed' 'Client role removed. NDI Tools and PC Agent remain installed and are managed separately.'
}

function Remove-OwnedFile([string]$Path) {
    if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force -ErrorAction Stop}
    if(Test-Path -LiteralPath $Path){throw "Removal could not be verified: $Path"}
}

function Remove-OwnedTask([string]$Name) {
    if(Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop}
    if(Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue){throw "Scheduled task removal could not be verified: $Name"}
}
