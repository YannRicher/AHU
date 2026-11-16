<#
.SYNOPSIS
    Met a jour une ou plusieurs applications du catalogue (doit etre execute en administrateur ou SYSTEM).
    Code de sortie: 0 = succes ou report, 1 = echec.

.EXAMPLE
    .\Install-App.ps1 -AppId Zoom
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$AppId,

    [string]$CatalogUrl,

    [string]$CatalogPath,

    [string]$DataRoot
)

& (Join-Path $PSScriptRoot 'Invoke-AppUpdate.ps1') -Action Remediate @PSBoundParameters
exit $LASTEXITCODE
