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
        Write-Output "WARNING!! $($storageAccount.StorageAccountName) > $($container.Name) is publicly accessible"
    }
}
