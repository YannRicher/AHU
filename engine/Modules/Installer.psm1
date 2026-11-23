# AHU - Telechargement et installation silencieuse (MSI / EXE)

function New-AhuInstallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Installed', 'Deferred', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$ExitCode = -1,

        [bool]$RebootRequired = $false
    )

    [pscustomobject]@{
        Status         = $Status
        Message        = $Message
        ExitCode       = $ExitCode
        RebootRequired = $RebootRequired
    }
}

function Save-AhuFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [int]$RetryCount = 3
    )

    Enable-AhuTls12

    $directory = Split-Path -Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $partial = $Destination + '.part'
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing -ErrorAction Stop
                Move-Item -LiteralPath $partial -Destination $Destination -Force
                return
            }
            catch {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                if ($attempt -ge $RetryCount) { throw }
                Write-AhuLog ('Echec du telechargement (tentative {0}/{1}): {2}' -f $attempt, $RetryCount, $_.Exception.Message) -Level Warning
                Start-Sleep -Seconds (10 * $attempt)
            }
        }
    }
    finally {
        $ProgressPreference = $previousProgress
    }
}

function Get-AhuInstallerFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App
    )

    $type = ([string](Get-AhuValue $App 'InstallerType' 'EXE')).ToLowerInvariant()
    $name = $null
    try {
        $name = [System.IO.Path]::GetFileName(([uri][string](Get-AhuValue $App 'DownloadUrl' '')).AbsolutePath)
    }
    catch {
        $name = $null
    }

    if ($name) {
        foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '') }
    }

    if (-not $name -or [System.IO.Path]::GetExtension($name).ToLowerInvariant() -ne ('.' + $type)) {
        $name = '{0}-setup.{1}' -f $App.Id, $type
    }

    $name
}

function Get-AhuConflictingProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App
    )

    foreach ($name in @(Get-AhuValue $App 'ConflictingProcesses' @())) {
        $processName = [System.IO.Path]::GetFileNameWithoutExtension([string]$name)
        if ($processName) {
            Get-Process -Name $processName -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AhuProcess {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [AllowEmptyString()]
        [string]$Arguments = '',

        [int]$TimeoutMinutes = 30
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = Split-Path -Path $FilePath -Parent

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            try { $process.Kill() } catch { Write-Verbose $_.Exception.Message }
            throw ('delai d''installation depasse ({0} min)' -f $TimeoutMinutes)
        }
        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Split-AhuUninstallCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $commandLine = $CommandLine.Trim()
    if ($commandLine -match '^"([^"]+)"(?:\s+(.*))?$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = [string]$Matches[2] }
    }

    $parts = $commandLine -split '\s+', 2
    [pscustomobject]@{
        FilePath  = $parts[0]
        Arguments = $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
    }
}

function Uninstall-AhuUserInstall {
    <#
        Desinstalle une copie par utilisateur (HKCU) via sa UninstallString, en silencieux.
        Utilise quand ReplaceUserInstall est vrai, pour remplacer la copie personnelle par l'installation machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [Parameter(Mandatory = $true)]
        $Entry
    )

    $commandLine = [string]$Entry.UninstallString
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        Write-AhuLog ('{0}: installation utilisateur {1} sans UninstallString' -f $App.Id, $Entry.DisplayVersion) -Level Warning
        return $false
    }

    $command = Split-AhuUninstallCommand -CommandLine $commandLine
    if (-not (Test-Path -LiteralPath $command.FilePath)) {
        Write-AhuLog ('{0}: desinstallateur introuvable ({1})' -f $App.Id, $command.FilePath) -Level Warning
        return $false
    }

    $arguments = $command.Arguments
    if ($arguments -notmatch '(?i)(^|\s)(/silent|/quiet|/qn)(\s|$)') {
        $arguments = ('{0} /silent' -f $arguments).Trim()
    }

    try {
        Write-AhuLog ('{0}: desinstallation de l''installation utilisateur {1} ({2} {3})' -f $App.Id, $Entry.DisplayVersion, $command.FilePath, $arguments)
        $exitCode = Invoke-AhuProcess -FilePath $command.FilePath -Arguments $arguments -TimeoutMinutes 15
        if ($exitCode -ne 0) {
            Write-AhuLog ('{0}: desinstallation utilisateur terminee avec le code {1}' -f $App.Id, $exitCode) -Level Warning
            return $false
        }
        Write-AhuLog ('{0}: installation utilisateur {1} retiree' -f $App.Id, $Entry.DisplayVersion)
        return $true
    }
    catch {
        Write-AhuLog ('{0}: echec de la desinstallation utilisateur - {1}' -f $App.Id, $_.Exception.Message) -Level Error
        return $false
    }
}

