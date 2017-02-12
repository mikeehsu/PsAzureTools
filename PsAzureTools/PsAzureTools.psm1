Import-Module 'AzureRm'

##########################################################################
Function Remove-PsatVmComplete
{
    [CmdletBinding()]

    Param(
        [parameter(Mandatory=$True, Position=0, ValueFromPipeline=$True, ValueFromPipelineByPropertyName=$True)]
        [string] $VmName,

        [parameter(Mandatory=$False)]
        [string] $ResourceGroupName,

        [parameter(Mandatory=$False)]
        [bool] $KeepNic,

        [parameter(Mandatory=$False)]
        [bool] $KeepPip,

        [parameter(Mandatory=$False)]
        [bool] $KeepOsDisk,

        [parameter(Mandatory=$False)]
        [bool] $KeepDataDisk,

        [parameter(Mandatory=$False)]
        [bool] $KeepResourceGroup,

        [parameter(Mandatory=$False)]
        [bool] $Force
    )

    Write-Verbose "Getting VM info for $VmName"

    # get vm information
    if ($ResourceGroupName) {
        $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction 'Stop'
    } else {
        $vm = Get-AzureRmVM | Where-Object {$_.Name -eq $VmName}

        # no Vm's found
        if (-not $vm) {
            Write-Error "$VmName VM not found."
            return
        }

        # more than one Vm with $VmName found
        if ($vm -like [array]) {
            Write-Error "$($vm.Count) VMs named $VmName exist. Please specify -ResourceGroup"
            return
        }

        $ResourceGroupName = $vm.ResourceGroupName
    }

    # no Vm found
    if (-not $vm) {
        Write-Error "Unable to get information for $vmName"
        return
    }

    # confirm machine
    if (-not $Force) {
        $confirmation = Read-Host "Are you sure you want to remove $($VmName)?"
        if ($confirmation.ToUpper() -ne 'Y') {
            Write-Output 'Command Aborted.'
            return
        }
    }

    try {
        Write-Verbose "Removing $VmName (ResourceGroupName: $ResourceGroupName)"
        $result = Remove-PsatRmVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -ErrorAction 'Stop'

        # remove all Nics, if necessary
        if (-not $KeepNic) {
            $nicIds = $vm.NetworkInterfaceIDs

            foreach ($nicId in $nicIds) {
                Write-Verbose "Get NICs info for $nicId"
                $nicResource = Get-AzureRmResource -ResourceId $nicId -ErrorAction 'Stop'

                $nic = Get-AzureRmNetworkInterface -ResourceGroupName $($nicResource.ResourceGroupName) -Name $($nicResource.ResourceName)

                Write-Verbose "Removing NIC  $($nicResource.ResourceGroupName) / $($nicResource.ResourceName)"
                $result = Remove-PsatRmNetworkInterface -ResourceGroupName $($nicResource.ResourceGroupName) -Name $($nicResource.ResourceName) -Force

                # remove any Public IPs (attached to Nic), if necessary
                if (-not $KeepPip) {
                    if ($nic.IpConfigurations.publicIpAddress) {
                        Write-Verbose "Getting Pip info for $($nic.IpConfigurations.publicIpAddress.Id)"
                        $pipId = $nic.IpConfigurations.publicIpAddress.Id
                        $pipResource = Get-AzureRmResource -ResourceId $pipId -ErrorAction 'Stop'

                        if ($pipResource) {
                            Write-Verbose "Removing Pip $($nic.IpConfigurations.publicIpAddress.Id)"
                            $result = $( Get-AzureRmPublicIpAddress -ResourceGroupName $($pipResource.ResourceGroupName) -Name $($pipResource.ResourceName) | Remove-PsatRmPublicIpAddress -Force )
                        }
                    }
                }
           }
        }


        # remove OSDisk, if necessary
        if (-not $KeepOsDisk) {
            # remove os managed disk
            $managedDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.id
            if ($managedDisk) {
                $managedDiskName = $managedDiskId.Split('/')[8]
                $result = Remove-PsatRmDisk -ResourceGroupName $ResourceGroupName -DiskName $managedDiskName -Force
            }

            # remove os disk
            $osDisk = $vm.StorageProfile.OsDisk.Vhd.Uri
            Write-Verbose "Removing OSDisk $osDisk"
            if ($osDisk) {
                $result = Remove-PsatStorageBlobByUri -Uri $osDisk
            }
        }

        # remove DataDisks all data disks, if necessary
        $dataDisks = $vm.StorageProfile.DataDisks
        if (-not $KeepDataDisk) {
            foreach ($dataDisk in $dataDisks) {
                Write-Verbose "Removing DataDisk $dataDisk.vhd.Uri"
                $result = Remove-PsatStorageBlobByUri -Uri "$($dataDisk.vhd.Uri)"
            }
        }

        # remove ResourceGroup, if nothing else inside
        if (-not $KeepResourceGroup) {
            Write-Verbose "Checking resource group $ResourceGroupName"
            $resources = Get-AzureRmResource | Where-Object {$_.ResourceGroupName -eq "$ResourceGroupName" }
            if (-not $resources) {
                Write-Verbose "Removing resource group $ResourceGroupName"
                $result = Remove-PsatRmResourceGroup -Name $ResourceGroupName -ErrorAction Continue
            }
        }

    } catch {
        $_.Exception
        Write-Error $_.Exception.Message
        Write-Error "Unable to reomve all components of the VM. Please check to make sure all components were properly removed."
        return
    }

    return
}


##########################################################################
function Remove-PsatStorageBlobByUri {

    [CmdletBinding()]

    Param(
        [parameter(Mandatory=$True)]
        [string] $Uri
    )

    Write-Verbose "Removing StorageBlob $Uri"
    $uriParts = $Uri.Split('/')
    $storageAccountName = $uriParts[2].Split('.')[0]
    $container = $uriParts[3]
    $blobName = $uriParts[4..$($uriParts.Count-1)] -Join '/'

    $resourceGroupName = $(Get-AzureRmStorageAccount | Where-Object {$_.StorageAccountName -eq "$storageAccountName"}).ResourceGroupName
    if (-not $resourceGroupName) {
        Write-Error "Error getting ResourceGroupName for $Uri"
        return
    }

    Write-Verbose "Removing blob: $blobName from resourceGroup: $resourceGroupName, storageAccount: $storageAccountName, container: $container"
    Set-AzureRmCurrentStorageAccount -ResourceGroupName "$resourceGroupName" -StorageAccountName "$storageAccountName"
    Remove-PsatStorageBlob -Container $container -Blob $blobName
}

