#Requires -Version 7.0
<#
.SYNOPSIS
    Genere intune\Detection.ps1 et intune\Remediation.ps1: scripts autonomes (modules du moteur integres).

.DESCRIPTION
    Les postes ne telechargent que le catalogue (donnees). Le code execute en SYSTEM est celui
    televerse dans Intune, ce qui evite d'executer du code recupere dynamiquement depuis GitHub.
    A regenerer (et a re-televerser dans Intune) seulement lorsque le moteur change.
#>
[CmdletBinding()]
param(
    [string]$CatalogUrl = 'https://raw.githubusercontent.com/YannRicher/AHU/main/catalog/apps.json'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$modules = 'Logging', 'Version', 'Catalog', 'Detection', 'Installer', 'Engine'

$body = New-Object System.Collections.Generic.List[string]
foreach ($module in $modules) {
    $relative = 'engine/Modules/{0}.psm1' -f $module
    $body.Add(('#region {0}' -f $relative))
    foreach ($line in Get-Content -LiteralPath (Join-Path $root $relative) -Encoding utf8) {
        if ($line -match '^\s*Export-ModuleMember\b') { continue }
        $body.Add($line.TrimEnd())
    }
    $body.Add('#endregion')
    $body.Add('')
}

$outputDirectory = Join-Path $root 'intune'
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$targets = @(
    @{ Action = 'Detect';    File = 'Detection.ps1';   Description = 'Detection: code 0 = conforme, 1 = remediation requise' }
    @{ Action = 'Remediate'; File = 'Remediation.ps1'; Description = 'Remediation: telecharge et installe les mises a jour requises' }
)

foreach ($target in $targets) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<#')
    $lines.Add(('    AHU - {0}' -f $target.Description))
    $lines.Add('')
    $lines.Add('    FICHIER GENERE par automation/Build-IntuneScripts.ps1 - ne pas modifier directement.')
    $lines.Add('    Source: engine/Modules/*.psm1 - https://github.com/YannRicher/AHU')
    $lines.Add('')
    $lines.Add('    Intune > Remediations:')
    $lines.Add('      Executer ce script avec les informations d''identification de connexion : Non (SYSTEM)')
    $lines.Add('      Appliquer la verification de signature du script                     : Non')
    $lines.Add('      Executer le script dans PowerShell 64 bits                            : Oui')
    $lines.Add('')
    $lines.Add('    Journal: C:\ProgramData\AHU\Logs\AHU.log')
    $lines.Add('#>')
    $lines.Add('')
    $lines.Add('# ---- Configuration ----')
    $lines.Add(('$AhuCatalogUrl = ''{0}''' -f $CatalogUrl))
    $lines.Add('# Vide = toutes les applications du catalogue presentes sur le poste. Ex.: @(''Zoom'')')
    $lines.Add('$AhuAppIds = @()')
    $lines.Add('# -----------------------')
    $lines.Add('')
    $lines.AddRange($body)
    $lines.Add(('$ahuResult = Invoke-AhuEngine -Action {0} -CatalogUrl $AhuCatalogUrl -AppId $AhuAppIds' -f $target.Action))
    $lines.Add('Write-Output $ahuResult.Summary')
    $lines.Add('exit $ahuResult.ExitCode')

    $output = Join-Path $outputDirectory $target.File
    [System.IO.File]::WriteAllText($output, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('{0} genere ({1:N0} Ko)' -f $output, ((Get-Item -LiteralPath $output).Length / 1KB))
}
