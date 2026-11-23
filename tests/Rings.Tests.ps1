# Pester 5 - anneaux pilote / production (Build-Catalog.ps1 sur un dossier temporaire)

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $buildScript = Join-Path $root 'automation\Build-Catalog.ps1'

    function New-RingFixture {
        param([hashtable]$Manifests)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-Rings-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'applications') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'settings.json') -Value '{ "Paused": false }' -Encoding utf8
        foreach ($name in $Manifests.Keys) {
            $json = $Manifests[$name] | ConvertTo-Json -Depth 10
            Set-Content -LiteralPath (Join-Path $dir ('applications\{0}.json' -f $name)) -Value $json -Encoding utf8
        }
        $dir
    }

    $zoom = @{
        Id = 'Zoom'; Mode = 'Auto'; Version = '7.3.0'
        DownloadUrl = 'https://example.com/zoom-7.3.0.msi'; Sha256 = ''
        InstallerType = 'MSI'; InstallArguments = '/qn'; DetectionName = @('=Zoom')
        Production = @{ Version = '7.2.51704'; DownloadUrl = 'https://example.com/zoom-7.2.51704.msi'; Sha256 = '' }
        Updater = @{ Type = 'RedirectMsi'; Url = 'https://example.com/latest' }
    }
    $autoNoProd = @{
        Id = 'NoProd'; Mode = 'Auto'; Version = '1.0'
        DownloadUrl = 'https://example.com/noprod.msi'; Sha256 = ''
        InstallerType = 'MSI'; DetectionName = @('NoProd')
    }
    $manual = @{ Id = 'Inventaire'; Mode = 'Manual'; DetectionName = @('Inventaire') }
}

Describe 'Anneaux: pilote et production' {
    BeforeAll {
        $dir = New-RingFixture -Manifests @{ zoom = $zoom; noprod = $autoNoProd; inventaire = $manual }
        & $buildScript -CatalogRoot $dir *> $null
        $pilot = Get-Content -LiteralPath (Join-Path $dir 'apps.pilot.json') -Raw | ConvertFrom-Json
        $prod = Get-Content -LiteralPath (Join-Path $dir 'apps.json') -Raw | ConvertFrom-Json
    }

    AfterAll {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'le pilote recoit la version la plus recente du manifeste' {
        $pilot.Applications.Zoom.Version | Should -Be '7.3.0'
    }

    It 'la production recoit la version du bloc Production' {
        $prod.Applications.Zoom.Version | Should -Be '7.2.51704'
        $prod.Applications.Zoom.DownloadUrl | Should -Be 'https://example.com/zoom-7.2.51704.msi'
    }

    It 'une application Auto sans bloc Production n''est pas en production' {
        $pilot.Applications.NoProd | Should -Not -BeNullOrEmpty
        $prod.Applications.PSObject.Properties.Name | Should -Not -Contain 'NoProd'
    }

    It 'une application Manual est dans les deux anneaux' {
        $pilot.Applications.Inventaire | Should -Not -BeNullOrEmpty
        $prod.Applications.Inventaire | Should -Not -BeNullOrEmpty
    }

    It 'Production et Updater ne sont jamais publies' {
        $pilot.Applications.Zoom.PSObject.Properties.Name | Should -Not -Contain 'Production'
        $prod.Applications.Zoom.PSObject.Properties.Name | Should -Not -Contain 'Updater'
    }
}

Describe 'Anneaux: un manifeste sans bloc Production et un Id en double' {
    It 'Id en double: erreur' {
        $dir = New-RingFixture -Manifests @{ zoom = $zoom; zoom2 = $zoom }
        try {
            { & $buildScript -CatalogRoot $dir *> $null } | Should -Throw
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
