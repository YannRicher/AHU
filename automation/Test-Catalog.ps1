#Requires -Version 7.0
<#
.SYNOPSIS
    Valide les manifestes et les deux catalogues publies (pilote et production). Code de sortie 1 si erreur.
#>
[CmdletBinding()]
param(
    [string]$CatalogRoot = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'catalog')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$errors = New-Object System.Collections.Generic.List[string]
$ids = @{}

foreach ($item in Get-AhuManifest -CatalogRoot $CatalogRoot) {
    $file = Split-Path -Path $item.Path -Leaf
    $manifest = $item.Manifest
    $id = [string](Get-AhuValue $manifest 'Id' '')

    if (-not $id) {
        $errors.Add(('{0}: Id manquant' -f $file))
        continue
    }
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-_]*$') {
        $errors.Add(('{0}: Id invalide (lettres, chiffres, . - _)' -f $file))
    }
    if ($file -ne ($id.ToLowerInvariant() + '.json')) {
        $errors.Add(('{0}: le nom du fichier doit etre {1}.json' -f $file, $id.ToLowerInvariant()))
    }
    if ($ids.ContainsKey($id)) {
        $errors.Add(('{0}: Id {1} en double' -f $file, $id))
    }
    $ids[$id] = $true

    foreach ($message in Test-AhuAppDefinition -App $manifest) {
        $errors.Add(('{0}: {1}' -f $file, $message))
    }

    $production = Get-AhuValue $manifest 'Production'
    if ($production) {
        $definition = [pscustomobject]@{ Id = $id; Mode = $manifest.Mode; Version = $production.Version; DownloadUrl = $production.DownloadUrl; Sha256 = (Get-AhuValue $production 'Sha256' ''); InstallerType = $manifest.InstallerType; DetectionName = $manifest.DetectionName }
        foreach ($message in Test-AhuAppDefinition -App $definition) {
            $errors.Add(('{0} (Production): {1}' -f $file, $message))
        }
    }

    $updater = Get-AhuValue $manifest 'Updater'
    if ($updater) {
        $type = [string](Get-AhuValue $updater 'Type' '')
        if (-not $type -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot ('Providers\{0}.ps1' -f $type)))) {
            $errors.Add(('{0}: fournisseur Updater.Type inconnu ({1})' -f $file, $type))
        }
    }
    elseif ($manifest.Mode -eq 'Auto') {
        Write-Warning ('{0}: mode Auto sans Updater, la version devra etre mise a jour manuellement.' -f $file)
    }
}

foreach ($name in 'apps.pilot.json', 'apps.json') {
    $published = Join-Path $CatalogRoot $name
    try {
        $catalog = ConvertFrom-AhuCatalogJson -Json (Get-Content -LiteralPath $published -Raw -Encoding utf8)
        foreach ($property in $catalog.Applications.PSObject.Properties) {
            if (-not $ids.ContainsKey($property.Name)) {
                $errors.Add(('{0}: {1} n''a pas de manifeste (executer Build-Catalog.ps1)' -f $name, $property.Name))
            }
            foreach ($message in Test-AhuAppDefinition -App $property.Value) {
                $errors.Add(('{0}: {1}: {2}' -f $name, $property.Name, $message))
            }
        }
    }
    catch {
        $errors.Add(('{0} invalide: {1}' -f $name, $_.Exception.Message))
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ('ERREUR: {0}' -f $_) -ForegroundColor Red }
    exit 1
}

Write-Host ('Catalogues valides ({0} application(s) dans les manifestes).' -f $ids.Count) -ForegroundColor Green
