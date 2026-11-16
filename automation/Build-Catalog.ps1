#Requires -Version 7.0
<#
.SYNOPSIS
    Genere catalog\apps.json (lu par les postes) a partir de catalog\settings.json et catalog\applications\*.json.

.DESCRIPTION
    Les manifestes sont la source de verite: ne pas modifier apps.json a la main.
    La section "Updater" (utile seulement a GitHub Actions) n'est pas publiee aux postes.
#>
[CmdletBinding()]
param(
    [string]$CatalogRoot = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'catalog')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$excluded = @('Id', 'Updater')
$applications = [ordered]@{}

foreach ($item in (Get-AhuManifest -CatalogRoot $CatalogRoot | Sort-Object { $_.Manifest.Id })) {
    $id = [string]$item.Manifest.Id
    if (-not $id) { throw ('Propriete Id manquante: {0}' -f $item.Path) }
    if ($applications.Contains($id)) { throw ('Id en double: {0}' -f $id) }

    $definition = [ordered]@{}
    foreach ($property in $item.Manifest.PSObject.Properties) {
        if ($excluded -contains $property.Name) { continue }
        $definition[$property.Name] = $property.Value
    }
    $applications[$id] = $definition
}

$catalog = [ordered]@{
    SchemaVersion = 1
    Settings      = Read-AhuJson -Path (Join-Path $CatalogRoot 'settings.json')
    Applications  = $applications
}

$output = Join-Path $CatalogRoot 'apps.json'
Write-AhuJson -Path $output -InputObject $catalog
Write-Host ('{0} genere ({1} application(s))' -f $output, $applications.Count)
