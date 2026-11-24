# AHU - Scripts avant / apres installation (PreInstall / PostInstall)
#
# Les scripts sont des fichiers .ps1 du depot (catalog/hooks/<Id>/PreInstall.ps1 et PostInstall.ps1).
# Le catalogue contient leur URL et leur SHA256: le poste telecharge, verifie le hash, puis execute
# le script dans un PROCESSUS SEPARE (un "exit" ou une erreur du script ne peut pas arreter le moteur).
# Code de sortie du processus: 0 = succes, autre = echec (celui du "exit N" du script, ou 1 sur erreur).

function ConvertTo-AhuPsLiteral {
    <#
        Valeur -> litteral PowerShell entre apostrophes (pour generer le script d'execution).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) { return '$null' }
    return ("'" + ([string]$Value).Replace("'", "''") + "'")
}

function Get-AhuHookHelperSource {
    <#
        Fonctions utilitaires disponibles dans les scripts avant/apres (noms de PSAppDeployToolkit v3,
        alias v4 pour les memes operations). Par defaut une erreur arrete le script (echec de la phase);
        -ContinueOnError $true consigne un avertissement et continue.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return @'
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string[]]$Message = @(),
        [int]$Severity = 1,
        [string]$Source = '',
        [bool]$ContinueOnError = $true
    )
    foreach ($line in $Message) {
        if ($Severity -eq 3) { Write-Host ('[Erreur] ' + $line) }
        elseif ($Severity -eq 2) { Write-Host ('[Avertissement] ' + $line) }
        else { Write-Host $line }
    }
}

function ConvertTo-AhuHookRegistryPath {
    param([Parameter(Mandatory = $true)][string]$Key)
    $roots = @{ HKLM = 'HKEY_LOCAL_MACHINE'; HKCU = 'HKEY_CURRENT_USER'; HKCR = 'HKEY_CLASSES_ROOT'; HKU = 'HKEY_USERS'; HKCC = 'HKEY_CURRENT_CONFIG' }
    if ($Key -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\?(.*)$') {
        return ('Registry::' + $roots[$Matches[1]] + '\' + $Matches[2])
    }
    if ($Key -match '^Registry::') { return $Key }
    if ($Key -match '^HKEY_') { return ('Registry::' + $Key) }
    throw ('Chemin de registre non pris en charge: ' + $Key)
}

function Remove-File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [switch]$Recurse,
        [bool]$ContinueOnError = $false
    )
    foreach ($item in $Path) {
        try {
            if ($Recurse) {
                $parent = Split-Path -Path $item -Parent
                $leaf = Split-Path -Path $item -Leaf
                $files = @(Get-ChildItem -LiteralPath $parent -Filter $leaf -Recurse -File -Force -ErrorAction SilentlyContinue)
            }
            else {
                $files = @(Get-Item -Path $item -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
            }
            if ($files.Count -eq 0) { Write-Host ('Rien a supprimer: ' + $item); continue }
            foreach ($file in $files) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Host ('Fichier supprime: ' + $file.FullName)
            }
        }
        catch {
            if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
        }
    }
}

function Remove-Folder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [bool]$ContinueOnError = $false
    )
    foreach ($item in $Path) {
        try {
            if (Test-Path -LiteralPath $item -PathType Container) {
                Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction Stop
                Write-Host ('Dossier supprime: ' + $item)
            }
            else {
                Write-Host ('Rien a supprimer: ' + $item)
            }
        }
        catch {
            if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
        }
    }
}

function Copy-File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Recurse,
        [bool]$ContinueOnError = $false
    )
    try {
        $isFolder = ($Destination.EndsWith('\') -or $Destination.EndsWith('/') -or (Test-Path -LiteralPath $Destination -PathType Container))
        if ($isFolder -and -not (Test-Path -LiteralPath $Destination -PathType Container)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        foreach ($item in $Path) {
            Copy-Item -Path $item -Destination $Destination -Recurse:$Recurse -Force -ErrorAction Stop
            Write-Host ('Copie: ' + $item + ' -> ' + $Destination)
        }
    }
    catch {
        if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
    }
}

function New-Folder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [bool]$ContinueOnError = $false
    )
    foreach ($item in $Path) {
        try {
            if (-not (Test-Path -LiteralPath $item -PathType Container)) {
                New-Item -ItemType Directory -Path $item -Force -ErrorAction Stop | Out-Null
                Write-Host ('Dossier cree: ' + $item)
            }
        }
        catch {
            if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
        }
    }
}

