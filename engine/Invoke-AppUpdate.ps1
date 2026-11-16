<#
.SYNOPSIS
    Point d'entree du moteur AHU (detection ou remediation) a partir des modules du depot.

.DESCRIPTION
    Pour Intune, utiliser plutot intune\Detection.ps1 et intune\Remediation.ps1 (generes, autonomes).
    Ce script sert aux tests locaux et au depannage.

.EXAMPLE
    .\Invoke-AppUpdate.ps1 -Action Detect -AppId Zoom -Verbose

.EXAMPLE
    .\Invoke-AppUpdate.ps1 -Action Detect -CatalogPath ..\catalog\apps.json -DataRoot $env:TEMP\AHU
#>
[CmdletBinding()]
param(
    [ValidateSet('Detect', 'Remediate')]
    [string]$Action = 'Detect',

    [string[]]$AppId,

    [string]$CatalogUrl = 'https://raw.githubusercontent.com/YannRicher/AHU/main/catalog/apps.json',

    [string]$CatalogPath,

    [string]$DataRoot = (Join-Path $env:ProgramData 'AHU')
)

foreach ($module in 'Logging', 'Version', 'Catalog', 'Detection', 'Installer', 'Engine') {
    Import-Module (Join-Path $PSScriptRoot ('Modules\{0}.psm1' -f $module)) -Force -Global -DisableNameChecking
}

$result = Invoke-AhuEngine -Action $Action -AppId $AppId -CatalogUrl $CatalogUrl -CatalogPath $CatalogPath -DataRoot $DataRoot
Write-Output $result.Summary
exit $result.ExitCode
