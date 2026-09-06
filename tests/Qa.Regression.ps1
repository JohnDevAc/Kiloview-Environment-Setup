# Runs only inside Installer.Regression.ps1's isolated fixture engine.
Test-Case 'Client Agent evidence requires a complete usable saved identity' {
    $valid = @{schemaVersion=1;endpointId=[guid]::NewGuid().ToString();adapterId=[guid]::NewGuid().ToString();address='192.0.2.20';prefixLength=24}
    Assert-True (Test-PcAgentState ([pscustomobject]$valid)) 'Complete Agent state was rejected.'
    foreach ($field in @('schemaVersion','endpointId','adapterId','address','prefixLength')) {
        $bad = $valid.Clone(); $bad[$field]=$null
        Assert-True (-not (Test-PcAgentState ([pscustomobject]$bad))) "Incomplete $field was accepted."
    }
    foreach ($address in @('0.0.0.0','127.0.0.1','169.254.1.2','224.0.0.1','192.0.2.0','192.0.2.255')) {
        $bad = $valid.Clone(); $bad.address=$address
        Assert-True (-not (Test-PcAgentState ([pscustomobject]$bad))) "Unusable $address was accepted."
    }
}
Test-Case 'Unsupported component receipts are preserved by Client setup' {
    New-Item -ItemType Directory -Force -Path $script:StateRoot | Out-Null
    $path = Join-Path $script:StateRoot 'installation-components.json'
    foreach ($json in @('{"schemaVersion":2,"roles":["server"],"serverOwnerSid":"S-1-5-21-100"}', '{"schemaVersion":1,"roles":["future-server"]}')) {
        [IO.File]::WriteAllText($path, $json)
        Assert-Throws { Save-ComponentReceipt 'client' } 'ownership was preserved'
        Assert-True ([IO.File]::ReadAllText($path) -ceq $json) 'Unsupported receipt was overwritten.'
    }
}

Test-Case 'Completed Discovery restoration residue does not imply server ownership' {
    Save-ComponentReceipt 'client'
    @{schemaVersion=1;restoreCompleted=$true} | ConvertTo-Json | Set-Content (Join-Path $script:StateRoot 'discovery-ownership.json')
    function Get-UbuntuDistro { throw 'Unexpected client WSL inspection' }
    function Stop-ManagedTask { throw 'Unexpected task mutation' }
    Uninstall-Suite -Confirmed
    Assert-True (-not (Test-ServerOwnershipEvidence)) 'Consumed Discovery residue recreated a server role.'
}
Test-Case 'Client-only removal makes no server or Discovery changes' {
    Save-ComponentReceipt 'client'
    function Get-NdiDiscoveryService { throw 'Unexpected shared service inspection' }
    function Get-UbuntuDistro { throw 'Unexpected client WSL inspection' }
    function Stop-ManagedTask { throw 'Unexpected task mutation' }
    Uninstall-Suite -Confirmed
    Restore-DiscoveryOwnership
    $receipt = Get-Content (Join-Path $script:StateRoot 'installation-components.json') -Raw | ConvertFrom-Json
    Assert-True (@($receipt.roles).Count -eq 1 -and $receipt.roles[0] -eq 'client') 'Client role was removed.'
}

Test-Case 'Discovery restores delayed Automatic startup and running state' {
    $script:Service = [pscustomobject]@{Name='FixtureDiscovery';Status='Running';StartType='Automatic'}
    function Get-NdiDiscoveryService { $script:Service }
    function Get-DiscoveryDelayedStart { 1 }
    Save-DiscoveryOwnership
    function Stop-ManagedTask { }
    function Unregister-ScheduledTask { }
    function Stop-Service { $script:Service.Status='Stopped' }
    function Set-Service { param($Name,$StartupType) $script:Service.StartType=$StartupType }
    function Start-Service { $script:Service.Status='Running' }
    function Restore-DiscoveryDelayedStart { param($Name,$Value) $script:Delayed=$Value }
    Restore-DiscoveryOwnership
    Assert-True ($script:Delayed -eq 1 -and $script:Service.Status -eq 'Running' -and $script:Service.StartType -eq 'Automatic') 'Prior delayed service state was lost.'
}

Test-Case 'Corrupt Discovery snapshot fails before mutation' {
    $script:Service = [pscustomobject]@{Name='FixtureDiscovery';Status='Running';StartType='Unsupported'}
    function Get-NdiDiscoveryService { $script:Service }
    Save-DiscoveryOwnership
    function Stop-ManagedTask { throw 'Unexpected task mutation' }
    Assert-Throws { Restore-DiscoveryOwnership } 'Invalid previous Discovery startup setting'
}
Test-Case 'Server ownership is persisted and preserved by Client setup' {
    function Get-CurrentUserSid { 'S-1-5-21-100' }
    Save-ComponentReceipt 'server'
    Save-ComponentReceipt 'client'
    $receipt = Get-Content (Join-Path $script:StateRoot 'installation-components.json') -Raw | ConvertFrom-Json
    Assert-True ($receipt.serverOwnerSid -eq 'S-1-5-21-100' -and @($receipt.roles).Count -eq 2) 'Client setup lost server ownership.'
}

