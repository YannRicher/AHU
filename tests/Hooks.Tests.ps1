# Pester 5 - scripts avant / apres installation (PreInstall / PostInstall)

BeforeAll {
    $root = Split-Path -Path $PSScriptRoot -Parent
    foreach ($module in 'Logging', 'Version', 'Catalog', 'Detection', 'Hooks', 'Installer', 'Engine') {
        Import-Module (Join-Path $root ('engine\Modules\{0}.psm1' -f $module)) -Force -Global -DisableNameChecking
    }
    Import-Module (Join-Path $root 'automation\AhuAutomation.psm1') -Force -Global -DisableNameChecking

    function New-TempDirectory {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ('AHU-Hooks-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $path
    }
}

Describe 'Fonctions utilitaires (noms PSADT)' {
    BeforeAll {
        . ([scriptblock]::Create((Get-AhuHookHelperSource)))
    }

    BeforeEach {
        $dir = New-TempDirectory
        $regPath = 'HKCU:\Software\AHU-Pester-' + [guid]::NewGuid().ToString('N')
    }

    AfterEach {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'le source des fonctions est du PowerShell valide' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput((Get-AhuHookHelperSource), [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'Remove-File supprime les fichiers qui correspondent au motif et ignore les autres' {
        Set-Content -LiteralPath (Join-Path $dir 'Zoom.lnk') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dir 'Zoom Workplace.lnk') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dir 'Autre.lnk') -Value 'x'

        Remove-File -Path (Join-Path $dir 'Zoom*.lnk') *> $null

        Test-Path -LiteralPath (Join-Path $dir 'Zoom.lnk') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'Zoom Workplace.lnk') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'Autre.lnk') | Should -BeTrue
    }

    It 'Remove-File ne signale pas d''erreur si le fichier est absent' {
        { Remove-File -Path (Join-Path $dir 'absent.lnk') *> $null } | Should -Not -Throw
    }

    It 'Remove-File -Recurse cherche dans les sous-dossiers' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'sous') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'sous\a.tmp') -Value 'x'
        Remove-File -Path (Join-Path $dir '*.tmp') -Recurse *> $null
        Test-Path -LiteralPath (Join-Path $dir 'sous\a.tmp') | Should -BeFalse
    }

    It 'Remove-Folder supprime le dossier et son contenu' {
        New-Item -ItemType Directory -Path (Join-Path $dir 'cible\profond') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'cible\profond\f.txt') -Value 'x'
        Remove-Folder -Path (Join-Path $dir 'cible') *> $null
        Test-Path -LiteralPath (Join-Path $dir 'cible') | Should -BeFalse
    }

    It 'New-Folder et Copy-File creent et copient' {
        New-Folder -Path (Join-Path $dir 'nouveau') *> $null
        Set-Content -LiteralPath (Join-Path $dir 'source.txt') -Value 'bonjour'
        Copy-File -Path (Join-Path $dir 'source.txt') -Destination (Join-Path $dir 'nouveau\') *> $null
        Get-Content -LiteralPath (Join-Path $dir 'nouveau\source.txt') | Should -Be 'bonjour'
    }

    It 'Set-RegistryKey, Get-RegistryKey et Remove-RegistryKey (forme HKCU:)' {
        Set-RegistryKey -Key $regPath -Name 'Valeur' -Value 7 -Type DWord *> $null
        Get-RegistryKey -Key $regPath -Value 'Valeur' | Should -Be 7

        Remove-RegistryKey -Key $regPath -Name 'Valeur' *> $null
        Get-RegistryKey -Key $regPath -Value 'Valeur' | Should -BeNullOrEmpty

        Remove-RegistryKey -Key $regPath -Recurse *> $null
        Test-Path -LiteralPath $regPath | Should -BeFalse
    }

    It 'accepte la forme HKEY_CURRENT_USER\...' {
        $long = $regPath -replace '^HKCU:', 'HKEY_CURRENT_USER'
        Set-RegistryKey -Key $long -Name 'Texte' -Value 'abc' *> $null
        (Get-ItemProperty -LiteralPath $regPath).Texte | Should -Be 'abc'
    }

    It 'une erreur arrete le script, sauf avec -ContinueOnError $true' {
        { Set-RegistryKey -Key 'C:\pas-un-registre' -Name 'x' -Value 1 } | Should -Throw
        { Set-RegistryKey -Key 'C:\pas-un-registre' -Name 'x' -Value 1 -ContinueOnError $true *> $null } | Should -Not -Throw
    }

    It 'Get-InstalledApplication retourne une liste (vide si rien ne correspond)' {
        @(Get-InstalledApplication -Name 'Application-Qui-N-Existe-Pas-AHU') | Should -BeNullOrEmpty
    }

    It 'Execute-Process retourne le code de sortie et echoue sur un code non nul' {
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        (Execute-Process -Path $cmd -Parameters '/c exit 0' 6>$null).ExitCode | Should -Be 0
        { Execute-Process -Path $cmd -Parameters '/c exit 3' *> $null } | Should -Throw
        { Execute-Process -Path $cmd -Parameters '/c exit 3' -IgnoreExitCodes 3 *> $null } | Should -Not -Throw
    }
}

