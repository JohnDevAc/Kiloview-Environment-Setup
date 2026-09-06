# Render the compiled native controls without launching the installer worker.
[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:TEMP 'kiloview-wizard-preview'),
    [ValidateRange(1, 2)] [double]$ScaleFactor = 1
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions
[Windows.Forms.Application]::EnableVisualStyles()
$root = Split-Path -Parent $PSScriptRoot
$assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes((Join-Path $root 'Kiloview-Environment-Setup.exe')))
$type = $assembly.GetType('KiloLink.Setup.SetupForm')
$flags = [Reflection.BindingFlags]'NonPublic,Instance'
$form = $type.GetConstructor($flags,$null,@([bool]),$null).Invoke(@($false))
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
function Field($Name) { $type.GetField($Name,$flags).GetValue($form) }
function Call($Name, $Arguments = @()) { [void]$type.GetMethod($Name,$flags).Invoke($form,$Arguments) }
function Render($Name) {
    $originalClient = $form.ClientSize
    $fontState = [Collections.Generic.List[object]]::new()
    if ($ScaleFactor -ne 1) {
        $controls = [Collections.Generic.Queue[Windows.Forms.Control]]::new()
        $controls.Enqueue($form)
        while ($controls.Count) {
            $control = $controls.Dequeue()
            $fontState.Add(@($control,$control.Font))
            foreach ($child in $control.Controls) { $controls.Enqueue($child) }
        }
        $form.Scale([Drawing.SizeF]::new($ScaleFactor,$ScaleFactor))
        foreach ($entry in $fontState) {
            $font = $entry[1]
            $entry[0].Font = [Drawing.Font]::new($font.FontFamily,($font.Size * $ScaleFactor),$font.Style,$font.Unit)
        }
    }
    $form.PerformLayout()
    $bitmap = New-Object Drawing.Bitmap($form.Width,$form.Height)
    try {
        $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $bitmap.Save((Join-Path $OutputDirectory ($Name + '.png')))
    } finally {
        $bitmap.Dispose()
        if ($ScaleFactor -ne 1) {
            foreach ($entry in $fontState) { $scaled = $entry[0].Font; $entry[0].Font = $entry[1]; $scaled.Dispose() }
            $form.Scale([Drawing.SizeF]::new((1 / $ScaleFactor),(1 / $ScaleFactor)))
            $form.ClientSize = $originalClient
        }
    }
}
try {
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    (Field 'installChoice').Enabled = $true
    (Field 'installChoice').Checked = $true
    (Field 'repairChoice').Enabled = $false
    (Field 'updateChoice').Enabled = $false
    (Field 'uninstallChoice').Enabled = $false
    (Field 'welcomeStatusLabel').Text = 'Ready for a new installation. Choose Next to configure the server network.'
    Render '01-welcome'
    $type.GetField('preferredInterfaceAlias',$flags).SetValue($form,'Ethernet')
    $type.GetField('preferredIpAddress',$flags).SetValue($form,'192.0.2.10')
    Call 'ShowSettings' @('Fixture settings')
    Render '02-settings'
    Call 'ReviewSelectedAction'
    Render '03-review'
    $type.GetField('selectedAction',$flags).SetValue($form,'Uninstall')
    Call 'ReviewSelectedAction'
    Render '04-uninstall'
    Call 'ShowProgressView'
    Call 'HandleOutputLine' @('@@KILOVIEW_EVENT@@{"type":"summary","webUrl":"http://192.0.2.10:80/","ndiEndpoint":"192.0.2.10:5959","linkEndpoint":"192.0.2.10:50000-50001 UDP"}')
    Call 'HandleOutputLine' @('@@KILOVIEW_EVENT@@{"type":"outcome","outcome":"Completed","message":"Installation completed and service readiness checks passed."}')
    Call 'FinishWizardOperation' @(0)
    Render '05-complete'
    Call 'HandleOutputLine' @('@@KILOVIEW_EVENT@@{"type":"outcome","outcome":"RestartRequired","message":"Restart Windows and sign back in to continue setup."}')
    Call 'FinishWizardOperation' @(3010)
    Render '06-restart'
    Call 'ShowSettings' @('Fixture settings')
    $form.ClientSize = [Drawing.Size]::new(640,480)
    (Field 'settingsPanel').AutoScrollPosition = [Drawing.Point]::new(160,300)
    Render '07-small-window-scrolled'
} finally { $form.Dispose(); [Environment]::ExitCode = 0 }
Write-Output $OutputDirectory
