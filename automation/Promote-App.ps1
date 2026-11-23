#Requires -Version 7.0
<#
.SYNOPSIS
    Promeut la version pilote d'une application vers la production (copie Version/DownloadUrl/Sha256
    dans le bloc Production du manifeste).

.DESCRIPTION
    Sorties GitHub Actions: changed (true/false), version.

.EXAMPLE
    .\automation\Promote-App.ps1 -AppId Zoom
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$item = Get-AhuManifest -AppId $AppId
$manifest = $item.Manifest

Set-AhuActionOutput -Name 'changed' -Value 'false'

if ([string]$manifest.Mode -eq 'Manual') {
    throw ('{0}: mode Manual, rien a promouvoir (aucune version geree).' -f $AppId)
}
if (-not (Test-AhuVersionString ([string](Get-AhuValue $manifest 'Version' '')))) {
    throw ('{0}: version pilote absente, rien a promouvoir.' -f $AppId)
}

$current = Get-AhuValue $manifest 'Production'
$alreadyPromoted = $current -and
    ([string]$current.Version -eq [string]$manifest.Version) -and
    ([string]$current.DownloadUrl -eq [string]$manifest.DownloadUrl) -and
    ([string](Get-AhuValue $current 'Sha256' '') -eq [string](Get-AhuValue $manifest 'Sha256' ''))

if ($alreadyPromoted) {
    Write-Host ('{0}: {1} deja en production.' -f $AppId, $manifest.Version)
    return
}

$block = [pscustomobject]@{
    Version     = [string]$manifest.Version
    DownloadUrl = [string]$manifest.DownloadUrl
    Sha256      = [string](Get-AhuValue $manifest 'Sha256' '')
}
Set-AhuProperty -InputObject $manifest -Name 'Production' -Value $block
Write-AhuJson -Path $item.Path -InputObject $manifest

Write-Host ('{0}: {1} promue en production.' -f $AppId, $manifest.Version)
Set-AhuActionOutput -Name 'changed' -Value 'true'
Set-AhuActionOutput -Name 'version' -Value ([string]$manifest.Version)
