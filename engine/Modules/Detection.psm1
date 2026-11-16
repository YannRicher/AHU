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

Export-ModuleMember -Function Get-AhuUninstallEntry, ConvertTo-AhuLikePattern, Test-AhuNameMatch, Find-AhuInstalledApp, Get-AhuAppDecision
