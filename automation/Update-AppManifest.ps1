#Requires -Version 7.0
<#
.SYNOPSIS
    Verifie si une nouvelle version est publiee pour une application en mode Auto et met a jour son manifeste.

.DESCRIPTION
    Seules les applications en mode Auto avec une section "Updater" sont traitees.
    Les modes Pinned et Manual sont toujours geres par un humain (pull request).

    Sorties GitHub Actions: changed (true/false), manifest (chemin), version.

.EXAMPLE
    .\automation\Update-AppManifest.ps1 -AppId Zoom
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [string]$WorkDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-' + [guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$item = Get-AhuManifest -AppId $AppId
$manifest = $item.Manifest
$relativePath = [System.IO.Path]::GetRelativePath((Get-AhuRepoRoot), $item.Path) -replace '\\', '/'

Set-AhuActionOutput -Name 'changed' -Value 'false'
Set-AhuActionOutput -Name 'manifest' -Value $relativePath

if ($manifest.Mode -ne 'Auto') {
    Write-Host ('{0}: mode {1}, mise a jour automatique ignoree.' -f $AppId, $manifest.Mode)
    return
}

$updater = Get-AhuValue $manifest 'Updater'
if (-not $updater) {
    Write-Host ('{0}: aucune section Updater, mise a jour automatique ignoree.' -f $AppId)
    return
}

$provider = Join-Path $PSScriptRoot ('Providers\{0}.ps1' -f $updater.Type)
if (-not (Test-Path -LiteralPath $provider)) {
    throw ('Fournisseur inconnu: {0}' -f $updater.Type)
}

try {
    $latest = & $provider -Manifest $manifest -Updater $updater -WorkDirectory $WorkDirectory
    $current = [string](Get-AhuValue $manifest 'Version' '')

    if ($latest.Unchanged) {
        Write-Host ('{0}: a jour ({1}).' -f $AppId, $current)
        Add-AhuStepSummary ('| {0} | {1} | a jour |' -f $AppId, $current)
        return
    }

    $comparison = Compare-AhuVersion $latest.Version $current
    if ($comparison -lt 0) {
        Write-Warning ('{0}: version publiee {1} plus ancienne que le catalogue {2}, ignoree.' -f $AppId, $latest.Version, $current)
        return
    }

    # RequireSignature: false = exception explicite (ex. 7-Zip, non signe). Le SHA256 reste verifie.
    $requireSignature = [bool](Get-AhuValue $manifest 'RequireSignature' $true)
    if ($requireSignature -and $latest.SignatureStatus -and $latest.SignatureStatus -ne 'Valid') {
        throw ('{0}: signature invalide ({1}) pour {2}' -f $AppId, $latest.SignatureStatus, $latest.DownloadUrl)
    }

    $expectedSigner = [string](Get-AhuValue $manifest 'SignerSubject' '')
    if ($requireSignature -and $expectedSigner -and $latest.Signer -notlike ('*{0}*' -f $expectedSigner)) {
        throw ('{0}: signataire inattendu ({1}), attendu: {2}' -f $AppId, $latest.Signer, $expectedSigner)
    }

    Set-AhuProperty -InputObject $manifest -Name 'Version' -Value $latest.Version
    Set-AhuProperty -InputObject $manifest -Name 'DownloadUrl' -Value $latest.DownloadUrl
    if ($latest.Sha256) { Set-AhuProperty -InputObject $manifest -Name 'Sha256' -Value $latest.Sha256 }
    Set-AhuProperty -InputObject $manifest -Name 'LastUpdated' -Value (Get-Date -Format 'yyyy-MM-dd')

    Write-AhuJson -Path $item.Path -InputObject $manifest

    Write-Host ('{0}: {1} -> {2} ({3})' -f $AppId, $current, $latest.Version, $latest.DownloadUrl)
    if ($latest.ProductName) { Write-Host ('{0}: ProductName = {1}' -f $AppId, $latest.ProductName) }
    Set-AhuActionOutput -Name 'changed' -Value 'true'
    Set-AhuActionOutput -Name 'version' -Value $latest.Version
    Add-AhuStepSummary ('| {0} | {1} | **{2}** |' -f $AppId, $current, $latest.Version)
}
finally {
    Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