function Remove-AhuStaleCache {
    <#
        Supprime les dossiers de cache d'une application qui ne correspondent pas a la version cible.
        Exemple: un MSI 7.1 reste apres un echec, puis la cible passe a 7.2 => le dossier 7.1 est supprime.
        Le dossier de la version cible est conserve pour reprendre sans retelecharger.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string]$TargetVersion,

        [Parameter(Mandatory = $true)]
        [string]$DataRoot
    )

    $appCache = Join-Path $DataRoot ('Cache\{0}' -f $AppId)
    if (-not (Test-Path -LiteralPath $appCache)) { return 0 }

    $removed = 0
    foreach ($directory in @(Get-ChildItem -LiteralPath $appCache -Directory)) {
        if ($directory.Name -eq $TargetVersion) { continue }
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $directory.FullName)) { $removed++ }
    }
    return $removed
}

function Remove-AhuOldMsiLog {
    <#
        Ne garde que les $Keep journaux MSI les plus recents par application.
        Fichiers attendus: <Id>-<version>-msi.log
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [int]$Keep = 2
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) { return 0 }

    $removed = 0
    $files = @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*-msi.log' -File)
    $groups = $files | Group-Object -Property {
        $m = [regex]::Match($_.Name, '^(.+)-[^-]+-msi\.log$')
        if ($m.Success) { $m.Groups[1].Value } else { $_.Name }
    }

    foreach ($group in $groups) {
        $old = @($group.Group | Sort-Object -Property LastWriteTime -Descending | Select-Object -Skip $Keep)
        foreach ($file in $old) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $file.FullName)) { $removed++ }
        }
    }
    return $removed
}

