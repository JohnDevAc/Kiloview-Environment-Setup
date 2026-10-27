# Harmless external producer fixture. Uses the actual parser, atomic writer,
# engine outcome mapping and journal; never executes the provisioning entry point.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$LifecycleRequestPath,
    [ValidateSet('succeeded','no-change','cancelled','partial','blocked','restart-required','crash')][string]$FixtureOutcome='succeeded'
)
$ErrorActionPreference='Stop'
$fixtureRequestPath=$LifecycleRequestPath
$fixtureRequestedOutcome=$FixtureOutcome
$root=Split-Path $PSScriptRoot
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Install-KiloLinkSuite.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Build the current provisioner before running fixtures.'}
$declarations=@();$found=$false
foreach($statement in $ast.EndBlock.Statements){
    if($statement.Extent.Text -eq 'Ensure-Administrator'){$found=$true;break}
    $declarations+=$statement.Extent.Text
}
if(-not $found){throw 'Entry boundary is missing; refusing to execute the engine.'}
. ([scriptblock]::Create($declarations -join "`n"))
Initialize-LifecycleProtocol
$script:Lifecycle=[KiloLink.Lifecycle.Request]::Load($fixtureRequestPath)
$script:StateRoot=Join-Path $script:Lifecycle.DirectoryPath 'fixture-state'
$script:InstallerLogPath=Join-Path $script:StateRoot 'fixture.log'
function Get-ObservedComponents { @([pscustomobject]@{productId='environment';installed=$true;configured=$false;running=$false;healthy=$null;version='fixture';channel='fixture'}) }
function Write-LauncherEvent { }
Start-DeploymentJournal $script:Lifecycle.Action $null
Set-OperationOutcome 'Running' 'Harmless Environment lifecycle fixture is running.'
switch($fixtureRequestedOutcome){
    crash {exit 7}
    succeeded {Set-OperationOutcome 'Completed' 'Harmless fixture completed.'}
    no-change {Set-OperationOutcome 'NoChange' 'Harmless fixture was already current.'}
    cancelled {Set-OperationOutcome 'Cancelled' 'Harmless fixture cancelled before changes.'}
    partial {Add-LifecycleEffect 'Harmless fixture records a simulated completed step.';Set-OperationOutcome 'Partial' 'Harmless fixture stopped after a simulated partial change.'}
    blocked {$script:LifecycleErrorCode='operation-conflict';Set-OperationOutcome 'Blocked' 'Harmless fixture simulates another active operation.'}
    restart-required {Set-OperationOutcome 'RestartRequired' 'Harmless fixture requires a simulated restart; no restart is scheduled.'}
}
exit (Get-InstallerExitCode)
