# Pester 5 - regles du depot

BeforeDiscovery {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $scriptFiles = @(Get-ChildItem -Path (Join-Path $root 'engine'), (Join-Path $root 'intune') -Include '*.ps1', '*.psm1' -Recurse |
        ForEach-Object { @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName } })
}

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
}

Describe 'Scripts executes sur les postes' {
    # Windows PowerShell 5.1 lit un fichier UTF-8 sans BOM comme ANSI: les accents seraient corrompus.
    It '<Name> est en ASCII pur' -TestCases $scriptFiles {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It '<Name> est du PowerShell valide' -TestCases $scriptFiles {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
}

Describe 'Catalogues publies' {
    BeforeAll {
        foreach ($module in 'Logging', 'Version', 'Catalog') {
            Import-Module (Join-Path $root ('engine\Modules\{0}.psm1' -f $module)) -Force -Global -DisableNameChecking
        }
    }

    It '<Name> est valide pour le moteur' -TestCases @(
        @{ Name = 'apps.json (production)';   File = 'apps.json' }
        @{ Name = 'apps.pilot.json (pilote)'; File = 'apps.pilot.json' }
    ) {
        $json = [System.IO.File]::ReadAllText((Join-Path $root ('catalog\{0}' -f $File)))
        $catalog = ConvertFrom-AhuCatalogJson -Json $json
        foreach ($property in $catalog.Applications.PSObject.Properties) {
            @(Test-AhuAppDefinition -App $property.Value) | Should -BeNullOrEmpty -Because $property.Name
        }
    }

    It 'les catalogues ne publient jamais le bloc Production ni Updater' {
        foreach ($file in 'apps.json', 'apps.pilot.json') {
            $text = [System.IO.File]::ReadAllText((Join-Path $root ('catalog\{0}' -f $file)))
            $text | Should -Not -Match '"Production"'
            $text | Should -Not -Match '"Updater"'
        }
    }

    It 'les scripts Intune pilote et production pointent vers le bon catalogue' {
        Get-Content -LiteralPath (Join-Path $root 'intune\Detection.ps1') -Raw | Should -Match 'catalog/apps\.json'
        Get-Content -LiteralPath (Join-Path $root 'intune\Remediation.ps1') -Raw | Should -Match 'catalog/apps\.json'
        Get-Content -LiteralPath (Join-Path $root 'intune\Detection-Pilote.ps1') -Raw | Should -Match 'catalog/apps\.pilot\.json'
        Get-Content -LiteralPath (Join-Path $root 'intune\Remediation-Pilote.ps1') -Raw | Should -Match 'catalog/apps\.pilot\.json'
    }
}
