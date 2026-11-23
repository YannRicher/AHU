<#
.SYNOPSIS
    Genere les deux catalogues publies a partir des manifestes:
      catalog\apps.pilot.json : anneau PILOTE (Version, DownloadUrl, Sha256 du manifeste)
      catalog\apps.json       : PRODUCTION (bloc Production du manifeste)

.DESCRIPTION
    Les manifestes sont la source de verite: ne pas modifier les catalogues a la main.
    - Une application Auto ou Pinned sans bloc Production n'est pas publiee en production (pilote seulement).
    - Une application Manual est publiee dans les deux catalogues (inventaire, aucune action).
    La section "Updater" n'est jamais publiee.
#>
[CmdletBinding()]
param(
    [string]$CatalogRoot = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'catalog')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$excluded = @('Id', 'Updater', 'Production')
$productionFields = @('Version', 'DownloadUrl', 'Sha256')

function ConvertTo-AhuDefinition {
    param(
        [Parameter(Mandatory = $true)]
        $Manifest,

        [hashtable]$Overrides = @{}
    )

    $definition = [ordered]@{}
    foreach ($property in $Manifest.PSObject.Properties) {
        if ($excluded -contains $property.Name) { continue }
        $definition[$property.Name] = $property.Value
    }
    foreach ($name in $Overrides.Keys) { $definition[$name] = $Overrides[$name] }
    $definition
}

$pilot = [ordered]@{}
$production = [ordered]@{}
$seen = @{}

foreach ($item in (Get-AhuManifest -CatalogRoot $CatalogRoot | Sort-Object { $_.Manifest.Id })) {
    $manifest = $item.Manifest
    $id = [string]$manifest.Id
    if (-not $id) { throw ('Propriete Id manquante: {0}' -f $item.Path) }
    if ($seen.ContainsKey($id)) { throw ('Id en double: {0}' -f $id) }
    $seen[$id] = $true

    $pilot[$id] = ConvertTo-AhuDefinition -Manifest $manifest

    $productionBlock = Get-AhuValue $manifest 'Production'
    if ($productionBlock) {
        $overrides = @{}
        foreach ($field in $productionFields) {
            if ($productionBlock.PSObject.Properties[$field]) { $overrides[$field] = $productionBlock.$field }
        }
        $production[$id] = ConvertTo-AhuDefinition -Manifest $manifest -Overrides $overrides
    }
    elseif ([string]$manifest.Mode -eq 'Manual') {
        $production[$id] = ConvertTo-AhuDefinition -Manifest $manifest
    }
    else {
        Write-Host ('{0}: pas de bloc Production, absente de apps.json (pilote seulement)' -f $id) -ForegroundColor Yellow
    }
}

$settings = Read-AhuJson -Path (Join-Path $CatalogRoot 'settings.json')

$rings = @(
    @{ File = 'apps.pilot.json'; Applications = $pilot }
    @{ File = 'apps.json'; Applications = $production }
)

foreach ($ring in $rings) {
    $catalog = [ordered]@{
        SchemaVersion = 1
        Settings      = $settings
        Applications  = $ring.Applications
    }
    $output = Join-Path $CatalogRoot $ring.File
    Write-AhuJson -Path $output -InputObject $catalog
    Write-Host ('{0} genere ({1} application(s))' -f $output, $ring.Applications.Count)
}