function Install-AhuApp {
    <#
        Telecharge, verifie (SHA256 + signature Authenticode) et installe silencieusement une application du catalogue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $App,

        [string]$DataRoot = (Join-Path $env:ProgramData 'AHU')
    )

    $id = $App.Id
    $version = [string](Get-AhuValue $App 'Version' '')
    $type = ([string](Get-AhuValue $App 'InstallerType' '')).ToUpperInvariant()
    $url = [string](Get-AhuValue $App 'DownloadUrl' '')

    # 1. Processus en conflit (ex.: Zoom ouvert pendant une reunion)
    $conflicts = @(Get-AhuConflictingProcess -App $App)
    if ($conflicts.Count -gt 0) {
        $names = (@($conflicts | ForEach-Object { $_.ProcessName } | Select-Object -Unique)) -join ', '
        if ([string](Get-AhuValue $App 'ConflictAction' 'Skip') -eq 'Kill') {
            Write-AhuLog ('{0}: fermeture des processus en conflit ({1})' -f $id, $names)
            $conflicts | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        else {
            $message = 'installation reportee, processus en cours d''execution: {0}' -f $names
            Write-AhuLog ('{0}: {1}' -f $id, $message) -Level Warning
            return New-AhuInstallResult -Status Deferred -Message $message
        }
    }

    $appCache = Join-Path $DataRoot ('Cache\{0}' -f $id)
    $installer = Join-Path (Join-Path $appCache $version) (Get-AhuInstallerFileName -App $App)
    $expectedHash = [string](Get-AhuValue $App 'Sha256' '')

    $staleCache = Remove-AhuStaleCache -AppId $id -TargetVersion $version -DataRoot $DataRoot
    if ($staleCache -gt 0) {
        Write-AhuLog ('{0}: {1} ancien(s) dossier(s) de cache supprime(s)' -f $id, $staleCache)
    }

    try {
        # 2. Telechargement (reutilise le cache si le hash correspond)
        $reuse = $false
        if ($expectedHash -and (Test-Path -LiteralPath $installer)) {
            $reuse = ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -eq $expectedHash.ToUpperInvariant())
        }

        if ($reuse) {
            Write-AhuLog ('{0}: installateur deja en cache ({1})' -f $id, $installer)
        }
        else {
            Write-AhuLog ('{0}: telechargement demarre ({1})' -f $id, $url)
            Save-AhuFile -Uri $url -Destination $installer
            Write-AhuLog ('{0}: telechargement termine ({1:N1} Mo)' -f $id, ((Get-Item -LiteralPath $installer).Length / 1MB))
        }

        # 3. Integrite
        if ($expectedHash) {
            $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash.ToUpperInvariant()) {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                throw ('SHA256 invalide (attendu {0}, obtenu {1})' -f $expectedHash, $actualHash)
            }
            Write-AhuLog ('{0}: SHA256 verifie' -f $id)
        }

        if ([bool](Get-AhuValue $App 'RequireSignature' $true)) {
            $signature = Get-AuthenticodeSignature -FilePath $installer
            $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
            if ($signature.Status -ne 'Valid') {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                throw ('signature Authenticode invalide ({0})' -f $signature.Status)
            }
            $expectedSigner = [string](Get-AhuValue $App 'SignerSubject' '')
            if ($expectedSigner -and $subject -notlike ('*{0}*' -f $expectedSigner)) {
                Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
                throw ('signataire inattendu ({0}), attendu: {1}' -f $subject, $expectedSigner)
            }
            Write-AhuLog ('{0}: signature valide ({1})' -f $id, $subject)
        }

        # 4. Installation
        $installArguments = [string](Get-AhuValue $App 'InstallArguments' '')
        if ($type -eq 'MSI') {
            $logDirectory = Join-Path $DataRoot 'Logs'
            # 2 anciens journaux conserves + le nouveau = 3 au maximum par application
            [void](Remove-AhuOldMsiLog -LogDirectory $logDirectory -Keep 2)
            $msiLog = Join-Path $logDirectory ('{0}-{1}-msi.log' -f $id, $version)
            $filePath = Join-Path $env:SystemRoot 'System32\msiexec.exe'
            $arguments = ('/i "{0}" {1} /L*v "{2}"' -f $installer, $installArguments, $msiLog).Trim()
        }
        else {
            $filePath = $installer
            $arguments = $installArguments
        }

        Write-AhuLog ('{0}: installation demarree ({1} {2})' -f $id, (Split-Path -Path $filePath -Leaf), $arguments)
        $exitCode = Invoke-AhuProcess -FilePath $filePath -Arguments $arguments -TimeoutMinutes ([int](Get-AhuValue $App 'InstallTimeoutMinutes' 30))

        $successCodes = @(Get-AhuValue $App 'SuccessExitCodes' @(0, 1641, 3010) | ForEach-Object { [int]$_ })
        $rebootRequired = @(1641, 3010) -contains $exitCode
        if ($successCodes -notcontains $exitCode) {
            if ($exitCode -eq 1618) {
                throw 'une autre installation est deja en cours (code 1618), nouvel essai au prochain cycle'
            }
            throw ('echec de l''installateur (code de sortie {0})' -f $exitCode)
        }

        # 5. Verification apres installation
        $entry = Find-AhuInstalledApp -App $App
        if ($null -eq $entry -or (Compare-AhuVersion $entry.DisplayVersion $version) -lt 0) {
            $found = if ($entry) { $entry.DisplayVersion } else { 'aucune' }
            throw ('installation terminee (code {0}) mais version detectee: {1}' -f $exitCode, $found)
        }

        $message = 'installation completee, version {0} detectee' -f $entry.DisplayVersion
        if ($rebootRequired) { $message += ' (redemarrage requis)' }
        Write-AhuLog ('{0}: {1}' -f $id, $message)

        Remove-Item -LiteralPath $appCache -Recurse -Force -ErrorAction SilentlyContinue
        return New-AhuInstallResult -Status Installed -Message $message -ExitCode $exitCode -RebootRequired $rebootRequired
    }
    catch {
        $message = 'echec: {0}' -f $_.Exception.Message
        Write-AhuLog ('{0}: {1}' -f $id, $message) -Level Error
        return New-AhuInstallResult -Status Failed -Message $message
    }
}

Export-ModuleMember -Function New-AhuInstallResult, Save-AhuFile, Get-AhuInstallerFileName, Get-AhuConflictingProcess, Invoke-AhuProcess, Split-AhuUninstallCommand, Uninstall-AhuUserInstall, Remove-AhuStaleCache, Remove-AhuOldMsiLog, Install-AhuApp
