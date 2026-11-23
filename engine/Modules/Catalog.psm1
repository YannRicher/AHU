# AHU - Lecture et validation du catalogue

$script:AhuSupportedSchemaVersion = 1

function Get-AhuValue {
    <#
        Lit une propriete optionnelle d'un objet JSON. Retourne Default si absente, nulle ou chaine vide.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Name,

        [Parameter(Position = 2)]
        $Default = $null
    )

    if ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) {
            if (-not ($property.Value -is [string] -and $property.Value -eq '')) {
                return $property.Value
            }
        }
    }

    return $Default
}

function Enable-AhuTls12 {
    [CmdletBinding()]
    param()

    try {
        $current = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$current -ne 0 -and ($current -band [Net.SecurityProtocolType]::Tls12) -eq 0) {
            [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
        }
    }
    catch {
        Write-Verbose ('TLS 1.2: {0}' -f $_.Exception.Message)
    }
}

function Test-AhuCatalog {
    <#
        Retourne la liste des erreurs de structure du catalogue (vide si valide).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Catalog
    )

    if ($null -eq $Catalog) {
        'Catalogue vide'
        return
    }

    if ($null -eq (Get-AhuValue $Catalog 'Applications')) {
        "Propriete 'Applications' manquante"
    }

    $schema = Get-AhuValue $Catalog 'SchemaVersion' 1
    if ([int]$schema -gt $script:AhuSupportedSchemaVersion) {
        'SchemaVersion {0} non supportee par ce moteur (maximum {1})' -f $schema, $script:AhuSupportedSchemaVersion
    }
}

function Test-AhuAppDefinition {
    <#
        Retourne la liste des erreurs d'une definition d'application (vide si valide).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App
    )

    $mode = [string](Get-AhuValue $App 'Mode' '')
    if (@('Auto', 'Pinned', 'Manual') -notcontains $mode) {
        "Mode invalide '{0}' (valeurs permises: Auto, Pinned, Manual)" -f $mode
    }

    if (@(Get-AhuValue $App 'DetectionName' @()).Count -eq 0) {
        'DetectionName manquant'
    }

    $conflictAction = [string](Get-AhuValue $App 'ConflictAction' 'Skip')
    if (@('Skip', 'Kill') -notcontains $conflictAction) {
        "ConflictAction invalide '{0}' (valeurs permises: Skip, Kill)" -f $conflictAction
    }

    if ($mode -eq 'Auto' -or $mode -eq 'Pinned') {
        if (-not (Test-AhuVersionString ([string](Get-AhuValue $App 'Version' '')))) {
            'Version manquante ou invalide (obligatoire en mode Auto et Pinned)'
        }

        if ([string](Get-AhuValue $App 'DownloadUrl' '') -notmatch '^https://') {
            'DownloadUrl doit etre une URL https'
        }

        if (@('MSI', 'EXE') -notcontains [string](Get-AhuValue $App 'InstallerType' '')) {
            'InstallerType doit etre MSI ou EXE'
        }

        $sha256 = [string](Get-AhuValue $App 'Sha256' '')
        if ($sha256 -and $sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            'Sha256 invalide (64 caracteres hexadecimaux attendus)'
        }
    }

    $installers = @(Get-AhuValue $App 'Installers' @())
    foreach ($variant in $installers) {
        $locale = [string](Get-AhuValue $variant 'Locale' '')
        if ($locale -notmatch '^[a-z]{2}-[A-Z]{2}$') {
            "Installers: Locale invalide '{0}' (format attendu: fr-CA)" -f $locale
        }
        if ([string](Get-AhuValue $variant 'DownloadUrl' '') -notmatch '^https://') {
            "Installers ({0}): DownloadUrl doit etre une URL https" -f $locale
        }
        $variantHash = [string](Get-AhuValue $variant 'Sha256' '')
        if ($variantHash -and $variantHash -notmatch '^[0-9a-fA-F]{64}$') {
            "Installers ({0}): Sha256 invalide" -f $locale
        }
    }
}

function ConvertFrom-AhuCatalogJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    $catalog = $Json.TrimStart([char]0xFEFF) | ConvertFrom-Json
    $errors = @(Test-AhuCatalog -Catalog $catalog)
    if ($errors.Count -gt 0) {
        throw ($errors -join '; ')
    }

    $catalog
}

function Get-AhuCatalog {
    <#
        Charge le catalogue depuis une URL (GitHub) ou un fichier local.
        En cas d'echec reseau, utilise la derniere copie valide en cache.
    #>
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Path,
        [string]$CacheFile,
        [int]$RetryCount = 3
    )

    $raw = $null
    $source = $null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    if ($Path) {
        $source = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
        $raw = [System.IO.File]::ReadAllText($source, $utf8)
    }
    elseif ($Uri) {
        Enable-AhuTls12
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                $raw = $utf8.GetString($response.RawContentStream.ToArray())
                $source = $Uri
                break
            }
            catch {
                Write-AhuLog ('Echec du telechargement du catalogue (tentative {0}/{1}): {2}' -f $attempt, $RetryCount, $_.Exception.Message) -Level Warning
                if ($attempt -lt $RetryCount) { Start-Sleep -Seconds (5 * $attempt) }
            }
        }
    }
    else {
        throw 'Aucune source de catalogue fournie (Uri ou Path).'
    }

    $catalog = $null
    if ($raw) {
        try {
            $catalog = ConvertFrom-AhuCatalogJson -Json $raw
        }
        catch {
            Write-AhuLog ('Catalogue recu invalide ({0}): {1}' -f $source, $_.Exception.Message) -Level Error
        }

        if ($catalog -and $CacheFile -and -not $Path) {
            try {
                $cacheDirectory = Split-Path -Path $CacheFile -Parent
                if (-not (Test-Path -LiteralPath $cacheDirectory)) {
                    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
                }
                [System.IO.File]::WriteAllText($CacheFile, $raw, $utf8)
            }
            catch {
                Write-AhuLog ('Impossible de mettre le catalogue en cache: {0}' -f $_.Exception.Message) -Level Warning
            }
        }
    }

    if (-not $catalog -and -not $Path -and $CacheFile -and (Test-Path -LiteralPath $CacheFile)) {
        Write-AhuLog ('Utilisation du catalogue en cache: {0}' -f $CacheFile) -Level Warning
        $catalog = ConvertFrom-AhuCatalogJson -Json ([System.IO.File]::ReadAllText($CacheFile, $utf8))
        $source = $CacheFile
    }

    if (-not $catalog) {
        throw ('Catalogue introuvable ou invalide ({0}{1})' -f $Uri, $Path)
    }

    Write-AhuLog ('Catalogue charge depuis {0} ({1} application(s))' -f $source, @($catalog.Applications.PSObject.Properties).Count)
    $catalog
}

function Get-AhuCatalogApp {
    <#
        Retourne les applications du catalogue (toutes, ou celles demandees), avec une propriete Id ajoutee.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Catalog,

        [string[]]$AppId
    )

    $filter = @($AppId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($property in $Catalog.Applications.PSObject.Properties) {
        if ($filter.Count -gt 0 -and $filter -notcontains $property.Name) { continue }
        $app = $property.Value
        $app | Add-Member -NotePropertyName 'Id' -NotePropertyValue $property.Name -Force
        $app
    }
}

Export-ModuleMember -Function Get-AhuValue, Enable-AhuTls12, Test-AhuCatalog, Test-AhuAppDefinition, ConvertFrom-AhuCatalogJson, Get-AhuCatalog, Get-AhuCatalogApp
