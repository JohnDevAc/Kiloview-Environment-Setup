#Requires -Version 5.1
# Copyright (c) 2026 John Lightfoot
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Deployment engine for KiloLink Server Pro, NDI Tools, and NDI Discovery Server.

.DESCRIPTION
    KiloLink runs in Docker Engine inside a dedicated Ubuntu WSL 2 distribution.
    Windows 11 mirrored networking exposes its TCP, UDP, and multicast traffic
    on physical adapters. The selected stable IPv4 address is advertised to
    KiloLink devices, while the services listen on all available interfaces.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Setup', 'Install', 'InstallClient', 'Repair', 'Update', 'MaintainRuntime', 'Uninstall', 'Resume', 'CheckDownloads', 'Inspect', 'Plan', 'Verify', 'Backup')]
    [string]$Action = 'Menu',
    [switch]$AcceptLicenses,
    [switch]$AutoRestart,
    [switch]$LauncherMode,
    [string]$LogPath,
    [string]$PreferredInterfaceAlias,
    [string]$PreferredIpAddress,
    [string]$ConfigurationPath,
    [switch]$ConfirmRemoval,
    [string]$PackageDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:StateRoot = Join-Path $env:ProgramData 'KiloLink'
$script:ConfigPath = Join-Path $script:StateRoot 'installer-config.json'
$script:StartupScriptPath = Join-Path $script:StateRoot 'start-kilolink.ps1'
$script:StartupTaskName = 'KiloLink WSL Startup'
$script:NdiTaskName = 'NDI Discovery Server Startup'
$script:FirewallGroup = 'KiloLink Suite Installer'
$script:HyperVPrefix = 'KiloLinkSuite-'
$script:WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$script:ManagedDistroName = 'KiloLink-Ubuntu'
$script:ContainerName = 'KLNKSVR-pro'
$script:ApplicationManifest = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__APPLICATION_MANIFEST_BASE64__')) | ConvertFrom-Json
$script:ProductVersion = '__PRODUCT_VERSION__'
$script:ActiveJournal = $null
$script:KiloImage = $script:ApplicationManifest.kiloLink.image
$script:LinuxDataPath = '/opt/kilolink-server'
$script:NdiToolsUrl = $script:ApplicationManifest.ndiTools.url
$script:KiloInstallerUrl = 'https://www.kiloview.com/downloads/klnk-pro/install.sh'
$script:InstallerLogPath = Join-Path $script:StateRoot 'installer.log'
$script:ResumeStatePath = Join-Path $script:StateRoot 'resume-state.json'
$script:ResumeTaskName = 'KiloLink Suite Installation Resume'
$script:PersistentLauncherPath = Join-Path $script:StateRoot 'Launcher\Kiloview-Environment-Setup.exe'
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'managed-installation.json'))) {
    $script:PersistentLauncherPath = Join-Path $PSScriptRoot 'Kiloview-Environment-Setup.exe'
}
$script:RestartScheduled = $false
$script:MaximumResumeAttempts = 3
$script:KiloDefaultUsername = 'admin'
$script:KiloDefaultPassword = 'Kiloview001'
$script:ProgressActive = $false
$script:ProgressActivity = ''
$script:ProgressStatus = ''
$script:ProgressPercent = 0
$script:ProgressPulseIndex = 0
$script:ProgressLastPulse = [datetime]::MinValue
$script:LauncherEventPrefix = '@@KILOVIEW_EVENT@@'
$script:OperationOutcome = 'Idle'
$script:OperationMessage = 'No deployment operation was performed.'
$script:OperationFailed = $false
$script:PreparedNdiInstaller = $null
$script:PreparedNdiSource = $null
$script:NdiDownloadPage = $null
$script:PreparedNdiCheck = $null
$script:NdiRestartRequired = $false
$script:PreparedPcAgentRoot = $null
$script:PreparedPcAgentRelease = $null