function Set-RegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Name,
        $Value,
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'Unknown')][string]$Type = 'String',
        [bool]$ContinueOnError = $false
    )
    try {
        $path = ConvertTo-AhuHookRegistryPath -Key $Key
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        }
        if ($Name) {
            New-ItemProperty -LiteralPath $path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
            Write-Host ('Registre: ' + $Key + ' [' + $Name + '] defini')
        }
        else {
            Write-Host ('Registre: ' + $Key + ' cree')
        }
    }
    catch {
        if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
    }
}

function Get-RegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Value,
        [bool]$ContinueOnError = $false
    )
    try {
        $path = ConvertTo-AhuHookRegistryPath -Key $Key
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        if ($Value) {
            $property = Get-ItemProperty -LiteralPath $path -Name $Value -ErrorAction SilentlyContinue
            if ($property) { return $property.$Value }
            return $null
        }
        return (Get-ItemProperty -LiteralPath $path -ErrorAction Stop)
    }
    catch {
        if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message); return $null } else { throw }
    }
}

function Remove-RegistryKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Name,
        [switch]$Recurse,
        [bool]$ContinueOnError = $false
    )
    try {
        $path = ConvertTo-AhuHookRegistryPath -Key $Key
        if (-not (Test-Path -LiteralPath $path)) { Write-Host ('Rien a supprimer: ' + $Key); return }
        if ($Name) {
            if ($null -ne (Get-ItemProperty -LiteralPath $path -Name $Name -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -LiteralPath $path -Name $Name -Force -ErrorAction Stop
                Write-Host ('Registre: ' + $Key + ' [' + $Name + '] supprime')
            }
            else {
                Write-Host ('Rien a supprimer: ' + $Key + ' [' + $Name + ']')
            }
        }
        else {
            Remove-Item -LiteralPath $path -Recurse:$Recurse -Force -ErrorAction Stop
            Write-Host ('Registre: ' + $Key + ' supprime')
        }
    }
    catch {
        if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
    }
}

function Get-InstalledApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Name,
        [switch]$Exact
    )
    $roots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $properties -or -not $properties.DisplayName) { continue }
            foreach ($pattern in $Name) {
                $isMatch = if ($Exact) { $properties.DisplayName -eq $pattern } else { $properties.DisplayName -like ('*' + $pattern + '*') }
                if ($isMatch) {
                    [pscustomobject]@{
                        DisplayName     = [string]$properties.DisplayName
                        DisplayVersion  = [string]$properties.DisplayVersion
                        Publisher       = [string]$properties.Publisher
                        UninstallString = [string]$properties.UninstallString
                        InstallLocation = [string]$properties.InstallLocation
                        ProductCode     = [string]$key.PSChildName
                    }
                    break
                }
            }
        }
    }
}

function Execute-Process {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Parameters = '',
        [string]$WorkingDirectory = '',
        [int[]]$IgnoreExitCodes = @(),
        [bool]$ContinueOnError = $false
    )
    try {
        $arguments = @{ FilePath = $Path; Wait = $true; PassThru = $true; NoNewWindow = $true; ErrorAction = 'Stop' }
        if ($Parameters) { $arguments.ArgumentList = $Parameters }
        if ($WorkingDirectory) { $arguments.WorkingDirectory = $WorkingDirectory }
        $process = Start-Process @arguments
        $code = [int]$process.ExitCode
        Write-Host ('Code de sortie de ' + (Split-Path -Path $Path -Leaf) + ': ' + $code)
        if ($code -ne 0 -and ($IgnoreExitCodes -notcontains $code)) {
            throw ('Echec de ' + $Path + ' (code de sortie ' + $code + ')')
        }
        [pscustomobject]@{ ExitCode = $code }
    }
    catch {
        if ($ContinueOnError) { Write-Host ('[Avertissement] ' + $_.Exception.Message) } else { throw }
    }
}

