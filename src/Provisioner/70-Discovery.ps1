function Get-DiscoveryConfigPath { Join-Path $env:ProgramData 'NDI\ndi-discovery-service.v1.json' }

function Get-DiscoveryDelayedStart {
    param([string]$Name)
    $value = Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name) -Name DelayedAutoStart -ErrorAction SilentlyContinue
    if ($value) { [int]$value.DelayedAutoStart } else { $null }
}

function Restore-DiscoveryDelayedStart {
    param([string]$Name, $Value)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    if ($null -eq $Value) { Remove-ItemProperty -LiteralPath $key -Name DelayedAutoStart -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -LiteralPath $key -Name DelayedAutoStart -Type DWord -Value ([int]$Value) }
}

function Test-ServerOwnershipEvidence {
    if (Get-SavedConfig) { return $true }
    $discoveryPath = Join-Path $script:StateRoot 'discovery-ownership.json'
    if (Test-Path -LiteralPath $discoveryPath) {
        $discovery = Get-Content -LiteralPath $discoveryPath -Raw | ConvertFrom-Json
        if ($discovery.schemaVersion -ne 1) { throw 'Unsupported Discovery ownership receipt.' }
        if (-not (Get-PropertyValue $discovery 'restoreCompleted' $false)) { return $true }
    }
    $path = Join-Path $script:StateRoot 'installation-components.json'
    if (Test-Path -LiteralPath $path) {
        $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($receipt.schemaVersion -ne 1) { throw 'Unsupported component receipt. Server ownership cannot be verified.' }
        if ('server' -in @($receipt.roles)) { return $true }
    }
    return [bool](Get-ScheduledTask -TaskName $script:StartupTaskName -ErrorAction SilentlyContinue)
}

function Save-DiscoveryOwnership {
    $path = Join-Path $script:StateRoot 'discovery-ownership.json'
    if (Test-Path -LiteralPath $path) {
        $previous = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($previous.schemaVersion -ne 1) { throw 'Unsupported Discovery ownership receipt.' }
        if (-not (Get-PropertyValue $previous 'restoreCompleted' $false)) { return }
        Remove-Item -LiteralPath $path -Force
    }
    $service = Get-NdiDiscoveryService
    $task = Get-ScheduledTask -TaskName $script:NdiTaskName -ErrorAction SilentlyContinue
    $configPath = Get-DiscoveryConfigPath
    $config = if (Test-Path -LiteralPath $configPath) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) } else { $null }
    $receipt = @{
        schemaVersion=1; priorServiceName=$(if ($service) { $service.Name } else { $null })
        priorStartType=$(if ($service) { [string]$service.StartType } else { $null })
        priorDelayedStart=$(if ($service) { Get-DiscoveryDelayedStart $service.Name } else { $null })
        priorRunning=[bool]($service -and $service.Status -eq 'Running')
        priorTaskXml=$(if ($task) { Export-ScheduledTask -TaskName $script:NdiTaskName } else { $null })
        priorTaskRunning=[bool]($task -and $task.State -eq 'Running')
        priorConfig=$config; managedServiceName=$null
    }
    New-Item -ItemType Directory -Path $script:StateRoot -Force | Out-Null
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($path + '.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
}

