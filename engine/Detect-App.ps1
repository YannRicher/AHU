<#
.SYNOPSIS
    Detecte si une ou plusieurs applications du catalogue doivent etre mises a jour.
    Code de sortie: 0 = conforme, 1 = remediation requise.

.EXAMPLE
    .\Detect-App.ps1 -AppId Zoom
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$AppId,

    [string]$CatalogUrl,

    [string]$CatalogPath,

    [string]$DataRoot
)

& (Join-Path $PSScriptRoot 'Invoke-AppUpdate.ps1') -Action Detect @PSBoundParameters
exit $LASTEXITCODE