Set-Alias -Name Write-ADTLogEntry -Value Write-Log
Set-Alias -Name Remove-ADTFile -Value Remove-File
Set-Alias -Name Remove-ADTFolder -Value Remove-Folder
Set-Alias -Name Copy-ADTFile -Value Copy-File
Set-Alias -Name New-ADTFolder -Value New-Folder
Set-Alias -Name Set-ADTRegistryKey -Value Set-RegistryKey
Set-Alias -Name Get-ADTRegistryKey -Value Get-RegistryKey
Set-Alias -Name Remove-ADTRegistryKey -Value Remove-RegistryKey
Set-Alias -Name Get-ADTApplication -Value Get-InstalledApplication
Set-Alias -Name Start-ADTProcess -Value Execute-Process
'@
}

function Get-AhuHookVariable {
    <#
        Variables disponibles dans les scripts (noms inspires de PSAppDeployToolkit v3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PreInstall', 'PostInstall')]
        [string]$Phase,

        [string]$InstallerPath = '',

        [string]$InstalledVersion = '',

        [string]$DataRoot = (Join-Path $env:ProgramData 'AHU')
    )

    [ordered]@{
        appId                      = [string]$App.Id
        appName                    = [string](Get-AhuValue $App 'Name' $App.Id)
        appVersion                 = [string](Get-AhuValue $App 'Version' '')
        installedVersion           = $InstalledVersion
        installPhase               = $(if ($Phase -eq 'PreInstall') { 'Pre-Installation' } else { 'Post-Installation' })
        installerPath              = $InstallerPath
        dirAhuLogs                 = (Join-Path $DataRoot 'Logs')
        envProgramFiles            = [string]$env:ProgramFiles
        envProgramFilesX86         = [string]${env:ProgramFiles(x86)}
        envProgramData             = [string]$env:ProgramData
        envCommonDesktop           = [Environment]::GetFolderPath('CommonDesktopDirectory')
        envCommonStartMenu         = [Environment]::GetFolderPath('CommonStartMenu')
        envCommonStartMenuPrograms = [Environment]::GetFolderPath('CommonPrograms')
        envCommonStartUp           = [Environment]::GetFolderPath('CommonStartup')
        envWinDir                  = [string]$env:SystemRoot
        envSystemDrive             = [string]$env:SystemDrive
        envTemp                    = [System.IO.Path]::GetTempPath()
    }
}

function Get-AhuHookFile {
    <#
        Telecharge et verifie (SHA256) les scripts avant/apres declares pour l'application.
        Retourne une table: PreInstall et/ou PostInstall => chemin local.
        Echoue (exception) si un script est introuvable ou si son hash ne correspond pas:
        rien n'est alors modifie sur le poste.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $files = @{}
    foreach ($phase in 'PreInstall', 'PostInstall') {
        $hook = Get-AhuValue $App $phase
        if (-not $hook) { continue }

        $url = [string](Get-AhuValue $hook 'Url' '')
        $expected = [string](Get-AhuValue $hook 'Sha256' '')
        if (-not $url -or -not $expected) {
            throw ('script {0}: Url et Sha256 obligatoires' -f $phase)
        }

        $destination = Join-Path $Directory ('{0}.ps1' -f $phase)
        Save-AhuFile -Uri $url -Destination $destination
        $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($actual -ne $expected.ToUpperInvariant()) {
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            throw ('script {0}: SHA256 invalide (attendu {1}, obtenu {2})' -f $phase, $expected, $actual)
        }

        Write-AhuLog ('{0}: script {1} telecharge et verifie' -f $App.Id, $phase)
        $files[$phase] = $destination
    }

    return $files
}

