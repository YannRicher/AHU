# Pester 5 - compatible Windows PowerShell 5.1 et PowerShell 7

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    foreach ($module in 'Logging', 'Version', 'Catalog', 'Detection', 'Hooks', 'Installer', 'Engine') {
        Import-Module (Join-Path $root ('engine\Modules\{0}.psm1' -f $module)) -Force -Global -DisableNameChecking
    }

    function New-TestApp {
        param([hashtable]$Properties)
        $base = [ordered]@{
            Id               = 'Zoom'
            Mode             = 'Auto'
            Version          = '7.2.51704'
            DownloadUrl      = 'https://cdn.zoom.us/prod/7.2.5.51704/x64/ZoomInstallerFull.msi'
            InstallerType    = 'MSI'
            InstallArguments = '/qn /norestart'
            DetectionName    = @('Zoom Workplace (64-bit)', 'Zoom (64-bit)')
            DetectionExclude = @('*VDI*', '*Plugin*')
        }
        foreach ($key in $Properties.Keys) { $base[$key] = $Properties[$key] }
        [pscustomobject]$base
    }

    function New-TestEntry {
        param([string]$Name, [string]$Version, [string]$Publisher = 'Zoom Communications, Inc.')
        [pscustomobject]@{ DisplayName = $Name; DisplayVersion = $Version; Publisher = $Publisher }
    }
}

Describe 'Compare-AhuVersion' {
    It 'compare <Version> a <Reference> = <Expected>' -TestCases @(
        @{ Version = '7.1.48953';    Reference = '7.2.51704';    Expected = -1 }
        @{ Version = '7.2.51704';    Reference = '7.2.51704';    Expected = 0 }
        @{ Version = '7.10.0';       Reference = '7.9.9';        Expected = 1 }
        @{ Version = '25.001.20531'; Reference = '25.1.20531';   Expected = 0 }
        @{ Version = '24.09';        Reference = '24.08';        Expected = 1 }
        @{ Version = '1.2';          Reference = '1.2.0.0';      Expected = 0 }
        @{ Version = '8.0.4310.10';  Reference = '8.0.4410.7';   Expected = -1 }
        @{ Version = '5.16.10 (26186)'; Reference = '7.2.51704'; Expected = -1 }
        @{ Version = '';             Reference = '1.0';          Expected = -1 }
    ) {
        Compare-AhuVersion $Version $Reference | Should -Be $Expected
    }
}

Describe 'Get-AhuAppDecision' {
    It 'Auto, version plus ancienne: mise a jour requise' {
        $d = Get-AhuAppDecision -App (New-TestApp @{}) -InstalledVersion '7.1.48953'
        $d.Status | Should -Be 'Update'
        $d.NeedsAction | Should -BeTrue
    }

    It 'Auto, meme version: conforme' {
        $d = Get-AhuAppDecision -App (New-TestApp @{}) -InstalledVersion '7.2.51704'
        $d.Status | Should -Be 'UpToDate'
        $d.NeedsAction | Should -BeFalse
    }

    It 'Pinned, version plus recente installee: aucun retour arriere' {
        $d = Get-AhuAppDecision -App (New-TestApp @{ Mode = 'Pinned'; Version = '25.001.20531' }) -InstalledVersion '25.001.20600'
        $d.Status | Should -Be 'Newer'
        $d.NeedsAction | Should -BeFalse
    }

    It 'Pinned, version plus ancienne: mise a jour vers la version epinglee' {
        $d = Get-AhuAppDecision -App (New-TestApp @{ Mode = 'Pinned'; Version = '25.001.20531' }) -InstalledVersion '24.005.20320'
        $d.Status | Should -Be 'Update'
        $d.NeedsAction | Should -BeTrue
    }

    It 'Manual: jamais d''action' {
        $d = Get-AhuAppDecision -App (New-TestApp @{ Mode = 'Manual' }) -InstalledVersion '1.0'
        $d.Status | Should -Be 'Manual'
        $d.NeedsAction | Should -BeFalse
    }

    It 'Non installee: aucune action par defaut' {
        $d = Get-AhuAppDecision -App (New-TestApp @{}) -InstalledVersion $null
        $d.Status | Should -Be 'NotInstalled'
        $d.NeedsAction | Should -BeFalse
    }

    It 'Non installee avec InstallIfMissing: installation' {
        $d = Get-AhuAppDecision -App (New-TestApp @{ InstallIfMissing = $true }) -InstalledVersion $null
        $d.Status | Should -Be 'Install'
        $d.NeedsAction | Should -BeTrue
    }

    It 'Enabled = false: desactivee' {
        $d = Get-AhuAppDecision -App (New-TestApp @{ Enabled = $false }) -InstalledVersion '1.0'
        $d.Status | Should -Be 'Disabled'
        $d.NeedsAction | Should -BeFalse
    }

    It 'Auto sans version cible: aucune action' {
        $d = Get-AhuAppDecision -App (New-TestApp @{ Version = '' }) -InstalledVersion '7.1.0'
        $d.Status | Should -Be 'Invalid'
        $d.NeedsAction | Should -BeFalse
    }
}

