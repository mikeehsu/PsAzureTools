<#
.SYNOPSIS
Watch for new TCP connections

.DESCRIPTION
This script will continuously display new TCP connections made.
You can include or exclude specific IP addresses from the display,
using the following options:

[C] to Clear all filters
[M] to Mark the current stream with a timestamp
[L] to add a filter on a local IP address/port
[R] to add a filter on a remote IP address/port
[S] to show the current filters
[Q] to quit

.EXAMPLE
Watch-NetTcpConnection.ps1

.NOTES
#>

$LocalInclude = @()
$LocalExclude = @()
$RemoteInclude = @()

$continueWatching = $true
$after = Get-NetTCPConnection
$after | Select-Object
while ($continueWatching) {
    $before = $after

    Write-Progress -Activity 'Watching' -Status "$(Get-Date -Format 'HH:mm:ss') [C]lear   [M]ark   [L]ocal$(if ($LocalInclude) {'*'})   [R]emote$(if ($RemoteInclude) {'*'})   [S]how   [Q]uit"
    if ([System.Console]::KeyAvailable) {
        $key = [System.Console]::ReadKey()
        switch ($key.Key) {
            'C' {
                Write-Output "---------- $(Get-Date -Format 'HH:mm:ss') Filters cleared ----------"
                $LocalInclude = @()
                $RemoteInclude = @()
            }

            'L' {
                $add = Read-Host -Prompt 'LocalAddress to add (or Clear/Toggle)'
                if ($add.StartsWith('C', 'CurrentCultureIgnoreCase')) {
                    $LocalInclude = @()
                }
                elseif ($add.StartsWith('T', 'CurrentCultureIgnoreCase')) {
                    $temp = $LocalInclude
                    $LocalInclude = $LocalExclude
                    $LocalExclude = $temp
                }
                else {
                    $LocalInclude += $add
                }
                Write-Output "---------- $(Get-Date -Format 'HH:mm:ss') LocalInclude=@($($LocalInclude | Join-String -SingleQuote -Separator ',')); LocalExclude=@($($LocalExclude | Join-String -SingleQuote -Separator ','))----------"
            }

            'M' {
                Write-Output "---------- Time now: $(Get-Date -Format 'HH:mm:ss') ----------"
                break
            }

            'R' {
                $add = Read-Host -Prompt "RemoteAddress to add (or 'Clear')"
                if ($add.StartsWith('C', 'CurrentCultureIgnoreCase')) {
                    $RemoteInclude = @()
                }
                else {
                    $RemoteInclude += $add
                }
                Write-Output "---------- $(Get-Date -Format 'HH:mm:ss') RemoteInclude=@($($RemoteInclude | Join-String -SingleQuote -Separator ',')) ----------"
            }

            'S' {
                Write-Output "---------- $(Get-Date -Format 'HH:mm:ss') LocalInclude=@($($LocalInclude | Join-String -SingleQuote -Separator ',')) ----------"
                Write-Output "---------- $(Get-Date -Format 'HH:mm:ss') LocalExclude=@($($LocalExclude | Join-String -SingleQuote -Separator ',')) ----------"
                Write-Output "---------- $(Get-Date -Format 'HH:mm:ss') RemoteInclude=@($($RemoteInclude | Join-String -SingleQuote -Separator ',')) ----------"
            }

            'Q' {
                $continueWatching = $false
                break
            }
        }
    }
    else {
        Start-Sleep -Seconds 1
    }

    $after = Get-NetTCPConnection
    $diff = Compare-Object -ReferenceObject $before -DifferenceObject $after
    if ($diff.Count -gt 0) {
        $diff.InputObject
        | Where-Object { -not $RemoteInclude -or $RemoteInclude -contains $_.RemoteAddress }
        | Where-Object { -not $LocalInclude -or $LocalInclude -contains $_.LocalAddress }
        | Where-Object { -not $LocalExclude -or $LocalExclude -notcontains $_.LocalAddress }
    }
}