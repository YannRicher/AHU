# AHU - Journalisation
# Format: "yyyy-MM-dd HH:mm:ss - message" dans C:\ProgramData\AHU\Logs\AHU.log

$script:AhuLogFile = $null

function Initialize-AhuLog {
    [CmdletBinding()]
    param(
        [string]$LogDirectory = (Join-Path $env:ProgramData 'AHU\Logs'),
        [string]$FileName = 'AHU.log',
        [long]$MaxBytes = 5MB
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $script:AhuLogFile = Join-Path $LogDirectory $FileName

    if ((Test-Path -LiteralPath $script:AhuLogFile) -and ((Get-Item -LiteralPath $script:AhuLogFile).Length -gt $MaxBytes)) {
        Move-Item -LiteralPath $script:AhuLogFile -Destination ($script:AhuLogFile + '.old') -Force
    }

    $script:AhuLogFile
}

function Write-AhuLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $prefix = switch ($Level) {
        'Warning' { '[AVERTISSEMENT] ' }
        'Error'   { '[ERREUR] ' }
        default   { '' }
    }

    $line = '{0} - {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix, $Message
    Write-Verbose $line

    if ($script:AhuLogFile) {
        try {
            [System.IO.File]::AppendAllText($script:AhuLogFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-Verbose ('Impossible d''ecrire dans le journal: {0}' -f $_.Exception.Message)
        }
    }
}

Export-ModuleMember -Function Initialize-AhuLog, Write-AhuLog