Describe 'Find-AhuInstalledApp' {
    It 'trouve Zoom Workplace et ignore les plugins et VDI' {
        $entries = @(
            New-TestEntry 'Zoom Outlook Plugin' '9.9.9'
            New-TestEntry 'Zoom Workplace (64-bit) VDI' '9.9.9'
            New-TestEntry 'Zoom Workplace (64-bit)' '7.1.48953'
            New-TestEntry 'Notepad++ (64-bit x64)' '8.6' 'Notepad++ Team'
        )
        $found = Find-AhuInstalledApp -App (New-TestApp @{}) -Entries $entries
        $found.DisplayVersion | Should -Be '7.1.48953'
    }

    It 'DetectionView: ignore les entrees de l''autre vue de registre (Java x64 et x86)' {
        $x64 = [pscustomobject]@{ DisplayName = 'Java 8 Update 513'; DisplayVersion = '8.0.5130.4'; Publisher = 'Oracle Corporation'; RegistryView = 'Registry64' }
        $x86 = [pscustomobject]@{ DisplayName = 'Java 8 Update 151'; DisplayVersion = '8.0.1510.12'; Publisher = 'Oracle Corporation'; RegistryView = 'Registry32' }
        $entries = @($x64, $x86)
        $app64 = New-TestApp @{ DetectionName = 'Java 8 Update*'; DetectionPublisher = 'Oracle*'; DetectionView = 'Registry64' }
        $app32 = New-TestApp @{ DetectionName = 'Java 8 Update*'; DetectionPublisher = 'Oracle*'; DetectionView = 'Registry32' }
        (Find-AhuInstalledApp -App $app64 -Entries $entries).DisplayVersion | Should -Be '8.0.5130.4'
        (Find-AhuInstalledApp -App $app32 -Entries $entries).DisplayVersion | Should -Be '8.0.1510.12'
        @(Find-AhuInstalledApp -App (New-TestApp @{ DetectionName = 'Java 8 Update*' }) -Entries $entries -All).Count | Should -Be 2
    }

    It 'DetectionView invalide: erreur de definition' {
        @(Test-AhuAppDefinition -App (New-TestApp @{ DetectionView = 'Registry16' })) -join ' ' | Should -Match 'DetectionView invalide'
    }

    It 'trouve l''ancien nom Zoom (64-bit)' {
        $found = Find-AhuInstalledApp -App (New-TestApp @{}) -Entries @(New-TestEntry 'Zoom (64-bit)' '5.17.31859')
        $found.DisplayVersion | Should -Be '5.17.31859'
    }

    It 'retourne la plus haute version si plusieurs entrees' {
        $entries = @(
            New-TestEntry 'Zoom (64-bit)' '5.17.31859'
            New-TestEntry 'Zoom Workplace (64-bit)' '7.1.48953'
        )
        (Find-AhuInstalledApp -App (New-TestApp @{}) -Entries $entries).DisplayVersion | Should -Be '7.1.48953'
    }

    It 'filtre par editeur' {
        $app = New-TestApp @{ DetectionPublisher = 'Zoom*' }
        Find-AhuInstalledApp -App $app -Entries @(New-TestEntry 'Zoom (64-bit)' '1.0' 'Autre editeur') | Should -BeNullOrEmpty
    }

    It 'le prefixe = exige le nom exact' {
        $app = New-TestApp @{ DetectionName = @('=Zoom'); DetectionExclude = @() }
        (Find-AhuInstalledApp -App $app -Entries @(New-TestEntry 'Zoom' '5.16.10 (26186)')).DisplayVersion | Should -Be '5.16.10 (26186)'
        Find-AhuInstalledApp -App $app -Entries @(New-TestEntry 'Zoom Outlook Plugin' '5.16.10') | Should -BeNullOrEmpty
    }

    It 'le manifeste Zoom reconnait Zoom 5.16 personnel et ignore le plugin' {
        $zoom = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'catalog\applications\zoom.json') -Raw | ConvertFrom-Json
        $entries = @(
            New-TestEntry 'Zoom' '5.16.10 (26186)'
            New-TestEntry 'Zoom Outlook Plugin' '5.16.10'
        )
        $found = @(Find-AhuInstalledApp -App $zoom -Entries $entries -All)
        $found.Count | Should -Be 1
        $found[0].DisplayName | Should -Be 'Zoom'
        (Get-AhuAppDecision -App $zoom -InstalledVersion $found[0].DisplayVersion).NeedsAction | Should -BeTrue
    }

    It 'sans joker, correspondance partielle' {
        $app = New-TestApp @{ DetectionName = 'Workplace'; DetectionExclude = @() }
        (Find-AhuInstalledApp -App $app -Entries @(New-TestEntry 'Zoom Workplace (64-bit)' '7.0')).DisplayVersion | Should -Be '7.0'
    }

    It 'Adobe Reader ne detecte pas Acrobat (produit distinct)' {
        $reader = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'catalog\applications\adobereader.json') -Raw | ConvertFrom-Json
        $reader | Add-Member -NotePropertyName Id -NotePropertyValue 'AdobeReader' -Force
        $acrobat = New-TestEntry 'Adobe Acrobat (64-bit)' '26.002.22031' 'Adobe'
        Find-AhuInstalledApp -App $reader -Entries @($acrobat) | Should -BeNullOrEmpty
    }

    It 'Adobe Reader detecte Reader, meme si Acrobat est aussi installe' {
        $reader = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'catalog\applications\adobereader.json') -Raw | ConvertFrom-Json
        $entries = @(
            New-TestEntry 'Adobe Acrobat (64-bit)' '26.002.22031' 'Adobe'
            New-TestEntry 'Adobe Acrobat Reader (64-bit)' '25.001.20531' 'Adobe'
        )
        (Find-AhuInstalledApp -App $reader -Entries $entries).DisplayName | Should -Be 'Adobe Acrobat Reader (64-bit)'
    }

    It 'entree Acrobat (Manual) detecte Acrobat mais pas Reader' {
        $acrobat = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'catalog\applications\acrobat.json') -Raw | ConvertFrom-Json
        $acrobat | Add-Member -NotePropertyName Id -NotePropertyValue 'Acrobat' -Force
        $entries = @(
            New-TestEntry 'Adobe Acrobat (64-bit)' '26.002.22031' 'Adobe'
            New-TestEntry 'Adobe Acrobat Reader (64-bit)' '25.001.20531' 'Adobe'
        )
        (Find-AhuInstalledApp -App $acrobat -Entries $entries).DisplayName | Should -Be 'Adobe Acrobat (64-bit)'
    }

    It 'retourne null si absent' {
        Find-AhuInstalledApp -App (New-TestApp @{}) -Entries @(New-TestEntry 'Autre' '1.0') | Should -BeNullOrEmpty
    }
}

