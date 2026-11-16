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

                $entry = Find-AhuInstalledApp -App $app -Entries $entries
                $installedVersion = if ($entry) { $entry.DisplayVersion } else { $null }
                $decision = Get-AhuAppDecision -App $app -InstalledVersion $installedVersion

                if ($entry -or $explicit -or $decision.NeedsAction) {
                    Write-AhuLog ('{0}: {1}' -f $app.Id, $decision.Message)
                }

                if (-not $decision.NeedsAction) {
                    if ($entry -or $explicit) { $summary.Add(('{0}: {1}' -f $app.Id, $decision.Message)) }
                    continue
                }

                if ($Action -eq 'Detect') {
                    $needsAction = $true
                    $summary.Add(('{0}: {1}' -f $app.Id, $decision.Message))
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

Export-ModuleMember -Function New-AhuEngineResult, Invoke-AhuEngine
