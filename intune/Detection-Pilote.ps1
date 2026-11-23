<#
    AHU - Detection: code 0 = conforme, 1 = remediation requise - anneau Pilote

    FICHIER GENERE par automation/Build-IntuneScripts.ps1 - ne pas modifier directement.
    Source: engine/Modules/*.psm1 - https://github.com/YannRicher/AHU

    Intune > Remediations:
      Executer ce script avec les informations d'identification de connexion : Non (SYSTEM)
      Appliquer la verification de signature du script                     : Non
      Executer le script dans PowerShell 64 bits                            : Oui

    Journal: C:\ProgramData\AHU\Logs\AHU.log
#>

# ---- Configuration ----
$AhuCatalogUrl = 'https://raw.githubusercontent.com/YannRicher/AHU/main/catalog/apps.pilot.json'
# Vide = toutes les applications du catalogue presentes sur le poste. Ex.: @('Zoom')
$AhuAppIds = @()
# -----------------------

#region engine/Modules/Logging.psm1
# AHU - Journalisation
# Format: "yyyy-MM-dd HH:mm:ss - message" dans C:\ProgramData\AHU\Logs\AHU.log

$script:AhuLogFile = $null

function Initialize-AhuLog {
    [CmdletBinding()]
    param(
        [string]$LogDirectory = (Join-Path $env:ProgramData 'AHU\Logs'),
        [string]$FileName = 'AHU.log',
        [long]$MaxBytes = 5MB
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $script:AhuLogFile = Join-Path $LogDirectory $FileName

    if ((Test-Path -LiteralPath $script:AhuLogFile) -and ((Get-Item -LiteralPath $script:AhuLogFile).Length -gt $MaxBytes)) {
        Move-Item -LiteralPath $script:AhuLogFile -Destination ($script:AhuLogFile + '.old') -Force
    }

    $script:AhuLogFile
}

function Write-AhuLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $prefix = switch ($Level) {
        'Warning' { '[AVERTISSEMENT] ' }
        'Error'   { '[ERREUR] ' }
        default   { '' }
    }

    $line = '{0} - {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix, $Message
    Write-Verbose $line

    if ($script:AhuLogFile) {
        try {
            [System.IO.File]::AppendAllText($script:AhuLogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-Verbose ('Impossible d''ecrire dans le journal: {0}' -f $_.Exception.Message)
        }
    }
}

#endregion

#region engine/Modules/Version.psm1
# AHU - Comparaison de versions
# Compare n'importe quel format numerique ("7.2.51704", "25.001.20531", "24.09", "8.0.4310.10").
# Les segments non numeriques sont ignores; les segments manquants valent 0.

function ConvertTo-AhuVersionPart {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { return }

    foreach ($match in [regex]::Matches($Version, '\d+')) {
        [decimal]$match.Value
    }
}

function Compare-AhuVersion {
    <#
        Retourne -1 si Version < ReferenceVersion, 0 si egales, 1 si Version > ReferenceVersion.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ReferenceVersion
    )

    [decimal[]]$left = @(ConvertTo-AhuVersionPart $Version)
    [decimal[]]$right = @(ConvertTo-AhuVersionPart $ReferenceVersion)
    $count = [Math]::Max($left.Count, $right.Count)

    for ($i = 0; $i -lt $count; $i++) {
        $a = if ($i -lt $left.Count) { $left[$i] } else { 0 }
        $b = if ($i -lt $right.Count) { $right[$i] } else { 0 }
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }

    return 0
}

function Test-AhuVersionString {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version
    )

    return (-not [string]::IsNullOrWhiteSpace($Version)) -and ($Version -match '\d')
}

#endregion

#region engine/Modules/Catalog.psm1
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

#endregion

#region engine/Modules/Detection.psm1
# AHU - Detection des applications installees et decision de conformite

function Read-AhuUninstallRoot {
    <#
        Lit les entrees d'une cle Uninstall deja ouverte. Scope: Machine ou User.
    #>
    param(
        $RootKey,
        [string]$Scope,
        [string]$UserSid,
        [string]$RegistryView
    )

    foreach ($keyName in $RootKey.GetSubKeyNames()) {
        $key = $null
        try {
            $key = $RootKey.OpenSubKey($keyName)
            if ($null -eq $key) { continue }

            $displayName = [string]$key.GetValue('DisplayName', '')
            if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

            [pscustomobject]@{
                DisplayName      = $displayName.Trim()
                DisplayVersion   = ([string]$key.GetValue('DisplayVersion', '')).Trim()
                Publisher        = [string]$key.GetValue('Publisher', '')
                UninstallString  = [string]$key.GetValue('UninstallString', '')
                WindowsInstaller = ([string]$key.GetValue('WindowsInstaller', '') -eq '1')
                KeyName          = $keyName
                RegistryView     = $RegistryView
                Scope            = $Scope
                UserSid          = $UserSid
            }
        }
        catch {
            Write-Verbose ('Cle ignoree {0}: {1}' -f $keyName, $_.Exception.Message)
        }
        finally {
            if ($null -ne $key) { $key.Close() }
        }
    }
}

function Get-AhuUninstallEntry {
    <#
        Lit "Programmes et fonctionnalites":
          - machine (HKLM, vues 64 et 32 bits)
          - utilisateurs dont la ruche est chargee (HKU\<SID>), y compris en session SYSTEM
        Les profils non charges (utilisateur deconnecte) sont vus au prochain passage, une fois la session ouverte.
    #>
    [CmdletBinding()]
    param()

    $views = @([Microsoft.Win32.RegistryView]::Registry32)
    if ([Environment]::Is64BitOperatingSystem) {
        $views = @([Microsoft.Win32.RegistryView]::Registry64) + $views
    }

    foreach ($view in $views) {
        $base = $null
        $root = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $root = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($null -eq $root) { continue }
            Read-AhuUninstallRoot -RootKey $root -Scope 'Machine' -RegistryView ([string]$view)
        }
        finally {
            if ($null -ne $root) { $root.Close() }
            if ($null -ne $base) { $base.Close() }
        }
    }

    $userView = if ([Environment]::Is64BitOperatingSystem) { [Microsoft.Win32.RegistryView]::Registry64 } else { [Microsoft.Win32.RegistryView]::Registry32 }
    $users = $null
    try {
        $users = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, $userView)
        foreach ($sid in $users.GetSubKeyNames()) {
            if ($sid -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') { continue }

            foreach ($subKey in @(
                    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
                )) {
                $root = $null
                try {
                    $root = $users.OpenSubKey("$sid\$subKey")
                    if ($null -eq $root) { continue }
                    Read-AhuUninstallRoot -RootKey $root -Scope 'User' -UserSid $sid -RegistryView ([string]$userView)
                }
                finally {
                    if ($null -ne $root) { $root.Close() }
                }
            }
        }
    }
    finally {
        if ($null -ne $users) { $users.Close() }
    }
}

function ConvertTo-AhuLikePattern {
    <#
        Sans joker (* ou ?), le motif est une correspondance partielle: "Workplace" => "*Workplace*".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Pattern
    )

    if ($Pattern -match '[\*\?]') { return $Pattern }
    return '*' + [System.Management.Automation.WildcardPattern]::Escape($Pattern) + '*'
}

function Test-AhuNameMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string]$Value,

        [string[]]$Pattern
    )

    foreach ($p in @($Pattern)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        # "=Zoom" : egalite stricte (ne pas confondre avec "Zoom Outlook Plugin")
        if ($p.StartsWith('=')) {
            if ($Value -eq $p.Substring(1)) { return $true }
            continue
        }
        if ($Value -like (ConvertTo-AhuLikePattern $p)) { return $true }
    }
    return $false
}

function Find-AhuInstalledApp {
    <#
        Retourne l'entree installee correspondant a l'application.
        Sans -All: la plus haute version (ou $null).
        Avec -All: toutes les correspondances, la plus ancienne en premier.
        Champs du catalogue: DetectionName (=Nom pour une egalite stricte), DetectionExclude, DetectionPublisher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [object[]]$Entries,

        [switch]$All
    )

    if (-not $PSBoundParameters.ContainsKey('Entries')) {
        $Entries = @(Get-AhuUninstallEntry)
    }

    $include = @(Get-AhuValue $App 'DetectionName' @())
    $exclude = @(Get-AhuValue $App 'DetectionExclude' @())
    $publisher = @(Get-AhuValue $App 'DetectionPublisher' @())

    $found = foreach ($entry in $Entries) {
        if (-not (Test-AhuNameMatch -Value $entry.DisplayName -Pattern $include)) { continue }
        if ($exclude.Count -gt 0 -and (Test-AhuNameMatch -Value $entry.DisplayName -Pattern $exclude)) { continue }
        if ($publisher.Count -gt 0 -and -not (Test-AhuNameMatch -Value $entry.Publisher -Pattern $publisher)) { continue }
        if (-not (Test-AhuVersionString $entry.DisplayVersion)) { continue }
        $entry
    }

    $sorted = @($found | Sort-Object -Property @{
            Expression = {
                $parts = @(ConvertTo-AhuVersionPart $_.DisplayVersion)
                (@($parts | ForEach-Object { '{0:D12}' -f [int64]$_ })) -join '.'
            }
        })

    if ($sorted.Count -eq 0) { return }
    if ($All) { return $sorted }
    return $sorted[-1]
}

function Get-AhuAppDecision {
    <#
        Decision pure (sans effet de bord) a partir de la definition du catalogue et de la version locale.
        Status: Disabled, Manual, NotInstalled, Install, Invalid, Update, UpToDate, Newer
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstalledVersion
    )

    $mode = [string](Get-AhuValue $App 'Mode' 'Manual')
    $target = [string](Get-AhuValue $App 'Version' '')
    $isInstalled = -not [string]::IsNullOrWhiteSpace($InstalledVersion)

    $status = $null
    $needsAction = $false
    $message = $null

    if (-not [bool](Get-AhuValue $App 'Enabled' $true)) {
        $status = 'Disabled'
        $message = 'desactivee dans le catalogue'
    }
    elseif ($mode -eq 'Manual') {
        if ($isInstalled) {
            $status = 'Manual'
            $message = 'version {0} detectee - mode Manual, aucune action' -f $InstalledVersion
        }
        else {
            $status = 'NotInstalled'
            $message = 'non installee'
        }
    }
    elseif (-not $isInstalled) {
        if ([bool](Get-AhuValue $App 'InstallIfMissing' $false)) {
            $status = 'Install'
            $needsAction = $true
            $message = 'non installee - installation requise (version {0})' -f $target
        }
        else {
            $status = 'NotInstalled'
            $message = 'non installee'
        }
    }
    elseif (-not (Test-AhuVersionString $target)) {
        $status = 'Invalid'
        $message = 'version {0} detectee - version cible absente du catalogue' -f $InstalledVersion
    }
    else {
        $comparison = Compare-AhuVersion $InstalledVersion $target
        if ($comparison -lt 0) {
            $status = 'Update'
            $needsAction = $true
            $message = 'version {0} detectee - mise a jour requise vers {1} (mode {2})' -f $InstalledVersion, $target, $mode
        }
        elseif ($comparison -eq 0) {
            $status = 'UpToDate'
            $message = 'version {0} detectee - a jour (mode {1})' -f $InstalledVersion, $mode
        }
        else {
            $status = 'Newer'
            $message = 'version {0} detectee - plus recente que la cible {1} (mode {2}), aucune action' -f $InstalledVersion, $target, $mode
        }
    }

    [pscustomobject]@{
        Status           = $status
        NeedsAction      = $needsAction
        Mode             = $mode
        InstalledVersion = $InstalledVersion
        TargetVersion    = $target
        Message          = $message
    }
}

#endregion

#region engine/Modules/Installer.psm1
# AHU - Telechargement et installation silencieuse (MSI / EXE)

function New-AhuInstallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Installed', 'Deferred', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$ExitCode = -1,

        [bool]$RebootRequired = $false
    )

    [pscustomobject]@{
        Status         = $Status
        Message        = $Message
        ExitCode       = $ExitCode
        RebootRequired = $RebootRequired
    }
}

function Save-AhuFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [int]$RetryCount = 3
    )

    Enable-AhuTls12

    $directory = Split-Path -Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $partial = $Destination + '.part'
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing -ErrorAction Stop
                Move-Item -LiteralPath $partial -Destination $Destination -Force
                return
            }
            catch {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                if ($attempt -ge $RetryCount) { throw }
                Write-AhuLog ('Echec du telechargement (tentative {0}/{1}): {2}' -f $attempt, $RetryCount, $_.Exception.Message) -Level Warning
                Start-Sleep -Seconds (10 * $attempt)
            }
        }
    }
    finally {
        $ProgressPreference = $previousProgress
    }
}

function Get-AhuInstallerFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App
    )

    $type = ([string](Get-AhuValue $App 'InstallerType' 'EXE')).ToLowerInvariant()
    $name = $null
    try {
        $name = [System.IO.Path]::GetFileName(([uri][string](Get-AhuValue $App 'DownloadUrl' '')).AbsolutePath)
    }
    catch {
        $name = $null
    }

    if ($name) {
        foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '') }
    }

    if (-not $name -or [System.IO.Path]::GetExtension($name).ToLowerInvariant() -ne ('.' + $type)) {
        $name = '{0}-setup.{1}' -f $App.Id, $type
    }

    $name
}

function Get-AhuConflictingProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App
    )

    foreach ($name in @(Get-AhuValue $App 'ConflictingProcesses' @())) {
        $processName = [System.IO.Path]::GetFileNameWithoutExtension([string]$name)
        if ($processName) {
            Get-Process -Name $processName -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AhuProcess {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [AllowEmptyString()]
        [string]$Arguments = '',

        [int]$TimeoutMinutes = 30
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = Split-Path -Path $FilePath -Parent

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
            throw ('delai d''installation depasse ({0} min)' -f $TimeoutMinutes)
        }
        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Split-AhuUninstallCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $commandLine = $CommandLine.Trim()
    if ($commandLine -match '^"([^"]+)"(?:\s+(.*))?$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = [string]$Matches[2] }
    }

    $parts = $commandLine -split '\s+', 2
    [pscustomobject]@{
        FilePath  = $parts[0]
        Arguments = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
    }
}

function Uninstall-AhuUserInstall {
    <#
        Desinstalle une copie par utilisateur (HKCU) via sa UninstallString, en silencieux.
        Utilise quand ReplaceUserInstall est vrai, pour remplacer la copie personnelle par l'installation machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        $Entry
    )

    $commandLine = [string]$Entry.UninstallString
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        Write-AhuLog ('{0}: installation utilisateur {1} sans UninstallString' -f $App.Id, $Entry.DisplayVersion) -Level Warning
        return $false
    }

    $command = Split-AhuUninstallCommand -CommandLine $commandLine
    if (-not (Test-Path -LiteralPath $command.FilePath)) {
        Write-AhuLog ('{0}: desinstallateur introuvable ({1})' -f $App.Id, $command.FilePath) -Level Warning
        return $false
    }

    $arguments = $command.Arguments
    if ($arguments -notmatch '(?i)(^|\s)(/silent|/quiet|/qn)(\s|$)') {
        $arguments = ('{0} /silent' -f $arguments).Trim()
    }

    try {
        Write-AhuLog ('{0}: desinstallation de l''installation utilisateur {1} ({2} {3})' -f $App.Id, $Entry.DisplayVersion, $command.FilePath, $arguments)
        $exitCode = Invoke-AhuProcess -FilePath $command.FilePath -Arguments $arguments -TimeoutMinutes 15
        if ($exitCode -ne 0) {
            Write-AhuLog ('{0}: desinstallation utilisateur terminee avec le code {1}' -f $App.Id, $exitCode) -Level Warning
            return $false
        }
        Write-AhuLog ('{0}: installation utilisateur {1} retiree' -f $App.Id, $Entry.DisplayVersion)
        return $true
    }
    catch {
        Write-AhuLog ('{0}: echec de la desinstallation utilisateur - {1}' -f $App.Id, $_.Exception.Message) -Level Error
        return $false
    }
}

function Remove-AhuStaleCache {
    <#
        Supprime les dossiers de cache d'une application qui ne correspondent pas a la version cible.
        Exemple: un MSI 7.1 reste apres un echec, puis la cible passe a 7.2 => le dossier 7.1 est supprime.
        Le dossier de la version cible est conserve pour reprendre sans retelecharger.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string]$TargetVersion,

        [Parameter(Mandatory = $true)]
        [string]$DataRoot
    )

    $appCache = Join-Path $DataRoot ('Cache\{0}' -f $AppId)
    if (-not (Test-Path -LiteralPath $appCache)) { return 0 }

    $removed = 0
    foreach ($directory in @(Get-ChildItem -LiteralPath $appCache -Directory)) {
        if ($directory.Name -eq $TargetVersion) { continue }
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $directory.FullName)) { $removed++ }
    }
    return $removed
}

function Remove-AhuOldMsiLog {
    <#
        Ne garde que les $Keep journaux MSI les plus recents par application.
        Fichiers attendus: <Id>-<version>-msi.log
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [int]$Keep = 2
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) { return 0 }

    $removed = 0
    $files = @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*-msi.log' -File)
    $groups = $files | Group-Object -Property {
        $m = [regex]::Match($_.Name, '^(.+)-[^-]+-msi\.log$')
        if ($m.Success) { $m.Groups[1].Value } else { $_.Name }
    }

    foreach ($group in $groups) {
        $old = @($group.Group | Sort-Object -Property LastWriteTime -Descending | Select-Object -Skip $Keep)
        foreach ($file in $old) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $file.FullName)) { $removed++ }
        }
    }
    return $removed
}

function Get-AhuLanguageOrder {
    <#
        Ordre de preference des langues d'installation:
          1. langue du systeme (UI du systeme, lue sous SYSTEM)
          2. fr-CA, 3. fr-FR, 4. en-US
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$SystemLocale = [System.Globalization.CultureInfo]::InstalledUICulture.Name
    )

    $fallback = @('fr-CA', 'fr-FR', 'en-US')
    @($SystemLocale) + $fallback | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Select-AhuInstallerVariant {
    <#
        Si l'application a des installateurs par langue (Installers), retourne une copie avec
        DownloadUrl, Sha256, InstallerType et InstallArguments de la langue retenue.
        Sinon, retourne l'application telle quelle (installateur par defaut).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [string[]]$LanguageOrder = (Get-AhuLanguageOrder)
    )

    $variants = @(Get-AhuValue $App 'Installers' @())
    if ($variants.Count -eq 0) { return $App }

    foreach ($locale in $LanguageOrder) {
        $match = $variants | Where-Object { [string]$_.Locale -eq $locale } | Select-Object -First 1
        if (-not $match) { continue }

        $resolved = $App.PSObject.Copy()
        foreach ($name in 'DownloadUrl', 'Sha256', 'InstallerType', 'InstallArguments') {
            if ($match.PSObject.Properties[$name]) {
                $resolved | Add-Member -NotePropertyName $name -NotePropertyValue $match.$name -Force
            }
        }
        $resolved | Add-Member -NotePropertyName 'SelectedLocale' -NotePropertyValue $locale -Force
        return $resolved
    }

    return $App
}

function Install-AhuApp {
    <#
        Telecharge, verifie (SHA256 + signature Authenticode) et installe silencieusement une application du catalogue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [string]$DataRoot = (Join-Path $env:ProgramData 'AHU')
    )

    $App = Select-AhuInstallerVariant -App $App
    $id = $App.Id
    if ($App.PSObject.Properties['SelectedLocale']) {
        Write-AhuLog ('{0}: installateur {1} retenu (langue systeme {2})' -f $id, $App.SelectedLocale, [System.Globalization.CultureInfo]::InstalledUICulture.Name)
    }
    $version = [string](Get-AhuValue $App 'Version' '')
    $type = ([string](Get-AhuValue $App 'InstallerType' '')).ToUpperInvariant()
    $url = [string](Get-AhuValue $App 'DownloadUrl' '')

    # 1. Processus en conflit (ex.: Zoom ouvert pendant une reunion)
    $conflicts = @(Get-AhuConflictingProcess -App $App)
    if ($conflicts.Count -gt 0) {
        $names = (@($conflicts | ForEach-Object { $_.ProcessName } | Select-Object -Unique)) -join ', '
        if ([string](Get-AhuValue $App 'ConflictAction' 'Skip') -eq 'Kill') {
            Write-AhuLog ('{0}: fermeture des processus en conflit ({1})' -f $id, $names)
            $conflicts | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        else {
            $message = 'installation reportee, processus en cours d''execution: {0}' -f $names
            Write-AhuLog ('{0}: {1}' -f $id, $message) -Level Warning
            return New-AhuInstallResult -Status Deferred -Message $message
        }
    }

    $appCache = Join-Path $DataRoot ('Cache\{0}' -f $id)
    $installer = Join-Path (Join-Path $appCache $version) (Get-AhuInstallerFileName -App $App)
    $expectedHash = [string](Get-AhuValue $App 'Sha256' '')

    $staleCache = Remove-AhuStaleCache -AppId $id -TargetVersion $version -DataRoot $DataRoot
    if ($staleCache -gt 0) {
        Write-AhuLog ('{0}: {1} ancien(s) dossier(s) de cache supprime(s)' -f $id, $staleCache)
    }

    try {
        # 2. Telechargement (reutilise le cache si le hash correspond)
        $reuse = $false
        if ($expectedHash -and (Test-Path -LiteralPath $installer)) {
            $reuse = ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -eq $expectedHash.ToUpperInvariant())
        }

        if ($reuse) {
            Write-AhuLog ('{0}: installateur deja en cache ({1})' -f $id, $installer)
        }
        else {
            Write-AhuLog ('{0}: telechargement demarre ({1})' -f $id, $url)
            Save-AhuFile -Uri $url -Destination $installer
            Write-AhuLog ('{0}: telechargement termine ({1:N1} Mo)' -f $id, ((Get-Item -LiteralPath $installer).Length / 1MB))
        }

        # 3. Integrite
        if ($expectedHash) {
            $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                throw ('SHA256 invalide (attendu {0}, obtenu {1})' -f $expectedHash, $actualHash)
            }
            Write-AhuLog ('{0}: SHA256 verifie' -f $id)
        }

        if ([bool](Get-AhuValue $App 'RequireSignature' $true)) {
            $signature = Get-AuthenticodeSignature -FilePath $installer
            $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
            if ($signature.Status -ne 'Valid') {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                throw ('signature Authenticode invalide ({0})' -f $signature.Status)
            }
            $expectedSigner = [string](Get-AhuValue $App 'SignerSubject' '')
            if ($expectedSigner -and $subject -notlike ('*{0}*' -f $expectedSigner)) {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                throw ('signataire inattendu ({0}), attendu: {1}' -f $subject, $expectedSigner)
            }
            Write-AhuLog ('{0}: signature valide ({1})' -f $id, $subject)
        }

        # 4. Installation
        $installArguments = [string](Get-AhuValue $App 'InstallArguments' '')
        if ($type -eq 'MSI') {
            $logDirectory = Join-Path $DataRoot 'Logs'
            # 2 anciens journaux conserves + le nouveau = 3 au maximum par application
            [void](Remove-AhuOldMsiLog -LogDirectory $logDirectory -Keep 2)
            $msiLog = Join-Path $logDirectory ('{0}-{1}-msi.log' -f $id, $version)
            $filePath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
            $arguments = ('/i "{0}" {1} /L*v "{2}"' -f $installer, $installArguments, $msiLog).Trim()
        }
        else {
            $filePath = $installer
            $arguments = $installArguments
        }

        Write-AhuLog ('{0}: installation demarree ({1} {2})' -f $id, (Split-Path -Path $filePath -Leaf), $arguments)
        $exitCode = Invoke-AhuProcess -FilePath $filePath -Arguments $arguments -TimeoutMinutes ([int](Get-AhuValue $App 'InstallTimeoutMinutes' 30))

        $successCodes = @(Get-AhuValue $App 'SuccessExitCodes' @(0, 1641, 3010) | ForEach-Object { [int]$_ })
        $rebootRequired = @(1641, 3010) -contains $exitCode
        if ($successCodes -notcontains $exitCode) {
            if ($exitCode -eq 1618) {
                throw 'une autre installation est deja en cours (code 1618), nouvel essai au prochain cycle'
            }
            throw ('echec de l''installateur (code de sortie {0})' -f $exitCode)
        }

        # 5. Verification apres installation
        $entry = Find-AhuInstalledApp -App $App
        if ($null -eq $entry -or (Compare-AhuVersion $entry.DisplayVersion $version) -lt 0) {
            $found = if ($entry) { $entry.DisplayVersion } else { 'aucune' }
            throw ('installation terminee (code {0}) mais version detectee: {1}' -f $exitCode, $found)
        }

        $message = 'installation completee, version {0} detectee' -f $entry.DisplayVersion
        if ($rebootRequired) { $message += ' (redemarrage requis)' }
        Write-AhuLog ('{0}: {1}' -f $id, $message)

        Remove-Item -LiteralPath $appCache -Recurse -Force -ErrorAction SilentlyContinue
        return New-AhuInstallResult -Status Installed -Message $message -ExitCode $exitCode -RebootRequired $rebootRequired
    }
    catch {
        $message = 'echec: {0}' -f $_.Exception.Message
        Write-AhuLog ('{0}: {1}' -f $id, $message) -Level Error
        return New-AhuInstallResult -Status Failed -Message $message
    }
}

#endregion

#region engine/Modules/Engine.psm1
# AHU - Orchestration (Detect / Remediate) pour Intune Remediations

function New-AhuEngineResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [string]$Summary
    )

    # Intune conserve au plus 2048 caracteres de sortie
    if ($Summary.Length -gt 2000) { $Summary = $Summary.Substring(0, 1997) + '...' }

    [pscustomobject]@{
        ExitCode = $ExitCode
        Summary  = $Summary
    }
}

function Invoke-AhuEngine {
    <#
        Detect    : code 0 = conforme, 1 = remediation requise
        Remediate : code 0 = succes (ou report), 1 = au moins un echec
        AppId vide = toutes les applications du catalogue presentes sur le poste.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Detect', 'Remediate')]
        [string]$Action,

        [string]$CatalogUrl,

        [string]$CatalogPath,

        [string[]]$AppId,

        [string]$DataRoot = (Join-Path $env:ProgramData 'AHU')
    )

    $AppId = @($AppId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $explicit = $AppId.Count -gt 0

    Initialize-AhuLog -LogDirectory (Join-Path $DataRoot 'Logs') | Out-Null
    Write-AhuLog ('===== AHU {0} - PowerShell {1} ({2} bits) - compte {3} =====' -f $Action, $PSVersionTable.PSVersion, ([IntPtr]::Size * 8), [Security.Principal.WindowsIdentity]::GetCurrent().Name)

    $mutex = $null
    $ownsMutex = $false
    if ($Action -eq 'Remediate') {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\AHU-Remediation')
        try { $ownsMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) {
            $mutex.Dispose()
            Write-AhuLog 'Une remediation AHU est deja en cours, arret.' -Level Warning
            return New-AhuEngineResult -ExitCode 0 -Summary 'Remediation AHU deja en cours'
        }
    }

    try {
        try {
            $catalog = Get-AhuCatalog -Uri $CatalogUrl -Path $CatalogPath -CacheFile (Join-Path $DataRoot 'Cache\apps.json')
        }
        catch {
            $message = 'Catalogue AHU inaccessible: {0}' -f $_.Exception.Message
            Write-AhuLog $message -Level Error
            return New-AhuEngineResult -ExitCode 1 -Summary $message
        }

        if ([bool](Get-AhuValue (Get-AhuValue $catalog 'Settings') 'Paused' $false)) {
            Write-AhuLog 'Catalogue en pause (Settings.Paused = true), aucune action.'
            return New-AhuEngineResult -ExitCode 0 -Summary 'Catalogue AHU en pause'
        }

        $apps = @(Get-AhuCatalogApp -Catalog $catalog -AppId $AppId)
        foreach ($requested in $AppId) {
            if (-not ($apps | Where-Object { $_.Id -eq $requested })) {
                Write-AhuLog ('{0}: application absente du catalogue' -f $requested) -Level Warning
            }
        }

        $entries = @(Get-AhuUninstallEntry)
        $summary = New-Object System.Collections.Generic.List[string]
        $needsAction = $false
        $failed = $false

        foreach ($app in $apps) {
            try {
                $definitionErrors = @(Test-AhuAppDefinition -App $app)
                if ($definitionErrors.Count -gt 0) {
                    Write-AhuLog ('{0}: definition invalide, application ignoree - {1}' -f $app.Id, ($definitionErrors -join '; ')) -Level Warning
                    if ($explicit) { $summary.Add(('{0}: definition invalide' -f $app.Id)) }
                    continue
                }

                $matches = @(Find-AhuInstalledApp -App $app -Entries $entries -All)
                $entry = if ($matches.Count -gt 0) { $matches[0] } else { $null }
                $installedVersion = if ($entry) { $entry.DisplayVersion } else { $null }
                $decision = Get-AhuAppDecision -App $app -InstalledVersion $installedVersion
                $detail = $decision.Message
                if ($entry.Scope -eq 'User') { $detail = $detail -replace 'detectee', 'detectee [installation utilisateur]' }

                if ($entry -or $explicit -or $decision.NeedsAction) {
                    Write-AhuLog ('{0}: {1}' -f $app.Id, $detail)
                }

                if (-not $decision.NeedsAction) {
                    if ($entry -or $explicit) { $summary.Add(('{0}: {1}' -f $app.Id, $detail)) }
                    continue
                }

                if ($Action -eq 'Detect') {
                    $needsAction = $true
                    $summary.Add(('{0}: {1}' -f $app.Id, $detail))
                    continue
                }

                $userMatches = @($matches | Where-Object { $_.Scope -eq 'User' })
                if ($userMatches.Count -gt 0 -and [bool](Get-AhuValue $app 'ReplaceUserInstall' $false)) {
                    $conflicts = @(Get-AhuConflictingProcess -App $app)
                    if ($conflicts.Count -gt 0 -and [string](Get-AhuValue $app 'ConflictAction' 'Skip') -eq 'Skip') {
                        $names = (@($conflicts | ForEach-Object { $_.ProcessName } | Select-Object -Unique)) -join ', '
                        $deferred = 'installation reportee, processus en cours d''execution: {0}' -f $names
                        Write-AhuLog ('{0}: {1}' -f $app.Id, $deferred) -Level Warning
                        $summary.Add(('{0}: {1}' -f $app.Id, $deferred))
                        continue
                    }

                    foreach ($userEntry in $userMatches) {
                        if (-not (Uninstall-AhuUserInstall -App $app -Entry $userEntry)) { $failed = $true }
                    }
                }

                $machineEntries = @(Get-AhuUninstallEntry | Where-Object { $_.Scope -eq 'Machine' })
                $machine = Find-AhuInstalledApp -App $app -Entries $machineEntries
                $target = [string](Get-AhuValue $app 'Version' '')
                $machineBehind = ($null -eq $machine) -or ((Compare-AhuVersion $machine.DisplayVersion $target) -lt 0)
                if (-not $machineBehind) {
                    $kept = 'version machine {0} deja a jour' -f $machine.DisplayVersion
                    Write-AhuLog ('{0}: {1}' -f $app.Id, $kept)
                    $summary.Add(('{0}: {1}' -f $app.Id, $kept))
                    continue
                }

                $result = Install-AhuApp -App $app -DataRoot $DataRoot
                $summary.Add(('{0}: {1}' -f $app.Id, $result.Message))
                if ($result.Status -eq 'Failed') { $failed = $true }
            }
            catch {
                $failed = $true
                Write-AhuLog ('{0}: erreur inattendue - {1}' -f $app.Id, $_.Exception.Message) -Level Error
                $summary.Add(('{0}: erreur - {1}' -f $app.Id, $_.Exception.Message))
            }
        }

        if ($summary.Count -eq 0) { $summary.Add('Aucune application du catalogue detectee sur ce poste') }

        if ($Action -eq 'Detect') {
            $exitCode = if ($needsAction -or $failed) { 1 } else { 0 }
            $prefix = if ($exitCode -eq 0) { 'Conforme' } else { 'Non conforme' }
        }
        else {
            $exitCode = if ($failed) { 1 } else { 0 }
            $prefix = if ($exitCode -eq 0) { 'Remediation terminee' } else { 'Remediation en echec' }
        }

        Write-AhuLog ('Resultat {0}: code {1}' -f $Action, $exitCode)
        return New-AhuEngineResult -ExitCode $exitCode -Summary ('{0} - {1}' -f $prefix, ($summary -join ' | '))
    }
    finally {
        if ($ownsMutex) {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
    }
}

#endregion

$ahuResult = Invoke-AhuEngine -Action Detect -CatalogUrl $AhuCatalogUrl -AppId $AhuAppIds
Write-Output $ahuResult.Summary
exit $ahuResult.ExitCode
