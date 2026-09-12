# Loaded by Installer.Regression.ps1: all native/WSL mutations remain intercepted.
Test-Case 'Systemd repair restarts only its distro when PID 1 actually needs it' {
    Assert-True (Test-Path -LiteralPath $BashPath) 'Git Bash is required for the generated systemd fixture.'
    foreach ($case in @(
        @{Name='healthy';Config="[boot]`nsystemd=true`n";PidOne='systemd';Restart=$false},
        @{Name='interrupted';Config="[boot]`nsystemd=true`n";PidOne='init';Restart=$true},
        @{Name='disabled';Config="[boot]`nsystemd=false`n";PidOne='init';Restart=$true},
        @{Name='missing-boot';Config="[network]`ngenerateHosts=false`n";PidOne='init';Restart=$true},
        @{Name='already-running';Config="[boot]`nsystemd = true`n";PidOne='systemd';Restart=$false}
    )) {
        $fixtureRoot = Join-Path $testRoot ('systemd-' + $case.Name)
        New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
        $unixRoot = '/' + $fixtureRoot.Substring(0,1).ToLowerInvariant() + $fixtureRoot.Substring(2).Replace('\','/')
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'wsl.conf'), $case.Config, $utf8)
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'ps'), "#!/bin/sh`nprintf '%s\n' " + $case.PidOne + "`n", $utf8)
        $script:NativeCalls = @(); $script:WaitCalls = @(); $script:DockerCalls = 0
        function Invoke-Native {
            param($FilePath,$Arguments)
            $script:NativeCalls += $FilePath + ' ' + ($Arguments -join ' ')
            Assert-True ($FilePath -eq 'wsl.exe' -and ($Arguments -join ' ') -eq '--terminate Fixture-Distro') 'A restart escaped the requested distribution.'
        }
        function Wait-WslDistroReady { param($Distro,$TimeoutSeconds) $script:WaitCalls += $Distro; $true }
        function Invoke-WslScript {
            param($Distro,$Content,[switch]$Capture)
            Assert-True ($Distro -eq 'Fixture-Distro') 'Unexpected distro.'
            if (-not $Capture) { $script:DockerCalls++; return }
            $probe = "export PATH='$unixRoot':/usr/bin:/bin`n" + $Content.Replace('/etc/wsl.conf', "'$unixRoot/wsl.conf'")
            Assert-True (-not $probe.Contains('/etc/')) 'Generated fixture still targets /etc.'
            $probePath = Join-Path $fixtureRoot 'enable.sh'
            [IO.File]::WriteAllText($probePath, $probe.Replace("`r`n","`n"), $utf8)
            $output = & $BashPath --noprofile --norc $probePath
            Assert-True ($LASTEXITCODE -eq 0) 'Generated systemd script failed.'
            return $output
        }
        Ensure-Docker 'Fixture-Distro'
        Assert-True ($script:NativeCalls.Count -eq [int]$case.Restart -and $script:WaitCalls.Count -eq [int]$case.Restart) "Incorrect restart decision: $($case.Name)."
        Assert-True ($script:DockerCalls -eq 1) 'Docker setup did not continue.'
        $after = [IO.File]::ReadAllText((Join-Path $fixtureRoot 'wsl.conf'))
        Assert-True ($after.Contains("systemd=true`n")) 'Systemd was not enabled.'
        if ($case.Name -eq 'healthy') { Assert-True ($after -ceq $case.Config) 'Healthy configuration changed.' }
        if ($case.Name -eq 'missing-boot') { Assert-True ($after.Contains('generateHosts=false')) 'Unrelated WSL configuration was lost.' }
    }
}

Test-Case 'Unknown systemd state stops repair without restarting or installing Docker' {
    function Invoke-WslScript { param($Distro,$Content,[switch]$Capture) if (-not $Capture) { throw 'Docker should not run' }; 'unexpected output' }
    Assert-Throws { Ensure-Docker 'Fixture-Distro' } 'Could not verify the systemd state'
}

Test-Case 'Failed targeted restart stops Docker installation and remains retryable' {
    function Invoke-WslScript { param($Distro,$Content,[switch]$Capture) if (-not $Capture) { throw 'Docker should not run' }; 'KILOLINK_SYSTEMD_RESTART_REQUIRED' }
    function Invoke-Native { throw 'Targeted termination failed' }
    Assert-Throws { Ensure-Docker 'Fixture-Distro' } 'Targeted termination failed'
    function Invoke-Native { }
    function Wait-WslDistroReady { $false }
    Assert-Throws { Ensure-Docker 'Fixture-Distro' } 'did not restart with systemd'
}

