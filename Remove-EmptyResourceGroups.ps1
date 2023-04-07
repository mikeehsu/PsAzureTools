<#
.SYNOPSIS
Removes empty resource groups from the current Azure subscription.

.DESCRIPTION
This script removes any resource groups from the current Azure subscription that do not have any resources tied to them. It then checks for any groups that don't have any resources tied to them, and removes them if the -Force switch is provided.

.PARAMETER Force
If this switch is provided, the script will remove any empty resource groups without prompting for confirmation.

.EXAMPLE
Remove-EmptyResourceGroups.ps1 -Force
Removes all empty resource groups from the current Azure subscription without prompting for confirmation.

.EXAMPLE
Remove-EmptyResourceGroups.ps1
Lists all empty resource groups in the current Azure subscription, but does not remove them.

#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [switch] $Force
)

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Subscription) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Set-AzContext) context before proceeding."
        exit
    }
} catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Set-AzContext) context before proceeding."
    exit
}

# start processing
$stopWatchStart = [System.Diagnostics.Stopwatch]::StartNew()

# get all resources at once to avoid hitting API request limits
Write-Verbose "Getting all resources..."
$resources = $(Get-AzResource).ResourceGroupName  | Sort-Object -Unique

Write-Verbose "Getting all Resources Groups..."
$groups =  $(Get-AzResourceGroup).ResourceGroupName  | Sort-Object

# check for groups that don't have any resources tied to them
$emptyGroups = @()
foreach ($group in $groups) {
    if ($resources -notcontains $group) {
        $emptyGroups += $group
    }
}

if ($emptyGroups.Length -eq 0) {
    Write-Host 'No empty Resource Groups found.'
    Write-Host "Script Complete. $(Get-Date) ($($stopWatchStart.Elapsed.ToString()))"
    return
}

Write-Host 'Empty Resource Groups:'
$emptyGroups

# if -Force switch not provided, stop
if (-not $Force) {
    Write-Host "Use the -Force switch to remove the empty Resource Groups."
    Write-Host "Script Complete. $(Get-Date) ($($stopWatchStart.Elapsed.ToString()))"
    return
}

# execute actual removal of empty resource groups
Write-Host ""
$count = 0
foreach ($group in $emptyGroups) {
    Write-Verbose "Removing $group..."
    $null = Remove-AzResourceGroup -Name $group -Force -ErrorAction "Stop"
    Write-Host "$group removed."

    $count++;
}

Write-Host "$count resource groups removed."
Write-Host "Script Complete. $(Get-Date) ($($stopWatchStart.Elapsed.ToString()))"
