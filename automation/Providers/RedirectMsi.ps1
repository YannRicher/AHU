<#
.SYNOPSIS
    Fournisseur "RedirectMsi": un lien "latest" stable redirige vers une URL CDN versionnee d'un MSI.

.DESCRIPTION
    Manifeste:
        "Updater": { "Type": "RedirectMsi", "Url": "https://zoom.us/client/latest/ZoomInstallerFull.msi?archType=x64" }

    1. Resout la redirection (requete legere, sans telechargement).
    2. Si l'URL finale est identique a DownloadUrl, rien a faire.
    3. Sinon, telecharge le MSI et lit ProductVersion (= DisplayVersion dans le registre), SHA256 et signature.
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

$finalUrl = Resolve-AhuRedirect -Uri $Updater.Url
Write-Host ('URL resolue: {0}' -f $finalUrl)

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
