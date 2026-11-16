#Requires -Version 7.0
<#
.SYNOPSIS
    Liste les applications en mode Auto ayant un fournisseur (Updater). Sortie GitHub Actions: apps (tableau JSON).

.EXAMPLE
    .\automation\Get-UpdatableApp.ps1
    .\automation\Get-UpdatableApp.ps1 -AppId Zoom
#>
[CmdletBinding()]
param(
    [string]$AppId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$ids = @(
    Get-AhuManifest |
        Where-Object { $_.Manifest.Mode -eq 'Auto' -and (Get-AhuValue $_.Manifest 'Updater') } |
        ForEach-Object { $_.Manifest.Id } |
        Where-Object { -not $AppId -or $_ -eq $AppId }
)

$json = ConvertTo-Json -InputObject $ids -Compress
Write-Host ('Applications a verifier: {0}' -f $json)
Set-AhuActionOutput -Name 'apps' -Value $json
$ids