function Restore-DiscoveryOwnership {
    $path = Join-Path $script:StateRoot 'discovery-ownership.json'
    $receipt = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } else { $null }
    if (-not $receipt -and -not (Test-ServerOwnershipEvidence)) { return }
    if ($receipt -and $receipt.schemaVersion -ne 1) { throw 'Unsupported Discovery ownership receipt. No Discovery settings were changed.' }
    if ($receipt -and (Get-PropertyValue $receipt 'restoreCompleted' $false)) { return }
    $service = Get-NdiDiscoveryService
    if ($receipt -and $receipt.managedServiceName -and $service -and $service.Name -ne $receipt.managedServiceName) {
        throw 'The Discovery service identity changed. Restore the recorded service before removing server ownership.'
    }
    $start = if ($receipt -and $service -and $receipt.priorServiceName -eq $service.Name) { $receipt.priorStartType } else { 'Disabled' }
    if ($start -notin @('Automatic','Manual','Disabled')) { throw 'Invalid previous Discovery startup setting.' }
    $priorConfig = if ($receipt -and $null -ne $receipt.priorConfig) { [Convert]::FromBase64String($receipt.priorConfig) } else { $null }
    Stop-ManagedTask $script:NdiTaskName
    Unregister-ScheduledTask -TaskName $script:NdiTaskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name $service.Name -Force -ErrorAction Stop
        # A legacy receipt has no trustworthy prior setting: retain the runtime,
        # disable its managed server service, and leave its configuration for repair.
        Set-Service -Name $service.Name -StartupType $start
        if ($receipt -and $receipt.priorServiceName -eq $service.Name -and $receipt.PSObject.Properties['priorDelayedStart']) {
            Restore-DiscoveryDelayedStart $service.Name $receipt.priorDelayedStart
        }
    }
    if ($receipt) {
        $configPath = Get-DiscoveryConfigPath
        if ($null -ne $receipt.priorConfig) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
            [IO.File]::WriteAllBytes($configPath, $priorConfig)
        } else { Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue }
        if ($receipt.priorTaskXml) {
            Register-ScheduledTask -TaskName $script:NdiTaskName -Xml $receipt.priorTaskXml -Force | Out-Null
            if ($receipt.priorTaskRunning) { Start-ScheduledTask -TaskName $script:NdiTaskName }
        }
        if ($service -and $receipt.priorServiceName -eq $service.Name -and $receipt.priorRunning) { Start-Service -Name $service.Name }
        $receipt | Add-Member -NotePropertyName restoreCompleted -NotePropertyValue $true -Force
        $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($path + '.tmp') -Encoding UTF8
        Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
    }
}

function Configure-NdiServer {
    param($Config)
    Save-DiscoveryOwnership
    Write-Step 'Configuring NDI Discovery Server on all physical adapters'
    $exe = Get-NdiDiscoveryExe
    if (-not $exe) {
        throw 'NDI Discovery Service.exe was not found in the NDI Tools installation.'
    }
    Stop-ManagedTask $script:NdiTaskName

    $ndiConfigDir = Join-Path $env:ProgramData 'NDI'
    New-Item -ItemType Directory -Path $ndiConfigDir -Force | Out-Null
    [pscustomobject]@{
        binding = '0.0.0.0'
        port_no = [string]$Config.NdiDiscoveryPort
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ndiConfigDir 'ndi-discovery-service.v1.json') -Encoding UTF8

    $service = Get-NdiDiscoveryService
    if (-not $service) {
        try {
            $process = Start-Process -FilePath $exe -ArgumentList @('install') -PassThru -WindowStyle Hidden
            if (-not $process.WaitForExit(15000)) { $process.Kill() }
        } catch {
            Write-Warning "NDI service registration was unavailable: $($_.Exception.Message)"
        }
        $service = Get-NdiDiscoveryService
    }

    if ($service) {
        $ownershipPath = Join-Path $script:StateRoot 'discovery-ownership.json'
        $ownership = Get-Content -LiteralPath $ownershipPath -Raw | ConvertFrom-Json
        $ownership.managedServiceName = $service.Name
        $ownership | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($ownershipPath + '.tmp') -Encoding UTF8
        Move-Item -LiteralPath ($ownershipPath + '.tmp') -Destination $ownershipPath -Force
        Unregister-ScheduledTask -TaskName $script:NdiTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Set-Service -Name $service.Name -StartupType Automatic
        if ($service.Status -eq 'Running') {
            Restart-Service -Name $service.Name -Force
        } else {
            Start-Service -Name $service.Name
        }
        Write-Detail "NDI Discovery Server is running as $($service.DisplayName)." Green
        return
    }

    $action = New-ScheduledTaskAction -Execute $exe -Argument "-bind 0.0.0.0 -port $($Config.NdiDiscoveryPort)"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT20S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:NdiTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $script:NdiTaskName
    Write-Detail 'NDI Discovery Server startup task installed.' Green
}
