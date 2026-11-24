# Pester 5 - nettoyage des caches et des journaux MSI

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    foreach ($module in 'Logging', 'Version', 'Catalog', 'Detection', 'Hooks', 'Installer', 'Engine') {
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

Describe 'Choix de la langue d''installation' {
    BeforeAll {
        $script:reader = [pscustomobject]@{
            Id               = 'AdobeReader'
            Mode             = 'Auto'
            Version          = '25.001.20531'
            DownloadUrl      = 'https://example.com/default-en.exe'
            Sha256           = ''
            InstallerType    = 'EXE'
            InstallArguments = '/sAll'
            DetectionName    = @('Adobe Acrobat Reader*')
            Installers       = @(
                [pscustomobject]@{ Locale = 'fr-CA'; DownloadUrl = 'https://example.com/fr-ca.exe' }
                [pscustomobject]@{ Locale = 'fr-FR'; DownloadUrl = 'https://example.com/fr-fr.exe' }
                [pscustomobject]@{ Locale = 'en-US'; DownloadUrl = 'https://example.com/en-us.exe' }
            )
        }
    }

    It 'ordre: langue systeme, puis fr-CA, fr-FR, en-US (sans doublon)' {
        (Get-AhuLanguageOrder -SystemLocale 'de-DE') -join ',' | Should -Be 'de-DE,fr-CA,fr-FR,en-US'
        (Get-AhuLanguageOrder -SystemLocale 'fr-FR') -join ',' | Should -Be 'fr-FR,fr-CA,en-US'
    }

    It 'prend la langue du systeme si un installateur existe' {
        $r = Select-AhuInstallerVariant -App $reader -LanguageOrder @('fr-FR', 'fr-CA', 'en-US')
        $r.DownloadUrl | Should -Be 'https://example.com/fr-fr.exe'
        $r.SelectedLocale | Should -Be 'fr-FR'
    }

    It 'sinon fr-CA avant fr-FR et en-US' {
        $r = Select-AhuInstallerVariant -App $reader -LanguageOrder @('de-DE', 'fr-CA', 'fr-FR', 'en-US')
        $r.DownloadUrl | Should -Be 'https://example.com/fr-ca.exe'
    }

    It 'en-US en dernier recours' {
        $onlyEnglish = [pscustomobject]@{
            Id = 'X'; DownloadUrl = 'https://example.com/default.exe'; InstallerType = 'EXE'; Installers = @([pscustomobject]@{ Locale = 'en-US'; DownloadUrl = 'https://example.com/en.exe' })
        }
        (Select-AhuInstallerVariant -App $onlyEnglish -LanguageOrder @('de-DE', 'fr-CA', 'fr-FR', 'en-US')).DownloadUrl | Should -Be 'https://example.com/en.exe'
    }

    It 'sans installateur par langue, ou sans correspondance: installateur par defaut' {
        $plain = [pscustomobject]@{ Id = 'Zoom'; DownloadUrl = 'https://example.com/zoom.msi'; InstallerType = 'MSI' }
        (Select-AhuInstallerVariant -App $plain -LanguageOrder @('fr-CA')).DownloadUrl | Should -Be 'https://example.com/zoom.msi'

        $none = [pscustomobject]@{ Id = 'X'; DownloadUrl = 'https://example.com/default.exe'; InstallerType = 'EXE'; Installers = @([pscustomobject]@{ Locale = 'de-DE'; DownloadUrl = 'https://example.com/de.exe' }) }
        (Select-AhuInstallerVariant -App $none -LanguageOrder @('fr-CA', 'en-US')).DownloadUrl | Should -Be 'https://example.com/default.exe'
    }

    It 'ne modifie pas l''application d''origine' {
        Select-AhuInstallerVariant -App $reader -LanguageOrder @('fr-CA') | Out-Null
        $reader.DownloadUrl | Should -Be 'https://example.com/default-en.exe'
    }

    It 'refuse un Locale invalide et un DownloadUrl non https' {
        $bad = $reader.PSObject.Copy()
        $bad | Add-Member -NotePropertyName Installers -NotePropertyValue @(
            [pscustomobject]@{ Locale = 'french'; DownloadUrl = 'https://example.com/a.exe' }
            [pscustomobject]@{ Locale = 'fr-CA'; DownloadUrl = 'http://example.com/b.exe' }
        ) -Force
        @(Test-AhuAppDefinition -App $bad).Count | Should -Be 2
    }
}
