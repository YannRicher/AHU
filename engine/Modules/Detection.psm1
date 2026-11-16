# AHU - Detection des applications installees et decision de conformite

function Get-AhuUninstallEntry {
    <#
        Lit les entrees "Programmes et fonctionnalites" machine (vues 64 et 32 bits),
        independamment du fait que le script tourne en 32 ou 64 bits.
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

            foreach ($keyName in $root.GetSubKeyNames()) {
                $key = $null
                try {
                    $key = $root.OpenSubKey($keyName)
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
                        RegistryView     = [string]$view
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
        finally {
            if ($null -ne $root) { $root.Close() }
            if ($null -ne $base) { $base.Close() }
        }
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
        if ($Value -like (ConvertTo-AhuLikePattern $p)) { return $true }
    }
    return $false
}

function Find-AhuInstalledApp {
    <#
        Retourne l'entree installee correspondant a l'application (la plus haute version si plusieurs), ou $null.
        Champs du catalogue utilises: DetectionName, DetectionExclude, DetectionPublisher.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [object[]]$Entries
    )

    if (-not $PSBoundParameters.ContainsKey('Entries')) {
        $Entries = @(Get-AhuUninstallEntry)
    }

    $include = @(Get-AhuValue $App 'DetectionName' @())
    $exclude = @(Get-AhuValue $App 'DetectionExclude' @())
    $publisher = @(Get-AhuValue $App 'DetectionPublisher' @())

    $best = $null
    foreach ($entry in $Entries) {
        if (-not (Test-AhuNameMatch -Value $entry.DisplayName -Pattern $include)) { continue }
        if ($exclude.Count -gt 0 -and (Test-AhuNameMatch -Value $entry.DisplayName -Pattern $exclude)) { continue }
        if ($publisher.Count -gt 0 -and -not (Test-AhuNameMatch -Value $entry.Publisher -Pattern $publisher)) { continue }
        if (-not (Test-AhuVersionString $entry.DisplayVersion)) { continue }

        if ($null -eq $best -or (Compare-AhuVersion $entry.DisplayVersion $best.DisplayVersion) -gt 0) {
            $best = $entry
        }
    }

    $best
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
