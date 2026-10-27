#Requires -Version 5.1
# Real native PS5.1 metadata child, loopback HTTP only, no installers or live state writes.
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('kiloview-ndi-metadata-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot|Out-Null
$results=New-Object Collections.Generic.List[object]
function Assert-True($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Pattern){$errorText=$null;try{& $Body|Out-Null}catch{$errorText=$_.Exception.ToString()};Assert-True ($errorText -match $Pattern) ('Unexpected failure: '+$errorText)}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{Name=$Name;Passed=$true});Write-Host "PASS $Name"}catch{$results.Add(@{Name=$Name;Passed=$false;Error=$_.Exception.Message});Write-Host "FAIL $Name`: $($_.Exception.Message)";Write-Host $_.ScriptStackTrace}}
foreach($module in @('10-Core.ps1','12-Lifecycle.ps1','48-NdiMetadata.ps1','50-Packages.ps1','90-Operations.ps1')){. (Join-Path $root ('src\Provisioner\'+$module))}
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'launcher\LifecycleProtocol.cs'))) -ReferencedAssemblies @('System.dll','System.Core.dll','System.Web.Extensions.dll')
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class NdiHttpFixture : IDisposable {
    TcpListener listener; TcpClient client; Thread thread; volatile bool stopping;
    public string Url { get; private set; }
    public NdiHttpFixture(string html, bool slow, bool oversize, bool delayHeaders = false) {
        listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
        thread = new Thread(delegate() {
            try {
                client = listener.AcceptTcpClient(); client.ReceiveTimeout=2000; client.SendTimeout=2000;
                using (NetworkStream stream = client.GetStream()) {
                    byte[] request = new byte[4096]; stream.Read(request,0,request.Length);
                    if (delayHeaders) { for(int i=0;i<100 && !stopping;i++) Thread.Sleep(100); }
                    byte[] body = Encoding.UTF8.GetBytes(html);
                    string header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + (oversize ? 5000000 : body.Length) + "\r\nConnection: close\r\n\r\n";
                    byte[] headers = Encoding.ASCII.GetBytes(header); stream.Write(headers,0,headers.Length);
                    if (slow) { for(int i=0;i<100 && !stopping;i++) Thread.Sleep(100); }
                    if(!stopping && !oversize) stream.Write(body,0,body.Length);
                }
            } catch(SocketException) {} catch(System.IO.IOException) {} catch(ObjectDisposedException) {}
        }); thread.IsBackground=true; thread.Start();
    }
    public void Dispose() { stopping=true; listener.Stop(); if(client!=null)client.Close(); thread.Join(2000); }
}
'@
$script:StateRoot=$testRoot
$script:InstallerLogPath=Join-Path $testRoot 'installer.log'
$script:Lifecycle=$null;$script:LifecycleErrorCode='';$script:LifecycleEffects=@();$script:LifecycleComponents=@();$script:LifecycleRecoveryRequired=$false;$script:ActiveJournal=$null
$script:ProgressActive=$false;$script:ProgressPercent=0;$script:OperationOutcome='Running';$script:LauncherMode=$true
$script:LauncherEventPrefix='FIXTURE:'
$script:probeBase=New-NdiMetadataProbeScript
function New-NdiMetadataProbeScript {
    $text=$script:probeBase.Replace('Read-NdiToolsMetadata | ConvertTo-Json',('Read-NdiToolsMetadata -Uri '''+$script:fixtureUrl+''' | ConvertTo-Json'))
    if($script:probePidPath){$text='[IO.File]::WriteAllText('''+$script:probePidPath.Replace("'","''")+''',[string]$PID);'+$text}
    return $text
}
$valid='<a href="https://downloads.ndi.tv/Tools/NDI%206%20Tools.exe">Windows</a><div>Version 6.3.2</div>'
Test-Case 'Bounded parser preserves source, version, duplicate-link and quoted-attribute rules' {
    $html=$valid+"<A title='x > y' HREF='https://downloads.ndi.tv/Tools/NDI%206%20Tools.exe'>Again</A><p>Version 6.3.2.0</p><script>"+$valid.Replace('6.3.2','9.0.0')+'</script><!--'+$valid.Replace('6.3.2','8.0.0')+'-->'
    $data=ConvertFrom-NdiToolsHtml $html
    Assert-True ($data.Url -eq 'https://downloads.ndi.tv/Tools/NDI%206%20Tools.exe' -and $data.Version -eq '6.3.2.0') 'Valid metadata changed.'
    Assert-Throws {ConvertFrom-NdiToolsHtml ($valid+$valid.Replace('NDI%206','NDI%207'))} 'could not be identified'
    Assert-Throws {ConvertFrom-NdiToolsHtml $valid.Replace('downloads.ndi.tv','example.com')} 'could not be identified'
    Assert-True (-not (ConvertFrom-NdiToolsHtml ($valid+'<p>Version 6.3.3</p>')).Version) 'Ambiguous version authorized a skip.'
}
Test-Case 'Oversized and pathological HTML parsing is bounded' {
    Assert-Throws {ConvertFrom-NdiToolsHtml ('x'*(4MB+1))} 'size limit'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Assert-Throws {ConvertFrom-NdiToolsHtml ('<a x="'*40000)} 'time|could not be identified'
    Assert-True ($watch.Elapsed.TotalSeconds -lt 4) 'Pathological HTML exceeded parser bound.'
}
Test-Case 'Real native metadata child fetches and parses loopback HTML' {
    $server=[NdiHttpFixture]::new($valid,$false,$false)
    try {$script:fixtureUrl=$server.Url;$data=Get-NdiToolsMetadata -TimeoutSeconds 8;Assert-True ($data.Version -eq '6.3.2.0') 'Native metadata result failed.'} finally {$server.Dispose()}
}
Test-Case 'Metadata response size limit fails before accepting a package' {
    $server=[NdiHttpFixture]::new($valid,$false,$true)
    try {$script:fixtureUrl=$server.Url;Assert-Throws {Get-NdiToolsMetadata -TimeoutSeconds 8} 'size limit';Assert-True ($script:LifecycleErrorCode -eq 'ndi-metadata-unavailable') 'Wrong oversized-response error.'} finally {$server.Dispose()}
}
Test-Case 'Unresponsive vendor request fails at the parent deadline' {
    $server=[NdiHttpFixture]::new($valid,$false,$false,$true)
    $watch=[Diagnostics.Stopwatch]::StartNew();$script:LifecycleErrorCode=''
    try {
        $script:fixtureUrl=$server.Url
        Assert-Throws {Get-NdiToolsMetadata -TimeoutSeconds 2} 'metadata limits'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 5 -and $script:LifecycleErrorCode -eq 'ndi-metadata-timeout') 'Unresponsive request bypassed the parent deadline.'
    } finally {$server.Dispose()}
}
Test-Case 'Slow HTTP body has an end-to-end deadline, heartbeat and no surviving probe' {
    $directory=Join-Path $testRoot ([guid]::NewGuid().ToString('D'));New-Item -ItemType Directory -Path $directory|Out-Null
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($owner)
    foreach($sid in @($owner.Value,'S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    Set-Acl -LiteralPath $directory -AclObject $acl
    $requestPath=Join-Path $directory 'request.json';$resultPath=Join-Path $directory 'result.json'
    [IO.File]::WriteAllText($requestPath,(@{schemaVersion=1;operationId=[IO.Path]::GetFileName($directory);productId='environment';action='install';role='server';resultPath=$resultPath}|ConvertTo-Json))
    $script:Lifecycle=[KiloLink.Lifecycle.Request]::Load($requestPath)
    $script:LifecycleErrorCode='';$script:LifecycleNextAction='';$script:probePidPath=Join-Path $directory 'probe.pid'
    $server=[NdiHttpFixture]::new($valid,$true,$false)
    $watch=[Diagnostics.Stopwatch]::StartNew();$started=[datetime]::UtcNow
    try {
        $script:fixtureUrl=$server.Url
        Assert-Throws {Get-NdiToolsMetadata -TimeoutSeconds 7} 'metadata limits'
        $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
        Assert-True ($result.stage -eq 'ndi-metadata' -and ([datetime]$result.updatedUtc-$started).TotalSeconds -ge 4) 'No durable heartbeat while request stalled.'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 10 -and $script:LifecycleErrorCode -eq 'ndi-metadata-timeout') 'End-to-end deadline/error failed.'
        $probeId=[int](Get-Content -LiteralPath $script:probePidPath)
        Assert-True (-not (Get-Process -Id $probeId -ErrorAction SilentlyContinue)) 'Read-only metadata child survived timeout.'
        Assert-True (-not $script:LifecycleRecoveryRequired -and -not (Test-Path (Join-Path $testRoot 'pending-process.json'))) 'Metadata probe invented mutation recovery.'
        function Get-ObservedComponents {@()}
        Set-OperationOutcome 'Failed' 'NDI metadata deadline fixture'
        $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
        Assert-True ($result.outcome -eq 'failed' -and $result.errorCode -eq 'ndi-metadata-timeout' -and $result.operationId -eq [IO.Path]::GetFileName($directory) -and (Get-InstallerExitCode) -eq 1) 'Failure lost correlation or reported success.'
    } finally {$server.Dispose();$script:Lifecycle=$null;$script:probePidPath=$null}
}
Test-Case 'Server preflight emits progress and failure precedes receipts and Windows changes' {
    $script:preflightVisible=$false;$script:unexpectedMutation=$false
    function Get-SavedConfig {$null}
    function Assert-ServerDownloads {param($Config);$script:preflightVisible=$script:ProgressActive;throw 'Fixture source unavailable'}
    function Start-DeploymentJournal {$script:unexpectedMutation=$true}
    function Ensure-WslFeatures {$script:unexpectedMutation=$true}
    $script:Action='Setup';$script:OperationOutcome='Running';$script:OperationFailed=$false
    Assert-Throws {Repair-Suite -RequestedConfiguration ([pscustomobject]@{}) -LicenseAccepted -BringCurrent} 'Fixture source unavailable'
    Assert-True ($script:preflightVisible -and -not $script:ProgressActive -and -not $script:unexpectedMutation) 'Preflight progress or mutation ordering failed.'
}
Test-Case 'Heartbeat persistence failure stops the read-only probe and retains its cause' {
    $server=[NdiHttpFixture]::new($valid,$true,$false)
    $script:probePidPath=Join-Path $testRoot 'heartbeat-failure-probe.pid'
    $script:fixtureUrl=$server.Url;$script:LifecycleErrorCode='';$script:ProgressActive=$false
    function Update-SuiteProgressPulse {
        if(Test-Path -LiteralPath $script:probePidPath){$script:LifecycleErrorCode='lifecycle-result-write-failed';throw 'Fixture heartbeat persistence failed'}
    }
    try {
        Assert-Throws {Get-NdiToolsMetadata -TimeoutSeconds 5} 'heartbeat persistence failed'
        Assert-True ($script:LifecycleErrorCode -eq 'lifecycle-result-write-failed') 'Persistence failure was recast as metadata failure.'
        $probeId=[int](Get-Content -LiteralPath $script:probePidPath)
        Assert-True (-not(Get-Process -Id $probeId -ErrorAction SilentlyContinue)) 'Persistence failure abandoned the read-only child.'
    } finally {$server.Dispose();$script:probePidPath=$null}
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding UTF8
Write-Host ("Results: {0}/{1}; evidence: {2}" -f @($results|Where-Object Passed).Count,$results.Count,$testRoot)
if(@($results|Where-Object {-not $_.Passed}).Count){exit 1}