Test-Case 'Wrong server owner cannot mutate uninstall or resume state' {
    function Get-CurrentUserSid { 'S-1-5-21-100' }
    Save-ComponentReceipt 'server'
    function Get-CurrentUserSid { 'S-1-5-21-200' }
    function Get-InteractiveUserSid { 'S-1-5-21-200' }
    Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ServerOwner' }, $true).Extent.Text)
    function Set-OperationOutcome { throw 'Unexpected mutation before owner check' }
    function Remove-ResumeTask { throw 'Unexpected resume mutation' }
    Assert-Throws { Uninstall-Suite -Confirmed } 'belongs to Windows account S-1-5-21-100'
    Assert-Throws { Resume-Suite } 'belongs to Windows account S-1-5-21-100'
}

Test-Case 'Same server owner and legacy task ownership are accepted' {
    function Get-CurrentUserSid { 'S-1-5-21-100' }
    function Get-InteractiveUserSid { 'S-1-5-21-100' }
    function Get-ScheduledTask { [pscustomobject]@{Principal=[pscustomobject]@{UserId='S-1-5-21-100'}} }
    Invoke-Expression ($ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-ServerOwner' }, $true).Extent.Text)
    Assert-ServerOwner
    Save-ComponentReceipt 'server'
    function Get-ScheduledTask { $null }
    Assert-ServerOwner
    Assert-True ((Get-ServerOwnerSid) -eq 'S-1-5-21-100') 'Legacy owner was not migrated.'
}

Test-Case 'Unverifiable legacy server ownership fails closed' {
    Save-Config (New-Config)
    Assert-Throws { Get-ServerOwnerSid } 'ownership cannot be verified'
}

Test-Case 'Server removal disables newly managed Discovery and retains shared files' {
    Save-DiscoveryOwnership
    $script:Service = [pscustomobject]@{Name='FixtureDiscovery';Status='Running';StartType='Automatic'}
    function Get-NdiDiscoveryService { $script:Service }
    function Stop-ManagedTask { }
    function Unregister-ScheduledTask { }
    function Stop-Service { param($Name,[switch]$Force,$ErrorAction) $script:Service.Status='Stopped' }
    function Set-Service { param($Name,$StartupType) $script:Service.StartType=$StartupType }
    Restore-DiscoveryOwnership
    Assert-True ($script:Service.Status -eq 'Stopped' -and $script:Service.StartType -eq 'Disabled') 'Discovery can restart after Server removal.'
    $receipt = Get-Content (Join-Path $script:StateRoot 'discovery-ownership.json') -Raw | ConvertFrom-Json
    Assert-True $receipt.restoreCompleted 'Removal did not persist Discovery restoration progress.'
}

Test-Case 'Discovery ownership preserves prior service and exact configuration' {
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $config = Get-DiscoveryConfigPath
    [IO.File]::WriteAllText($config, 'previous configuration')
    $script:Service = [pscustomobject]@{Name='FixtureDiscovery';Status='Stopped';StartType='Manual'}
    function Get-NdiDiscoveryService { $script:Service }
    Save-DiscoveryOwnership
    $script:Service.Status='Running'; $script:Service.StartType='Automatic'
    [IO.File]::WriteAllText($config, 'suite configuration')
    Save-DiscoveryOwnership # Repair must not overwrite the original snapshot.
    function Stop-ManagedTask { }
    function Unregister-ScheduledTask { }
    function Stop-Service { param($Name,[switch]$Force,$ErrorAction) $script:Service.Status='Stopped' }
    function Set-Service { param($Name,$StartupType) $script:Service.StartType=$StartupType }
    Restore-DiscoveryOwnership
    Assert-True ($script:Service.Status -eq 'Stopped' -and $script:Service.StartType -eq 'Manual') 'Previous service settings were not restored.'
    Assert-True ([IO.File]::ReadAllText($config) -ceq 'previous configuration') 'Previous Discovery configuration was lost.'
    function Get-NdiDiscoveryService { throw 'A resumed uninstall repeated Discovery restoration' }
    Restore-DiscoveryOwnership
}

Test-Case 'Failed server removal retains verified ownership for retry' {
    function Get-CurrentUserSid { 'S-1-5-21-100' }
    Save-ComponentReceipt 'server'
    Save-Config (New-Config)
    function Get-UbuntuDistro { $null }
    function Stop-ManagedTask { throw 'Fixture interrupted removal' }
    Assert-Throws { Uninstall-Suite -Confirmed } 'Fixture interrupted removal'
    Assert-True ((Get-ServerOwnerSid) -eq 'S-1-5-21-100') 'An interrupted uninstall erased server ownership.'
}
