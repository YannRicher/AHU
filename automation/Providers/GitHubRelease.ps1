<#
.SYNOPSIS
    Fournisseur "GitHubRelease": dernier asset d'une release GitHub publique (ex. ip7z/7zip).

.DESCRIPTION
    Manifeste:
        "Updater": { "Type": "GitHubRelease", "Repo": "ip7z/7zip", "AssetPattern": "7z*-x64.exe" }

    1. Interroge l'API GitHub (derniere release publiee).
    2. Choisit l'asset dont le nom correspond a AssetPattern (exactement un doit correspondre).
    3. Si l'URL est identique a DownloadUrl, rien a faire.
    4. Sinon, telecharge le fichier et lit ProductVersion, SHA256 et signature.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    $Manifest,

    [Parameter(Mandatory = $true)]
    $Updater,

    [Parameter(Mandatory = $true)]
    [string]$WorkDirectory
)

$repo = [string](Get-AhuValue $Updater 'Repo' '')
$pattern = [string](Get-AhuValue $Updater 'AssetPattern' '')
if ($repo -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$' -or -not $pattern) {
    throw 'Updater GitHubRelease: Repo (proprietaire/depot) et AssetPattern sont obligatoires.'
}

$headers = @{ 'User-Agent' = 'AHU-updater'; 'Accept' = 'application/vnd.github+json' }
$release = Invoke-RestMethod -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $repo) -Headers $headers -TimeoutSec 60

$assets = @($release.assets | Where-Object { $_.name -like $pattern })
if ($assets.Count -ne 1) {
    throw ('{0}: {1} asset(s) correspondent a {2} dans la release {3} (1 attendu)' -f $repo, $assets.Count, $pattern, $release.tag_name)
}

$finalUrl = [string]$assets[0].browser_download_url
Write-Host ('Release {0} - asset: {1}' -f $release.tag_name, $assets[0].name)

if ($finalUrl -eq (Get-AhuValue $Manifest 'DownloadUrl' '') -and (Test-AhuVersionString (Get-AhuValue $Manifest 'Version' ''))) {
    return [pscustomobject]@{ Unchanged = $true; DownloadUrl = $finalUrl; Version = $Manifest.Version }
}

$file = Save-AhuDownload -Uri $finalUrl -Directory $WorkDirectory
$info = Get-AhuInstallerInfo -Path $file

if (-not (Test-AhuVersionString $info.ProductVersion)) {
    throw ('ProductVersion introuvable dans {0}' -f $file)
}

[pscustomobject]@{
    Unchanged       = $false
    Version         = $info.ProductVersion
    DownloadUrl     = $finalUrl
    Sha256          = $info.Sha256
    SignatureStatus = $info.SignatureStatus
    Signer          = $info.Signer
    ProductName     = $info.ProductName
}