Describe 'Test-AhuAppDefinition' {
    It 'accepte une definition Auto complete' {
        @(Test-AhuAppDefinition -App (New-TestApp @{})).Count | Should -Be 0
    }

    It 'accepte une definition Manual minimale' {
        @(Test-AhuAppDefinition -App ([pscustomobject]@{ Mode = 'Manual'; DetectionName = 'X' })).Count | Should -Be 0
    }

    It 'refuse un mode inconnu' {
        @(Test-AhuAppDefinition -App (New-TestApp @{ Mode = 'Latest' })).Count | Should -Be 1
    }

    It 'refuse une URL http et un hash invalide' {
        @(Test-AhuAppDefinition -App (New-TestApp @{ DownloadUrl = 'http://x'; Sha256 = 'abc' })).Count | Should -Be 2
    }

    It 'refuse Pinned sans version' {
        @(Test-AhuAppDefinition -App (New-TestApp @{ Mode = 'Pinned'; Version = '' })).Count | Should -Be 1
    }
}

Describe 'Get-AhuInstallerFileName' {
    It 'utilise le nom du fichier de l''URL' {
        Get-AhuInstallerFileName -App (New-TestApp @{}) | Should -Be 'ZoomInstallerFull.msi'
    }

    It 'genere un nom si l''URL n''a pas la bonne extension' {
        Get-AhuInstallerFileName -App (New-TestApp @{ DownloadUrl = 'https://exemple.com/download?id=1' }) | Should -Be 'Zoom-setup.msi'
    }
}

