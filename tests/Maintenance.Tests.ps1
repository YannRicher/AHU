# Pester 5 - nettoyage des caches et des journaux MSI

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    foreach ($module in 'Logging', 'Version', 'Catalog', 'Detection', 'Installer', 'Engine') {
        Import-Module (Join-Path $root ('engine\Modules\{0}.psm1' -f $module)) -Force -Global -DisableNameChecking
    }
}

Describe 'Remove-AhuStaleCache' {
    BeforeEach {
        $dataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-Cache-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dataRoot 'Cache\Zoom\7.2.51704') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dataRoot 'Cache\Zoom\7.1.48953') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dataRoot 'Cache\Zoom\7.1.48953\ZoomInstallerFull.msi') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dataRoot 'Cache\apps.json') -Value '{}'
    }

    AfterEach {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'supprime les versions anciennes et garde la version cible' {
        $removed = Remove-AhuStaleCache -AppId 'Zoom' -TargetVersion '7.2.51704' -DataRoot $dataRoot
        $removed | Should -Be 1
        Test-Path -LiteralPath (Join-Path $dataRoot 'Cache\Zoom\7.2.51704') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dataRoot 'Cache\Zoom\7.1.48953') | Should -BeFalse
    }

    It 'ne touche pas au cache d''une autre application ni au catalogue en cache' {
        New-Item -ItemType Directory -Path (Join-Path $dataRoot 'Cache\VSCode\1.0') -Force | Out-Null
        Remove-AhuStaleCache -AppId 'Zoom' -TargetVersion '7.2.51704' -DataRoot $dataRoot | Out-Null
        Test-Path -LiteralPath (Join-Path $dataRoot 'Cache\VSCode\1.0') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dataRoot 'Cache\apps.json') | Should -BeTrue
    }

    It 'ne fait rien si le cache de l''application n''existe pas' {
        Remove-AhuStaleCache -AppId 'Absente' -TargetVersion '1.0' -DataRoot $dataRoot | Should -Be 0
    }
}

Describe 'Remove-AhuOldMsiLog' {
    BeforeEach {
        $logDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-Logs-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

        # 4 journaux Zoom, du plus ancien au plus recent
        $zoomLogs = 'Zoom-7.1.0-msi.log', 'Zoom-7.1.1-msi.log', 'Zoom-7.2.0-msi.log', 'Zoom-7.2.51704-msi.log'
        $day = 0
        foreach ($name in $zoomLogs) {
            $path = Join-Path $logDirectory $name
            Set-Content -LiteralPath $path -Value 'log'
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date '2026-11-01').AddDays($day)
            $day++
        }

        # Un journal d'une autre application, avec un nom contenant un tiret
        $other = Join-Path $logDirectory 'Adobe-Reader-26.0-msi.log'
        Set-Content -LiteralPath $other -Value 'log'
        (Get-Item -LiteralPath $other).LastWriteTime = (Get-Date '2026-10-01')

        # Un journal qui ne suit pas le format: il est classe seul, donc garde
        Set-Content -LiteralPath (Join-Path $logDirectory 'AHU.log') -Value 'log'
    }

    AfterEach {
        Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'garde les 2 journaux les plus recents par application' {
        $removed = Remove-AhuOldMsiLog -LogDirectory $logDirectory -Keep 2
        $removed | Should -Be 2
        Test-Path -LiteralPath (Join-Path $logDirectory 'Zoom-7.1.0-msi.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $logDirectory 'Zoom-7.1.1-msi.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $logDirectory 'Zoom-7.2.0-msi.log') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $logDirectory 'Zoom-7.2.51704-msi.log') | Should -BeTrue
    }

    It 'ne touche pas aux autres applications ni aux journaux AHU.log' {
        Remove-AhuOldMsiLog -LogDirectory $logDirectory -Keep 2 | Out-Null
        Test-Path -LiteralPath (Join-Path $logDirectory 'Adobe-Reader-26.0-msi.log') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $logDirectory 'AHU.log') | Should -BeTrue
    }

    It 'ne fait rien si le dossier n''existe pas' {
        Remove-AhuOldMsiLog -LogDirectory (Join-Path $logDirectory 'absent') -Keep 2 | Should -Be 0
    }
}
