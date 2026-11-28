# AHU - Orchestration (Detect / Remediate) pour Intune Remediations

# Version du moteur: a incrementer a chaque changement de code execute sur les postes
# (apparait dans AHU.log pour savoir quel moteur a roule). Le build est une empreinte du code,
# calculee par automation/Build-IntuneScripts.ps1 ('sources' = modules du depot, hors Intune).
$script:AhuEngineVersion = '1.3.2'
$script:AhuEngineBuild = 'sources'

function Get-AhuEngineVersion {
    [CmdletBinding()]
    param()

    '{0} (build {1})' -f $script:AhuEngineVersion, $script:AhuEngineBuild
}

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
    Write-AhuLog ('===== AHU {0} - moteur {1} - PowerShell {2} ({3} bits) - compte {4} =====' -f $Action, (Get-AhuEngineVersion), $PSVersionTable.PSVersion, ([IntPtr]::Size * 8), [Security.Principal.WindowsIdentity]::GetCurrent().Name)
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
                # -All trie de la plus ancienne a la plus recente: on retient la plus recente
                $entry = if ($matches.Count -gt 0) { $matches[-1] } else { $null }
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

Export-ModuleMember -Function New-AhuEngineResult, Invoke-AhuEngine, Get-AhuEngineVersion