Describe 'Invoke-AhuEngine (catalogue local)' {
    BeforeAll {
        $dataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-Tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
        $catalogPath = Join-Path $dataRoot 'apps.json'
        $catalog = @{
            SchemaVersion = 1
            Settings      = @{ Paused = $false }
            Applications  = @{ Zoom = (New-TestApp @{}) }
        }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $catalogPath -Encoding ASCII
    }

    AfterAll {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Detect: non conforme si Zoom est desuet' {
        Mock -ModuleName Engine Get-AhuUninstallEntry { New-TestEntry 'Zoom Workplace (64-bit)' '7.1.48953' }
        $result = Invoke-AhuEngine -Action Detect -CatalogPath $catalogPath -DataRoot $dataRoot
        $result.ExitCode | Should -Be 1
        $result.Summary | Should -Match 'mise a jour requise vers 7.2.51704'
    }

    It 'Detect: conforme si Zoom est a jour' {
        Mock -ModuleName Engine Get-AhuUninstallEntry { New-TestEntry 'Zoom Workplace (64-bit)' '7.2.51704' }
        (Invoke-AhuEngine -Action Detect -CatalogPath $catalogPath -DataRoot $dataRoot).ExitCode | Should -Be 0
    }

    It 'Detect: retient la version la plus recente si deux versions sont installees (ex. Java 8u151 et 8u513)' {
        Mock -ModuleName Engine Get-AhuUninstallEntry {
            New-TestEntry 'Zoom Workplace (64-bit)' '7.1.48953'
            New-TestEntry 'Zoom Workplace (64-bit)' '7.2.51704'
        }
        $result = Invoke-AhuEngine -Action Detect -CatalogPath $catalogPath -DataRoot $dataRoot
        $result.ExitCode | Should -Be 0
        $result.Summary | Should -Match 'version 7.2.51704 detectee'
    }

    It 'Detect: conforme si Zoom est absent' {
        Mock -ModuleName Engine Get-AhuUninstallEntry { }
        (Invoke-AhuEngine -Action Detect -CatalogPath $catalogPath -DataRoot $dataRoot).ExitCode | Should -Be 0
    }

    It 'Remediate: reporte si Zoom est ouvert' {
        Mock -ModuleName Engine Get-AhuUninstallEntry { New-TestEntry 'Zoom Workplace (64-bit)' '7.1.48953' }
        Mock -ModuleName Installer Get-AhuConflictingProcess { [pscustomobject]@{ ProcessName = 'Zoom' } }
        $app = New-TestApp @{ ConflictingProcesses = @('Zoom') }
        $result = Install-AhuApp -App $app -DataRoot $dataRoot
        $result.Status | Should -Be 'Deferred'
    }

    It 'ecrit le journal au format date - message' {
        $log = Get-Content -LiteralPath (Join-Path $dataRoot 'Logs\AHU.log')
        $log | Should -Not -BeNullOrEmpty
        $log[0] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} - '
    }

    It 'inscrit la version du moteur dans l''entete du journal' {
        Mock -ModuleName Engine Get-AhuUninstallEntry { }
        $fresh = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-Tests-' + [guid]::NewGuid().ToString('N'))
        try {
            [void](Invoke-AhuEngine -Action Detect -CatalogPath $catalogPath -DataRoot $fresh)
            $log = Get-Content -LiteralPath (Join-Path $fresh 'Logs\AHU.log')
            $log[0] | Should -Match '===== AHU Detect - moteur \d+\.\d+\.\d+ \(build \S+\) - PowerShell '
        }
        finally {
            Remove-Item -LiteralPath $fresh -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Get-AhuEngineVersion retourne version et build' {
        Get-AhuEngineVersion | Should -Match '^\d+\.\d+\.\d+ \(build \S+\)$'
    }
}
