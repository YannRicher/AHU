#Requires -Version 7.0
<#
.SYNOPSIS
    Genere les scripts Intune autonomes (modules du moteur integres), un couple par anneau:
      intune\Detection.ps1 + intune\Remediation.ps1                 => PRODUCTION (apps.json)
      intune\Detection-Pilote.ps1 + intune\Remediation-Pilote.ps1   => PILOTE (apps.pilot.json)

.DESCRIPTION
    Les postes ne telechargent que le catalogue (donnees). Le code execute en SYSTEM est celui
    televerse dans Intune. A regenerer (et a re-televerser dans Intune) seulement lorsque le moteur change.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$modules = 'Logging', 'Version', 'Catalog', 'Detection', 'Hooks', 'Installer', 'Engine'
$baseUrl = 'https://raw.githubusercontent.com/YannRicher/AHU/main/catalog'

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

# Empreinte du code integre (deterministe: pas de date) inscrite dans le journal des postes
$sha = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($body -join "`n")))
$sha.Dispose()
$build = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 8)
$placeholder = '$script:AhuEngineBuild = ''sources'''
$replaced = 0
for ($i = 0; $i -lt $body.Count; $i++) {
    if ($body[$i] -eq $placeholder) {
        $body[$i] = '$script:AhuEngineBuild = ''{0}''' -f $build
        $replaced++
    }
}
if ($replaced -ne 1) { throw 'Marqueur $script:AhuEngineBuild introuvable (ou en double) dans Engine.psm1' }

$outputDirectory = Join-Path $root 'intune'
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$rings = @(
    @{ Name = 'Production'; CatalogUrl = "$baseUrl/apps.json";       Suffix = '' }
    @{ Name = 'Pilote';     CatalogUrl = "$baseUrl/apps.pilot.json"; Suffix = '-Pilote' }
)

$actions = @(
    @{ Action = 'Detect';    Prefix = 'Detection';   Description = 'Detection: code 0 = conforme, 1 = remediation requise' }
    @{ Action = 'Remediate'; Prefix = 'Remediation'; Description = 'Remediation: telecharge et installe les mises a jour requises' }
)

foreach ($ring in $rings) {
    foreach ($target in $actions) {
        $file = '{0}{1}.ps1' -f $target.Prefix, $ring.Suffix
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('<#')
        $lines.Add(('    AHU - {0} - anneau {1}' -f $target.Description, $ring.Name))
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
        $lines.Add(('$AhuCatalogUrl = ''{0}''' -f $ring.CatalogUrl))
        $lines.Add('# Vide = toutes les applications du catalogue presentes sur le poste. Ex.: @(''Zoom'')')
        $lines.Add('$AhuAppIds = @()')
        $lines.Add('# -----------------------')
        $lines.Add('')
        foreach ($line in $body) { $lines.Add($line) }
        $lines.Add(('$ahuResult = Invoke-AhuEngine -Action {0} -CatalogUrl $AhuCatalogUrl -AppId $AhuAppIds' -f $target.Action))
        $lines.Add('Write-Output $ahuResult.Summary')
        $lines.Add('exit $ahuResult.ExitCode')

        $output = Join-Path $outputDirectory $file
        [System.IO.File]::WriteAllText($output, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ('{0} genere ({1:N0} Ko, build {2})' -f $output, ((Get-Item -LiteralPath $output).Length / 1KB), $build)
    }
}
