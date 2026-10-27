#Requires -Version 5.1
[CmdletBinding()]
param([string]$Path = (Join-Path $PSScriptRoot 'version.json'))
$ErrorActionPreference='Stop'
$metadata=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
$version=[string]$metadata.version
$channel=[string]$metadata.channel
$releaseVersion=if($metadata.releaseVersion){[string]$metadata.releaseVersion}else{$version}
if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'Build version must contain three numeric components.'}
if($channel -ceq 'stable'){
    if($releaseVersion -cne $version){throw 'Stable release identity must match the numeric build version.'}
}elseif($channel -ceq 'development'){
    if($releaseVersion -cnotmatch ('^'+[regex]::Escape($version)+'-dev\.[1-9]\d*$')){throw 'Development release identity must match the build version with a -dev.N suffix.'}
}else{throw 'Build channel must be stable or development.'}
[pscustomobject]@{Version=$version;ReleaseVersion=$releaseVersion;Channel=$channel}
