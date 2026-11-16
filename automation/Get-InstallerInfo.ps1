#Requires -Version 7.0
<#
.SYNOPSIS
    Aide pour remplir un manifeste Pinned: telecharge un installateur et affiche version, SHA256 et signataire.

.EXAMPLE
    .\automation\Get-InstallerInfo.ps1 -Uri https://exemple.com/setup.msi
    .\automation\Get-InstallerInfo.ps1 -Path C:\Temp\setup.exe
#>
[CmdletBinding(DefaultParameterSetName = 'Uri')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
    [string]$Uri,

    [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
    [string]$Path
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AhuAutomation.psm1') -Force -Global -DisableNameChecking

$workDirectory = $null
try {
    if ($Uri) {
        $workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-' + [guid]::NewGuid().ToString('N'))
        $finalUrl = Resolve-AhuRedirect -Uri $Uri
        Write-Host ('URL finale: {0}' -f $finalUrl)
        $Path = Save-AhuDownload -Uri $finalUrl -Directory $workDirectory
    }
    Get-AhuInstallerInfo -Path $Path
}
finally {
    if ($workDirectory) { Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue }
}
