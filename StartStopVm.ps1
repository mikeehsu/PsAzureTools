<#
.SYNOPSIS
Start or Stop a set of Virtual Macheins.

.DESCRIPTION
This script is used to Start or Stop a set of Vms. All item listed in the -Include parameters will be selected. All items listed in the -Exclude parameters will be excluded. Exclusions will take precedence.

.PARAMETER IncludeVmNames
List of Virtual Machine Names to include

.PARAMETER ExcludeVmNames
List of Virtual Machine Names to exclude

.PARAMETER IncludeResourceGroupNames
List of resource group names to include in the action

.PARAMETER ExcludeResourceGroupNames
List of resource group names to exclude in the action

.PARAMETER IncludeTags
List of tags and tag values to include in the action

.PARAMETER ExcludeTags
List of tags and tag values to exclude in the action

.PARAMETER Wait
If specified this will wait until the action completes before returning back. By default, the script will end once the action has been requested.

.EXAMPLE
.\StartStopVm.ps1 -IncludeResourceGroupNames 'test-rg' -IncludeTags = @( @{ENIVRONMENT = 'DEV'} ) -ExcludeVmNames 'my-db'

.NOTES
#>
[CmdletBinding()]

Param (
    [Parameter(Mandatory = $true)]
    [string] $Action,

    [Parameter(Mandatory = $false)]
    [array] $IncludeVmNames,

    [Parameter(Mandatory = $false)]
    [array] $ExcludeVmNames,

    [Parameter(Mandatory = $false)]
    [array] $IncludeResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [array] $ExcludResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [array] $IncludeTags,

    [Parameter(Mandatory = $false)]
    [array] $ExcludeTags,

    [Parameter(Mandatory = $false)]
    [switch] $Wait
)

#######################################################################
## MAIN

$startTime = Get-Date

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw"Please login (Login-AzureRmAccount) and set the proper subscription context before proceeding."
    }

}
catch {
    throw "Please login and set the proper subscription context before proceeding."
}

# validate parameters
if ( @('Start', 'Stop') -notcontains $Action) {
    throw "Action ($Action) invalid. Action must be either Start of Stop."
}

if (-not $IncludeVmNames -and
    -not $IncludeResourceGroupNames -and
    -not $IncludeTags -and
    -not $ExcludeVmNames -and
    -not $ExcludeResourceGroupNames -and
    -not $ExcludeTags) {
    throw "Must specify at least one -Include or -Exclude criteria"
}

# build inclusion expression
$includeItems = @()
if ($IncludeVmNames) {
    $includeItems += '$IncludeVmNames -contains $_.Name'
}

if ($IncludeResourceGroupNames) {
    $includeItems += '$IncludeResourceGroupNames -contains $_.ResourceGroupName'
}

foreach ($tag in $IncludeTags) {
    $includeItems += '$_.Tags.' + $tag.Keys + " -eq '" + $tag.Values + "'"
}

$includeExpr = $includeItems -join ' -or '
Write-Verbose "VMs to include: $includeExpr"


# build exclusion expression
$excludeItems = @()
if ($ExcludeVmNames) {
    $excludeItems += '$ExcludeVmNames -contains $_.Name'
}

if ($ExcludeResourceGroupNames) {
    $excludeItems += '$ExcludeResourceGroupNames -contains $_.ResourceGroupName'
}

foreach ($tag in $ExcludeTags) {
    $excludeItems += '$_.Tags.' + $tag.Keys + " -eq '" + $tag.Values + "'"
}

$excludeExpr = $excludeItems -join ' -or '
Write-Verbose "VMs to exclude: $excludeExpr"

# get Vms
try {
    $cmd = "Get-AzVm | Where-Object { ($includeExpr) -and -not ($excludeExpr) }"
    $vms = Invoke-Expression $cmd
} catch {
    throw "Error selecting VMs - $cmd"
}
Write-Output "VMs selected: $($vms.Name -join ', ')"


# execute the action
$jobs = @()
foreach ($vm in $vms) {
    if ($Action -eq 'Start') {
        $jobs += Start-AzVm -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -AsJob
        Write-Output "$($vm.Name) starting"

    } elseif ($Action -eq 'Stop') {
        $jobs += Stop-AzVm -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -AsJob
        Write-Output "$($vm.Name) stopping"

    } else {
        throw "Invalid action ($Action)"
    }
}

# wait for jobs to complete
if (-not $Wait) {
    return
}

[System.Collections.ArrayList] $jobIds = $($jobs.Id)
do {
    $job = Wait-Job -Id $jobIds[0]
    Write-Output "$($job.Name) $($job.StatusMessage)"

    $jobIds.Remove($jobIds[0])
} until (-not $jobIds)

$elapsedTime = $(Get-Date) - $startTime
$totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
Write-Output "$Action complete. ($totalTime elapsed)"
