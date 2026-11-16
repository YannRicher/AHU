# AHU - Fonctions communes pour la maintenance du catalogue (GitHub Actions / poste d'administration)
# Necessite PowerShell 7 sur Windows (lecture des proprietes MSI via COM).

$script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent

foreach ($module in 'Logging', 'Version', 'Catalog') {
    Import-Module (Join-Path $script:RepoRoot ('engine\Modules\{0}.psm1' -f $module)) -Force -Global -DisableNameChecking
}

function Get-AhuRepoRoot {
    $script:RepoRoot
}

function Read-AhuJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Write-AhuJson {
    <#
        Ecriture deterministe: indentation PowerShell 7, fins de ligne LF, UTF-8 sans BOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $InputObject
    )

    $json = ($InputObject | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Get-AhuManifest {
    <#
        Retourne les manifestes catalog\applications\*.json: @{ Path; Manifest }.
    #>
    [CmdletBinding()]
    param(
        [string]$AppId,

        [string]$CatalogRoot = (Join-Path $script:RepoRoot 'catalog')
    )

    $items = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $CatalogRoot 'applications') -Filter '*.json' | Sort-Object Name) {
        [pscustomobject]@{
            Path     = $file.FullName
            Manifest = Read-AhuJson -Path $file.FullName
        }
    }

    if ($AppId) {
        $match = @($items | Where-Object { $_.Manifest.Id -eq $AppId })
        if ($match.Count -eq 0) { throw ('Manifeste introuvable pour {0}' -f $AppId) }
        return $match[0]
    }

    $items
}

function Set-AhuProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        $Value
    )

    if ($InputObject.PSObject.Properties[$Name]) {
        $InputObject.$Name = $Value
    }
    else {
        $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Resolve-AhuRedirect {
    <#
        Suit les redirections HTTP et retourne l'URL finale (ex.: lien "latest" => URL CDN versionnee).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('AHU-Catalog/1.0')
    try {
        $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            [void]$response.EnsureSuccessStatusCode()
            $response.RequestMessage.RequestUri.AbsoluteUri
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $client.Dispose()
    }
}

function Get-AhuMsiProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$Property = @('ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer')
    )

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $null
    try {
        $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $result = [ordered]@{}
        foreach ($name in $Property) {
            $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @("SELECT Value FROM Property WHERE Property = '$name'"))
            try {
                [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                $result[$name] = if ($record) { $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1)) } else { $null }
                [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
            }
            finally {
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
            }
        }
        [pscustomobject]$result
    }
    finally {
        if ($database) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($database) }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Get-AhuInstallerInfo {
    <#
        Informations d'un installateur local: SHA256, signature et (MSI) ProductVersion/ProductName.
        La ProductVersion d'un MSI est exactement la DisplayVersion ecrite dans le registre.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path
    $info = [ordered]@{
        File            = Split-Path -Path $Path -Leaf
        SizeMB          = [Math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
        Sha256          = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        SignatureStatus = [string]$signature.Status
        Signer          = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        ProductName     = $null
        ProductVersion  = $null
        ProductCode     = $null
        Manufacturer    = $null
    }

    if ([System.IO.Path]::GetExtension($Path) -eq '.msi') {
        $msi = Get-AhuMsiProperty -Path $Path
        foreach ($name in 'ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer') { $info[$name] = $msi.$name }
    }
    else {
        $versionInfo = (Get-Item -LiteralPath $Path).VersionInfo
        $info.ProductName = $versionInfo.ProductName
        $info.ProductVersion = $versionInfo.ProductVersion
        $info.Manufacturer = $versionInfo.CompanyName
    }

    [pscustomobject]$info
}

function Save-AhuDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $name = [System.IO.Path]::GetFileName(([uri]$Uri).AbsolutePath)
    if (-not $name) { $name = 'installer.bin' }
    $destination = Join-Path $Directory $name

    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Uri -OutFile $destination -UseBasicParsing -ErrorAction Stop
    $destination
}

function Set-AhuActionOutput {
    <#
        Ecrit une sortie d'etape GitHub Actions (ignore hors GitHub Actions).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowEmptyString()]
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ('{0}={1}' -f $Name, $Value) -Encoding utf8
    }
}

function Add-AhuStepSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Markdown
    )

    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8
    }
}

Export-ModuleMember -Function Get-AhuRepoRoot, Read-AhuJson, Write-AhuJson, Get-AhuManifest, Set-AhuProperty, Resolve-AhuRedirect, Get-AhuMsiProperty, Get-AhuInstallerInfo, Save-AhuDownload, Set-AhuActionOutput, Add-AhuStepSummary