function Invoke-AhuHook {
    <#
        Execute un script avant/apres dans un processus PowerShell separe, avec un delai maximum.
        Ne leve jamais d'exception: retourne Success, ExitCode et Message (la sortie est ecrite dans le journal AHU).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PreInstall', 'PostInstall')]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string]$InstallerPath = '',

        [string]$InstalledVersion = '',

        [string]$DataRoot = (Join-Path $env:ProgramData 'AHU'),

        [double]$TimeoutMinutes = 10
    )

    $id = [string]$App.Id
    $process = $null
    try {
        $variables = Get-AhuHookVariable -App $App -Phase $Phase -InstallerPath $InstallerPath -InstalledVersion $InstalledVersion -DataRoot $DataRoot

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('$ErrorActionPreference = ''Stop''')
        $lines.Add('$ProgressPreference = ''SilentlyContinue''')
        foreach ($name in $variables.Keys) {
            $lines.Add(('${0} = {1}' -f $name, (ConvertTo-AhuPsLiteral $variables[$name])))
        }
        $lines.Add((Get-AhuHookHelperSource))
        # Le script est insere tel quel (et non appele avec ".") pour qu'un "exit N" termine bien le processus avec le code N
        $lines.Add('try {')
        $lines.Add([System.IO.File]::ReadAllText($ScriptPath))
        $lines.Add('}')
        $lines.Add('catch {')
        $lines.Add('    [Console]::Error.WriteLine(''Erreur: '' + $_.Exception.Message)')
        $lines.Add('    if ($_.InvocationInfo) { [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage) }')
        $lines.Add('    exit 1')
        $lines.Add('}')
        $lines.Add('exit 0')

        $wrapperDirectory = Join-Path $DataRoot ('Cache\{0}' -f $id)
        if (-not (Test-Path -LiteralPath $wrapperDirectory)) {
            New-Item -ItemType Directory -Path $wrapperDirectory -Force | Out-Null
        }
        $wrapper = Join-Path $wrapperDirectory ('run-{0}.ps1' -f $Phase)
        [System.IO.File]::WriteAllText($wrapper, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Process -Id $PID).Path
        $startInfo.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $wrapper)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.WorkingDirectory = Split-Path -Path $wrapper -Parent

        $process = [System.Diagnostics.Process]::Start($startInfo)
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit([int]($TimeoutMinutes * 60 * 1000))) {
            try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
            Write-AhuLog ('{0}: [{1}] delai depasse ({2} min), script arrete' -f $id, $Phase, $TimeoutMinutes) -Level Error
            return [pscustomobject]@{ Success = $false; ExitCode = -1; Message = ('delai depasse ({0} min)' -f $TimeoutMinutes) }
        }
        $process.WaitForExit()

        $outputLines = @(($outputTask.Result -split '\r?\n') | Where-Object { $_.Trim() })
        $errorLines = @(($errorTask.Result -split '\r?\n') | Where-Object { $_.Trim() })
        foreach ($line in ($outputLines | Select-Object -First 200)) {
            Write-AhuLog ('{0}: [{1}] {2}' -f $id, $Phase, $line.TrimEnd())
        }
        foreach ($line in ($errorLines | Select-Object -First 50)) {
            Write-AhuLog ('{0}: [{1}] {2}' -f $id, $Phase, $line.TrimEnd()) -Level Warning
        }

        $code = [int]$process.ExitCode
        if ($code -eq 0) {
            return [pscustomobject]@{ Success = $true; ExitCode = 0; Message = 'termine' }
        }

        $message = 'code de sortie {0}' -f $code
        if ($errorLines.Count -gt 0) { $message = '{0}: {1}' -f $message, $errorLines[0].Trim() }
        Write-AhuLog ('{0}: [{1}] echec - {2}' -f $id, $Phase, $message) -Level Error
        return [pscustomobject]@{ Success = $false; ExitCode = $code; Message = $message }
    }
    catch {
        $message = $_.Exception.Message
        Write-AhuLog ('{0}: [{1}] erreur - {2}' -f $id, $Phase, $message) -Level Error
        return [pscustomobject]@{ Success = $false; ExitCode = -1; Message = $message }
    }
    finally {
        if ($process) { $process.Dispose() }
    }
}

Export-ModuleMember -Function ConvertTo-AhuPsLiteral, Get-AhuHookHelperSource, Get-AhuHookVariable, Get-AhuHookFile, Invoke-AhuHook
