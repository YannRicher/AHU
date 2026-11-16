# AHU - Comparaison de versions
# Compare n'importe quel format numerique ("7.2.51704", "25.001.20531", "24.09", "8.0.4310.10").
# Les segments non numeriques sont ignores; les segments manquants valent 0.

function ConvertTo-AhuVersionPart {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { return }

    foreach ($match in [regex]::Matches($Version, '\d+')) {
        [decimal]$match.Value
    }
}

function Compare-AhuVersion {
    <#
        Retourne -1 si Version < ReferenceVersion, 0 si egales, 1 si Version > ReferenceVersion.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter(Mandatory = $true, Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ReferenceVersion
    )

    [decimal[]]$left = @(ConvertTo-AhuVersionPart $Version)
    [decimal[]]$right = @(ConvertTo-AhuVersionPart $ReferenceVersion)
    $count = [Math]::Max($left.Count, $right.Count)

    for ($i = 0; $i -lt $count; $i++) {
        $a = if ($i -lt $left.Count) { $left[$i] } else { 0 }
        $b = if ($i -lt $right.Count) { $right[$i] } else { 0 }
        if ($a -lt $b) { return -1 }
        if ($a -gt $b) { return 1 }
    }

    return 0
}

function Test-AhuVersionString {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version
    )

    return (-not [string]::IsNullOrWhiteSpace($Version)) -and ($Version -match '\d')
}

Export-ModuleMember -Function ConvertTo-AhuVersionPart, Compare-AhuVersion, Test-AhuVersionString
