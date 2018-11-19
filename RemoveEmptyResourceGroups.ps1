##############################
#.SYNOPSIS
# Find and remove any empty Resource Groups
#
#.DESCRIPTION
# Find and remove any empty Resource Groups
#
#.PARAMETER Remove
# Set this parameter to remove the empty resources groups.
#
#.EXAMPLE
# .\RemoveEmptyResourceGroups.ps1 -Remove
#
#.NOTES
#
##############################

Param (
    [Parameter(Mandatory=$false)]
    [switch] $Remove
)

$count = 0
$emptyGroups = @()

# get all resources at once to avoid hitting API request limits
Write-Verbose "Getting all resources..."
$resources = $(Get-AzureRmResource).ResourceGroupName  | Sort-Object -Unique
Write-Verbose "Getting all Resources Groups..."
$groups =  $(Get-AzureRmResourceGroup).ResourceGroupName  | Sort-Object

# check for groups that don't have any resources tied to them
foreach ($group in $groups) {
    if ($resources -notcontains $group) {
        $emptyGroups += $group
    }
}

if ($emptyGroups.Length -eq 0) {
    Write-Output 'No empty Resource Groups found.'
    return
}

Write-Output 'Empty Resource Groups:'
$emptyGroups

# if -Remove switch not provided, stop
if (-not $Remove) {
    return
}

# execute actual removal of empty resource groups
Write-Output ""
foreach ($group in $emptyGroups) {
    Write-Verbose "Removing $group..."
    $null = Remove-AzureRmResourceGroup -ResourceGroupName $group -Force -ErrorAction "Stop"
    $count++;
    Write-Output "$group removed."
}

Write-Output "Total of $count Resource Groups removed."
