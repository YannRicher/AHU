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

function Get-VersionWhitespaceError {
    param($Definition, [string]$Label)
    $version = Get-AhuValue $Definition 'Version'
    if ($null -ne $version -and [string]$version -ne ([string]$version).Trim()) {
        '{0}: Version avec espaces superflus ({1})' -f $Label, ('"{0}"' -f $version)
    }
}

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
    foreach ($message in @(Get-VersionWhitespaceError -Definition $manifest -Label $file)) { if ($message) { $errors.Add($message) } }

    $production = Get-AhuValue $manifest 'Production'
    if ($production) {
        foreach ($message in @(Get-VersionWhitespaceError -Definition $production -Label ('{0} (Production)' -f $file))) { if ($message) { $errors.Add($message) } }
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

# Scripts avant/apres: catalog/hooks/<Id>/PreInstall.ps1 et PostInstall.ps1
$hooksRoot = Join-Path $CatalogRoot 'hooks'
if (Test-Path -LiteralPath $hooksRoot) {
    foreach ($directory in Get-ChildItem -LiteralPath $hooksRoot -Directory) {
        if (-not $ids.ContainsKey($directory.Name)) {
            $errors.Add(('hooks/{0}: aucun manifeste avec cet Id' -f $directory.Name))
        }
        foreach ($file in Get-ChildItem -LiteralPath $directory.FullName -File) {
            if (@('PreInstall.ps1', 'PostInstall.ps1') -notcontains $file.Name) {
                $errors.Add(('hooks/{0}/{1}: nom inattendu (PreInstall.ps1 ou PostInstall.ps1)' -f $directory.Name, $file.Name))
                continue
            }
            foreach ($message in Get-AhuHookError -Path $file.FullName) {
                $errors.Add(('hooks/{0}/{1}: {2}' -f $directory.Name, $file.Name, $message))
            }
        }
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
            foreach ($message in @(Get-VersionWhitespaceError -Definition $property.Value -Label ('{0}: {1}' -f $name, $property.Name))) { if ($message) { $errors.Add($message) } }
            foreach ($phase in 'PreInstall', 'PostInstall') {
                $hook = Get-AhuValue $property.Value $phase
                if (-not $hook) { continue }
                $hookPath = Join-Path $hooksRoot ('{0}\{1}.ps1' -f $property.Name, $phase)
                if (-not (Test-Path -LiteralPath $hookPath)) {
                    $errors.Add(('{0}: {1}: script {2} introuvable dans catalog/hooks' -f $name, $property.Name, $phase))
                }
                elseif ((Get-AhuHookHash -Path $hookPath) -ne ([string](Get-AhuValue $hook 'Sha256' '')).ToUpperInvariant()) {
                    $errors.Add(('{0}: {1}: SHA256 du script {2} different du fichier (executer Build-Catalog.ps1)' -f $name, $property.Name, $phase))
                }
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
