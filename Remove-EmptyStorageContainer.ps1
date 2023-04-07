<#
.SYNOPSIS
Deletes all empty containers from an Azure Storage Account.

.DESCRIPTION
This script deletes all empty containers from an Azure Storage Account.

.PARAMETER ResourceGroupName
The name of the resource group containing the storage account.

.PARAMETER StorageAccountName
The name of the storage account.

.EXAMPLE
.\Remove-EmptyStorageContainer.ps1 -ResourceGroupName "my-resource-group" -StorageAccountName "mystorageaccount"

This will delete all containers, with no blobs inside them, from the "mystorageaccount" storage account in the "my-resource-group" resource group.

.NOTES
- Azure PowerShell module must be installed. You can install it using the following command: `Install-Module -Name Az -AllowClobber -Scope CurrentUser`.
- You must be logged in to your Azure account using the `Connect-AzAccount` cmdlet.
#>

#require -module Az.Storage

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]    
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [Alias('Name')]
    [string] $StorageAccountName
)

#region - confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before running this script."
    }
}
catch {
    throw "Please login (Connect-AzAccount) and set the proper subscription context before running this script."
}
#endregion

# Import the Az.Storage module
Import-Module Az.Storage

# start stopwatch   
$stopWatchStart = [System.Diagnostics.Stopwatch]::StartNew()

# Set the resource group name
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop

# Get a list of all containers in the storage account
$containers = Get-AzStorageContainer -Context $storageAccount.Context

#region - Loop through each container and check if it's empty
$deleteCount = 0
foreach ($container in $containers) {
    try {
        Write-Verbose "Checking container $($container.Name)..."
        $blobCount = (Get-AzStorageBlob -Container $container.Name -Context $storageAccount.Context).Count
        if ($blobCount -eq 0) {
            # If the container is empty, delete it
            Remove-AzStorageContainer -Name $container.Name -Context $storageAccount.Context
            Write-Host "$($container.Name) deleted."
            $deleteCount++
        }
    }
    catch {
        Write-Error "Error deleting container $($container.Name): $_"
    }
}
#endregion

Write-Host "$($containers.Count) containers were checked."
Write-Host "$deleteCount empty containers have been deleted from $StorageAccountName."
Write-Host "Script Complete. $(Get-Date) ($($stopWatchStart.Elapsed.ToString()))"