Describe 'Invoke-AhuHook (processus separe)' {
    BeforeEach {
        $dir = New-TempDirectory
        $app = [pscustomobject]@{ Id = 'TestApp'; Name = 'Test App'; Version = '2.0' }
        Initialize-AhuLog -LogDirectory (Join-Path $dir 'Logs') | Out-Null
        $logFile = Join-Path $dir 'Logs\AHU.log'

        function Invoke-TestHook {
            param([string]$Content, [double]$Timeout = 1)
            $script = Join-Path $dir 'PostInstall.ps1'
            Set-Content -LiteralPath $script -Value $Content -Encoding ascii
            Invoke-AhuHook -App $app -Phase PostInstall -ScriptPath $script -DataRoot $dir -TimeoutMinutes $Timeout
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'un script qui reussit retourne Success et sa sortie est dans le journal AHU' {
        $result = Invoke-TestHook 'Write-Log "message du script"'
        $result.Success | Should -BeTrue
        Get-Content -LiteralPath $logFile -Raw | Should -Match 'TestApp: \[PostInstall\] message du script'
    }

    It 'une exception du script est un echec avec le message' {
        $result = Invoke-TestHook 'throw "probleme voulu"'
        $result.Success | Should -BeFalse
        $result.Message | Should -Match 'probleme voulu'
    }

    It 'exit N dans le script ne tue pas le moteur et donne le code N' {
        $result = Invoke-TestHook 'exit 7'
        $result.Success | Should -BeFalse
        $result.ExitCode | Should -Be 7
    }

    It 'un script trop long est arrete apres le delai' {
        $result = Invoke-TestHook 'Start-Sleep -Seconds 60' -Timeout 0.05
        $result.Success | Should -BeFalse
        $result.Message | Should -Match 'delai depasse'
    }

    It 'les variables de contexte sont disponibles' {
        $out = Join-Path $dir 'vars.txt'
        $content = @'
Set-Content -LiteralPath '@@OUT@@' -Value ("$appId|$appName|$appVersion|$installPhase|" + [bool]$envCommonDesktop + "|" + [bool]$envProgramFiles)
'@ -replace '@@OUT@@', $out
        (Invoke-TestHook $content).Success | Should -BeTrue
        Get-Content -LiteralPath $out | Should -Be 'TestApp|Test App|2.0|Post-Installation|True|True'
    }
}

Describe 'Install-AhuApp avec scripts avant/apres' {
    BeforeAll {
        $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $cmdHash = (Get-FileHash -LiteralPath $cmdExe -Algorithm SHA256).Hash

        Mock -ModuleName Installer Find-AhuInstalledApp { [pscustomobject]@{ DisplayVersion = '2.0' } }
        $copySource = {
            $map = Get-Content -LiteralPath $env:AHU_TEST_SOURCES -Raw | ConvertFrom-Json
            New-Item -ItemType Directory -Path (Split-Path -Path $Destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $map.PSObject.Properties[$Uri].Value -Destination $Destination -Force
        }
        Mock -ModuleName Installer Save-AhuFile $copySource
        Mock -ModuleName Hooks Save-AhuFile $copySource
    }

    BeforeEach {
        $dir = New-TempDirectory
        Initialize-AhuLog -LogDirectory (Join-Path $dir 'Logs') | Out-Null
        $order = Join-Path $dir 'order.txt'

        function New-Fixture {
            param([string]$Pre, [string]$Post, [string]$PostHashOverride = '')
            $sources = @{ 'https://test/setup.exe' = $cmdExe }
            $app = [ordered]@{
                Id = 'TestApp'; Name = 'Test App'; Mode = 'Auto'; Version = '2.0'
                DownloadUrl = 'https://test/setup.exe'; Sha256 = $cmdHash; InstallerType = 'EXE'
                InstallArguments = ('/c echo install>>"{0}"' -f $order)
                RequireSignature = $false; DetectionName = @('Test App')
            }
            foreach ($phase in @(@('PreInstall', $Pre), @('PostInstall', $Post))) {
                if (-not $phase[1]) { continue }
                $file = Join-Path $dir ('{0}.src.ps1' -f $phase[0])
                Set-Content -LiteralPath $file -Value $phase[1] -Encoding ascii
                $url = 'https://test/{0}.ps1' -f $phase[0]
                $sources[$url] = $file
                $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if ($phase[0] -eq 'PostInstall' -and $PostHashOverride) { $hash = $PostHashOverride }
                $app[$phase[0]] = [pscustomobject]@{ Url = $url; Sha256 = $hash }
            }
            $mapFile = Join-Path $dir 'sources.json'
            $sources | ConvertTo-Json | Set-Content -LiteralPath $mapFile -Encoding ascii
            $env:AHU_TEST_SOURCES = $mapFile
            [pscustomobject]$app
        }
    }

    AfterEach {
        $env:AHU_TEST_SOURCES = $null
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'execute avant, puis l''installateur, puis apres' {
        $app = New-Fixture -Pre ("Add-Content -LiteralPath '{0}' -Value 'pre'" -f $order) -Post ("Add-Content -LiteralPath '{0}' -Value 'post'" -f $order)
        $result = Install-AhuApp -App $app -DataRoot $dir
        $result.Status | Should -Be 'Installed'
        @(Get-Content -LiteralPath $order) | Should -Be @('pre', 'install', 'post')
    }

    It 'sans script, l''installation se fait comme avant' {
        $app = New-Fixture
        $result = Install-AhuApp -App $app -DataRoot $dir
        $result.Status | Should -Be 'Installed'
        @(Get-Content -LiteralPath $order) | Should -Be @('install')
    }

    It 'un echec du script avant annule l''installation' {
        $app = New-Fixture -Pre 'throw "pas pret"' -Post ("Add-Content -LiteralPath '{0}' -Value 'post'" -f $order)
        $result = Install-AhuApp -App $app -DataRoot $dir
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'installation annulee'
        Test-Path -LiteralPath $order | Should -BeFalse
    }

    It 'un echec du script apres est signale comme echec (l''application est deja installee)' {
        $app = New-Fixture -Post 'exit 5'
        $result = Install-AhuApp -App $app -DataRoot $dir
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'script apres installation en echec'
        @(Get-Content -LiteralPath $order) | Should -Be @('install')
    }

    It 'un SHA256 invalide empeche tout: ni script avant ni installation' {
        $app = New-Fixture -Pre ("Add-Content -LiteralPath '{0}' -Value 'pre'" -f $order) -Post 'exit 0' -PostHashOverride ('0' * 64)
        $result = Install-AhuApp -App $app -DataRoot $dir
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'SHA256 invalide'
        Test-Path -LiteralPath $order | Should -BeFalse
    }
}

Describe 'Publication des scripts dans le catalogue' {
    BeforeAll {
        $buildScript = Join-Path $root 'automation\Build-Catalog.ps1'
        $dir = New-TempDirectory
        New-Item -ItemType Directory -Path (Join-Path $dir 'applications') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dir 'hooks\Zoom') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'settings.json') -Value '{ "Paused": false }' -Encoding utf8

        $zoom = @{
            Id = 'Zoom'; Mode = 'Auto'; Version = '7.3.0'
            DownloadUrl = 'https://example.com/zoom-7.3.0.msi'; InstallerType = 'MSI'; DetectionName = @('=Zoom')
            Production = @{ Version = '7.2.0'; DownloadUrl = 'https://example.com/zoom-7.2.0.msi' }
            PreInstall = @{ Url = 'https://evil.example.com/x.ps1'; Sha256 = ('A' * 64) }
        }
        $other = @{ Id = 'Autre'; Mode = 'Manual'; DetectionName = @('Autre') }
        $zoom | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'applications\zoom.json') -Encoding utf8
        $other | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'applications\autre.json') -Encoding utf8

        # CRLF volontaire: le hash publie doit etre celui du contenu LF servi par GitHub
        $hookFile = Join-Path $dir 'hooks\Zoom\PostInstall.ps1'
        [System.IO.File]::WriteAllText($hookFile, "Write-Log 'ok'`r`nRemove-File -Path 'x'`r`n")

        & $buildScript -CatalogRoot $dir *> $null
        $pilot = Get-Content -LiteralPath (Join-Path $dir 'apps.pilot.json') -Raw | ConvertFrom-Json
        $prod = Get-Content -LiteralPath (Join-Path $dir 'apps.json') -Raw | ConvertFrom-Json

        $lf = [System.Text.Encoding]::ASCII.GetBytes("Write-Log 'ok'`nRemove-File -Path 'x'`n")
        $expectedHash = (([System.Security.Cryptography.SHA256]::Create().ComputeHash($lf) | ForEach-Object { $_.ToString('X2') }) -join '')
    }

    AfterAll {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'le script est publie dans les deux anneaux avec son URL et son SHA256 (contenu LF)' {
        foreach ($catalog in $pilot, $prod) {
            $catalog.Applications.Zoom.PostInstall.Url | Should -Be 'https://raw.githubusercontent.com/YannRicher/AHU/main/catalog/hooks/Zoom/PostInstall.ps1'
            $catalog.Applications.Zoom.PostInstall.Sha256 | Should -Be $expectedHash
        }
    }

    It 'seuls les fichiers de catalog/hooks definissent les scripts (pas le manifeste)' {
        $pilot.Applications.Zoom.PSObject.Properties.Name | Should -Not -Contain 'PreInstall'
        $prod.Applications.Zoom.PSObject.Properties.Name | Should -Not -Contain 'PreInstall'
    }

    It 'une application sans script n''a ni PreInstall ni PostInstall' {
        $pilot.Applications.Autre.PSObject.Properties.Name | Should -Not -Contain 'PostInstall'
    }

    It 'le catalogue publie est valide pour le moteur' {
        @(Test-AhuAppDefinition -App $pilot.Applications.Zoom) | Should -BeNullOrEmpty
    }
}

Describe 'Validation des scripts' {
    BeforeEach {
        $dir = New-TempDirectory
    }

    AfterEach {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Test-AhuAppDefinition exige une URL https et un SHA256 valides' {
        $app = [pscustomobject]@{
            Id = 'X'; Mode = 'Manual'; DetectionName = @('X')
            PreInstall = [pscustomobject]@{ Url = 'http://exemple.com/a.ps1'; Sha256 = 'abc' }
        }
        $messages = @(Test-AhuAppDefinition -App $app)
        $messages.Count | Should -Be 2
        ($messages -join ' ') | Should -Match 'PreInstall'
    }

    It 'Get-AhuHookHash donne le meme hash en CRLF et en LF' {
        $crlf = Join-Path $dir 'crlf.ps1'
        $lf = Join-Path $dir 'lf.ps1'
        [System.IO.File]::WriteAllText($crlf, "a`r`nb`r`n")
        [System.IO.File]::WriteAllText($lf, "a`nb`n")
        Get-AhuHookHash -Path $crlf | Should -Be (Get-AhuHookHash -Path $lf)
    }

    It 'Get-AhuHookError accepte un script valide' {
        $file = Join-Path $dir 'ok.ps1'
        Set-Content -LiteralPath $file -Value "Write-Log 'ok'" -Encoding ascii
        @(Get-AhuHookError -Path $file) | Should -BeNullOrEmpty
    }

    It 'Get-AhuHookError refuse une erreur de syntaxe' {
        $file = Join-Path $dir 'syntaxe.ps1'
        Set-Content -LiteralPath $file -Value 'if ($x {' -Encoding ascii
        @(Get-AhuHookError -Path $file).Count | Should -BeGreaterThan 0
    }

    It 'Get-AhuHookError refuse des accents sans BOM, et les accepte avec BOM' {
        $text = "Write-Log 'caf" + [char]0xE9 + "'"
        $withoutBom = Join-Path $dir 'sans-bom.ps1'
        $withBom = Join-Path $dir 'avec-bom.ps1'
        [System.IO.File]::WriteAllText($withoutBom, $text, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($withBom, $text, (New-Object System.Text.UTF8Encoding($true)))
        @(Get-AhuHookError -Path $withoutBom).Count | Should -BeGreaterThan 0
        @(Get-AhuHookError -Path $withBom) | Should -BeNullOrEmpty
    }
}

Describe 'Relance apres ConflictAction Kill' {
    BeforeAll {
        $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $cmdHash = (Get-FileHash -LiteralPath $cmdExe -Algorithm SHA256).Hash
        $fakeApp = 'C:\Fake\ShareX.exe'

        function New-KillFixture {
            param([string]$Action = 'Kill', [string]$Arguments = '/c exit 0')
            [pscustomobject]@{
                Id = 'ShareX'; Name = 'ShareX'; Mode = 'Auto'; Version = '22.4.0'
                DownloadUrl = 'https://test/setup.exe'; Sha256 = $cmdHash; InstallerType = 'EXE'
                InstallArguments = $Arguments; RequireSignature = $false; DetectionName = @('ShareX*')
                ConflictingProcesses = @('ShareX'); ConflictAction = $Action
            }
        }
    }

    BeforeEach {
        $dir = New-TempDirectory
        Initialize-AhuLog -LogDirectory (Join-Path $dir 'Logs') | Out-Null
        Mock -ModuleName Installer Find-AhuInstalledApp { [pscustomobject]@{ DisplayVersion = '22.4.0' } }
        Mock -ModuleName Installer Start-Sleep { }
        Mock -ModuleName Installer Stop-Process { }
        Mock -ModuleName Installer Start-AhuUserProcess { $true }
        Mock -ModuleName Installer Get-AhuConflictingProcess { [pscustomobject]@{ ProcessName = 'ShareX'; Path = $fakeApp } }
        Mock -ModuleName Installer Save-AhuFile {
            New-Item -ItemType Directory -Path (Split-Path -Path $Destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $cmdExe -Destination $Destination -Force
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ferme le processus, installe, puis le relance dans la session de l''utilisateur' {
        $result = Install-AhuApp -App (New-KillFixture) -DataRoot $dir
        $result.Status | Should -Be 'Installed'
        Should -Invoke -ModuleName Installer Stop-Process -Times 1 -Exactly
        Should -Invoke -ModuleName Installer Start-AhuUserProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq $fakeApp }
    }

    It 'relance aussi quand l''installation echoue (l''utilisateur ne perd pas l''application)' {
        $result = Install-AhuApp -App (New-KillFixture -Arguments '/c exit 5') -DataRoot $dir
        $result.Status | Should -Be 'Failed'
        Should -Invoke -ModuleName Installer Start-AhuUserProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq $fakeApp }
    }

    It 'en mode Skip, rien n''est ferme ni relance (report)' {
        $result = Install-AhuApp -App (New-KillFixture -Action 'Skip') -DataRoot $dir
        $result.Status | Should -Be 'Deferred'
        Should -Invoke -ModuleName Installer Stop-Process -Times 0 -Exactly
        Should -Invoke -ModuleName Installer Start-AhuUserProcess -Times 0 -Exactly
    }

    It 'sans conflit, aucune relance' {
        Mock -ModuleName Installer Get-AhuConflictingProcess { @() }
        $result = Install-AhuApp -App (New-KillFixture) -DataRoot $dir
        $result.Status | Should -Be 'Installed'
        Should -Invoke -ModuleName Installer Start-AhuUserProcess -Times 0 -Exactly
    }

    It 'Start-AhuUserProcess retourne $false sans lever d''erreur si l''executable est absent' {
        Mock -ModuleName Installer Start-AhuUserProcess { $false }
        { Start-AhuUserProcess -FilePath 'C:\pas-la\x.exe' } | Should -Not -Throw
    }
}