Test-Case 'Custom registered NDI paths participate in Discovery, current-version retention and real lock preflight' {
    $savedProgramFiles = $env:ProgramFiles; $savedProgramFilesX86 = ${env:ProgramFiles(x86)}
    $instance = $null; $child = $null
    try {
        $env:ProgramFiles = Join-Path $testRoot 'ndi-program-files'
        ${env:ProgramFiles(x86)} = Join-Path $testRoot 'ndi-program-files-x86'
        $customRoot = Join-Path $testRoot 'custom NDI [tools]'
        $discoveryDir = Join-Path $customRoot 'Discovery'
        New-Item -ItemType Directory -Path $discoveryDir,$env:ProgramFiles,${env:ProgramFiles(x86)} -Force | Out-Null
        function Get-NdiRegistration { [pscustomobject]@{DisplayName='NDI 6 Tools';DisplayVersion='6.3.2.0';InstallLocation=$customRoot} }
        function Get-CurrentNdiToolsVersion { [version]'6.3.2.0' }
        function Download-FileWithProgress { throw 'A healthy current custom installation must not download Tools' }
        $exe = Join-Path $customRoot 'Fixture.exe'
        & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /reference:System.Windows.Forms.dll ("/out:$exe") (Join-Path $root 'tests\QuietInstaller.Fixture.cs')
        Assert-True ($LASTEXITCODE -eq 0) 'Native fixture compilation failed.'
        $discovery = Join-Path $discoveryDir 'NDI Discovery Service.exe'
        Copy-Item -LiteralPath $exe -Destination $discovery
        Assert-True ((Get-NdiDiscoveryExe) -eq $discovery) 'Custom registered Discovery was missed.'
        Install-NdiTools
        Install-NdiTools -UpdateOnly -PrepareOnly
        Install-NdiTools -UpdateOnly
        # Restore the production guard which the general test harness mocks.
        . ([scriptblock]::Create($ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-NdiToolsFilesAvailable'},$false).Extent.Text))
        if (-not ('KiloLink.Setup.QuietInstaller' -as [type])) { Add-Type -Path (Join-Path $root 'launcher\QuietInstaller.cs') }
        Assert-NdiToolsFilesAvailable
        $marker = Join-Path $customRoot 'holder'
        $instance = [KiloLink.Setup.QuietInstaller]::Start($exe, ('"' + $marker + '"'))
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        while (-not $instance.HasExited -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-True ($instance.HasExited -and $instance.ExitCode -eq 3010) 'Owned fixture did not settle.'
        $childId = [int](Get-Content -LiteralPath ($marker + '.child'))[0]
        $child = Get-Process -Id $childId
        Assert-Throws { Assert-NdiToolsFilesAvailable } ('files are in use.*PID ' + $childId)
        $child.Refresh()
        Assert-True (-not $child.HasExited) 'Read-only guard closed the holder.'
        $instance.Dispose(); $instance = $null
        Assert-True ($child.WaitForExit(5000)) 'Owned child remained running.'
        Assert-NdiToolsFilesAvailable
    } finally {
        if ($instance) { $instance.Dispose() }
        if ($child) { Assert-True ($child.WaitForExit(5000)) 'Owned child cleanup failed'; $child.Dispose() }
        $env:ProgramFiles = $savedProgramFiles; ${env:ProgramFiles(x86)} = $savedProgramFilesX86
    }
}

Test-Case 'NDI roots retain default and service fallbacks and reject unsafe broad locations' {
    $savedProgramFiles = $env:ProgramFiles; $savedProgramFilesX86 = ${env:ProgramFiles(x86)}
    try {
        $env:ProgramFiles = Join-Path $testRoot 'ndi-fallback-program-files'
        ${env:ProgramFiles(x86)} = Join-Path $testRoot 'ndi-fallback-program-files-x86'
        $customRoot = Join-Path $testRoot 'ndi-service-custom'
        $discovery = Join-Path $customRoot 'Discovery Service\NDI Discovery Service.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $discovery) -Force | Out-Null
        [IO.File]::WriteAllText($discovery,'fixture')
        function Get-NdiRegistration { $null }
        function Get-NdiDiscoveryService { [pscustomobject]@{Name='Fixture Discovery'} }
        function Get-CimInstance { [pscustomobject]@{Name='Fixture Discovery';PathName=('"' + $discovery + '" --port 5959')} }
        Assert-True ((Get-NdiDiscoveryExe) -eq $discovery) 'Registered service custom root was missed.'
        function Get-NdiRegistration { [pscustomobject]@{InstallLocation=$customRoot + '\'} }
        Assert-True (@(Get-NdiToolsRoots).Count -eq 1) 'Registration/service aliases were not deduplicated.'
        function Get-NdiDiscoveryService { $null }
        foreach ($bad in @('relative\NDI','C:\',$env:ProgramFiles,'\\server\share\NDI')) {
            function Get-NdiRegistration { [pscustomobject]@{InstallLocation=$bad} }
            Assert-Throws { Get-NdiToolsRoots } 'Invalid NDI Tools|too broad'
        }
        function Get-NdiRegistration { [pscustomobject]@{InstallLocation=(Join-Path $testRoot 'missing-registration-root')} }
        $defaultExe = Join-Path $env:ProgramFiles 'NDI\NDI 6 Tools\Discovery\NDI Discovery Service.exe'
        $x86Exe = Join-Path ${env:ProgramFiles(x86)} 'NDI\NDI 5 Tools\Discovery\NDI Discovery Service.exe'
        foreach ($path in @($defaultExe,$x86Exe)) { New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null; [IO.File]::WriteAllText($path,'fixture') }
        Assert-True ((Get-NdiDiscoveryExe) -eq $defaultExe) 'Default Discovery fallback regressed.'
        Assert-True (@(Get-NdiToolsFiles | Where-Object Name -eq 'NDI Discovery Service.exe').Count -eq 2) 'Both installed default versions must be inspected.'
        function Get-NdiRegistration { @([pscustomobject]@{InstallLocation=$customRoot},[pscustomobject]@{InstallLocation=(Split-Path -Parent (Split-Path -Parent $x86Exe))}) }
        Assert-True (@(Get-NdiToolsRoots).Count -eq 3) 'Multiple registered roots were not retained and deduplicated.'
    } finally { $env:ProgramFiles = $savedProgramFiles; ${env:ProgramFiles(x86)} = $savedProgramFilesX86 }
}
