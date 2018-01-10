##############################
#.SYNOPSIS
# Find publicly accessible storage containers
#
#.DESCRIPTION
# This script will loop through all containers and output
# the names of any where PublicAccess is not set to "Off"
##
#.EXAMPLE
# FindPublicAccessStorage.ps1
#
#.NOTES
#
##############################

# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
        exit
    }
    $azureEnvironmentName = $result.Environment.Name

} catch {
    Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
    exit
}

$storageAccounts = Get-AzureRMStorageAccount

foreach ($storageAccount in $storageAccounts) {
    $storageAccountKey = Get-AzureRmStorageAccountKey `
        -ResourceGroupName $storageAccount.ResourceGroupName `
        -Name $storageAccount.StorageAccountName

    $storageContext = New-AzureStorageContext `
        -StorageAccountName $storageAccount.StorageAccountName `
        -StorageAccountKey $storageAccountKey.Value[0]

    Write-Debug "Checking $($storageAccount.StorageAccountName)"

    $publicOnContainers = Get-AzureStorageContainer -context $storageContext |
        Where-Object {$_.PublicAccess -ne 'Off' }

    foreach ($container in $publicOnContainers) {
        Write-Output "WARNING!! $($storageAccount.StorageAccountName)/$($container.Name) is publicly accessible"
    }
}
