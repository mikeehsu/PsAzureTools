##############################
#.SYNOPSIS
# Find Unused Storage
#
#.DESCRIPTION
# Find Unused Storage looks for unused VHD files (not attached to a
# Virtual Machine) and storage accounts used for boot diagnostics
# which no Virtual Machines are pointing to
#
#.PARAMETER CleanupScript
# File path to generate a Powershell script to delete the VHD files
# and Storage Accounts
#
#.EXAMPLE
# FindUnusedStorage.ps1 -CleanUpScript .\cleanupmyaccount.ps1
#
#.NOTES
#
##############################

Param(
    [parameter(Mandatory=$False)]
    [string] $CleanupScript
)


function IsDiskAttachedToVm
{

    Param(
        [parameter(Mandatory=$True)]
        [array] $VmList,

        [parameter(Mandatory=$True)]
        [string] $BlobName
    )

    # Write-Verbose "looking for blob: $Blobname"

    foreach ($vm in $vmList) {
        # Write-Verbose "looking at VM: $($vm.Name) ... OS: $($vm.StorageProfile.osdisk.vhd.uri)"
        if ($vm.StorageProfile.osdisk.vhd.uri -like "*/$($BlobName)") {
            return $True
        }

        foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
            # Write-Verbose "looking at DATA: $($vm.Name) ... $($dataDisk.vhd.uri)"
            if ($dataDisk.vhd.Uri -like "*/$($BlobName)") {
                return $True
            }
        }
    }

    return $False
}

function IsAccountUsedByDiagnostics
{
    Param(
        [parameter(Mandatory=$True)]
        [array] $VmList,

        [parameter(Mandatory=$True)]
        [string] $StorageAccountName
    )

    # Write-Verbose "looking for StorageAccountName: $StorageAccountName"

    foreach ($vm in $vmList) {
        # Write-Verbose "looking at VM: $($vm.Name) ... OS: $($vm.DiagnosticsProfile.BootDiagnostics.StorageUri)"
        if ($vm.DiagnosticsProfile.BootDiagnostics.StorageUri -like "*/$($StorageAccountName).") {
            return $True
        }
    }

}


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

# start processing
$vms = Get-AzureRmVM
$storageAccounts = Get-AzureRMStorageAccount

foreach ($storageAccount in $storageAccounts) {

    Write-Verbose "Checking account: $($storageAccount.StorageAccountName)..."

    if ($storageAccount.StorageAccountName -like '*diag*') {
        $isUsed = IsAccountUsedByDiagnostics -VmList $vms -StorageAccountName $storageAccount.StorageAccountName
        if (-not $isUsed) {
            Write-Output "NOT USED FOR DIAGNOSTICS -- Account: $($storageAccount.StorageAccountName )"
        }
    }

    $cleanupScriptHeader = $False

    $storageAccountKey = Get-AzureRmStorageAccountKey `
        -ResourceGroupName $storageAccount.ResourceGroupName `
        -Name $storageAccount.StorageAccountName

    $storageContext = New-AzureStorageContext `
        -StorageAccountName $storageAccount.StorageAccountName `
        -StorageAccountKey $storageAccountKey.Value[0]

    $containers = Get-AzureStorageContainer -context $storageContext
    foreach ($container in $containers) {
        Write-Verbose "Checking container: $($container.Name)..."

        $blobs = Get-AzureStorageBlob -context $storageContext -Container $container.Name
        foreach ($blob in $blobs) {

            Write-Verbose "Checking blob: $($blob.Name)"

            if ($blob.Name -like '*.vhd') {
                $isAttached = IsDiskAttachedToVm -VmList $vms -Blobname $blob.Name
                if (-not $isAttached) {

                    if ($CleanupScript -and -not $cleanupScriptHeader) {
                        $output = '
##########
$storageAccount = Get-AzureRMStorageAccount -ResourceGroupName ' +
                            $storageAccount.ResourceGroupName +
                            ' -Name ' + $storageAccount.StorageAccountName
                        Write-Output $output | Out-File $CleanupScript -Append

                        $output = '$storageAccountKey = Get-AzureRmStorageAccountKey `
    -ResourceGroupName $storageAccount.ResourceGroupName `
    -Name $storageAccount.StorageAccountName
                            '
                        Write-Output $output | Out-File $CleanupScript -Append

                        $output =  '$storageContext = New-AzureStorageContext `
    -StorageAccountName $storageAccount.StorageAccountName `
    -StorageAccountKey $storageAccountKey.Value[0]
                            '
                        Write-Output $output | Out-File $CleanupScript -Append

                        $cleanupScriptHeader = $True
                    }

                    Write-Output "NOT USED -- Account: $($storageAccount.StorageAccountName ) Container: $($container.Name) Blob: $($blob.Name) LeaseStatus: $($blob.ICloudBlob.Properties.LeaseStatus) LeaseState: $($blob.ICloudBlob.Properties.LeaseState)"
                    if ($CleanupScript) {
                        $output = 'Remove-AzureStorageBlob -Context $storageContext -Container ' +
                            $container.Name +
                            ' -Blob ' + $blob.Name
                        Write-Output $output | Out-File $CleanupScript -Append
                    }
                }
            }
        }
    }


}


