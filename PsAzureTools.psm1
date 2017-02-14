Import-Module 'AzureRm'


##########################################################################

function Move-PsatNetworkInterface
{
    [CmdletBinding()]

    Param(
        [parameter(Mandatory=$True)]
        [string] $NicName,

        [parameter(Mandatory=$True)]
        [string] $VnetName,

        [parameter(Mandatory=$True)]
        [string] $SubnetName
    )

    $nic = Get-AzureRmNetworkInterface | Where-Object {$_.Name -eq $NicName }
    if (-not $nic) {
        Write-Error "$nicName NIC not found."
        return
    }

    $vnet = Get-AzureRmVirtualNetwork | Where-Object {$_.Name -eq $VnetName}
    if (-not $vnet) {
        Write-Error "$VnetName Vnet not found."
        return
    }

    $subnet = $vnet.Subnets | Where-Object {$_.Name -eq $SubnetName}
    if (-not $subnet) {
        Write-Error "$SubnetName Subnet not found."
        return
    }

    $nic.IpConfigurations[0].Subnet.Id = $subnet.Id
    Set-AzureRmNetworkInterface -NetworkInterface $nic
}


##########################################################################
function Remove-PsatNetworkSecurityGroup {

    [CmdletBinding()]

    Param(
        [parameter(Mandatory=$True)]
        [string] $nsgId
    )

    $parts = $nsgId.Split('/')
    $resourceGroupName = $parts[4]
    $networkSecurityGroupName = $parts[8]

    $nsg = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $networkSecurityGroupName
    if ($nsg.NetworkInterfaces -or $nsg.Subnets) {
        Write-Verbose "NetworkSecurityGroup $($resourceGroupName) / $($networkSecurityGroupName) is still being used"
    } else {
        Write-Verbose "Removing NetworkSecurityGroup $($resoruceGroupName) / $($networkSecurityGroupName)"
        $result = Remove-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $networkSecurityGroupName -Force
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
        [bool] $KeepNetworkInterface,

        [parameter(Mandatory=$False)]
        [bool] $KeepNetworkSecurityGroup,

        [parameter(Mandatory=$False)]
        [bool] $KeepPublicIp,

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
        $confirmation = Read-Host "Are you sure you want to remove $($ResourceGroupName) / $($VmName)?"
        if ($confirmation.ToUpper() -ne 'Y') {
            Write-Output 'Command Aborted.'
            return
        }
    }

    try {
        Write-Verbose "Removing VirtualMachine $($ResourceGroupName) / $($VmName)"
        $result = Remove-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -ErrorAction 'Stop'

        # remove all Nics, if necessary
        if (-not $KeepNetworkInterface) {
            $nicIds = $vm.NetworkInterfaceIDs

            foreach ($nicId in $nicIds) {
                Write-Verbose "Get NICs info for $nicId"
                $nicResource = Get-AzureRmResource -ResourceId $nicId -ErrorAction 'Stop'

                $nic = Get-AzureRmNetworkInterface -ResourceGroupName $($nicResource.ResourceGroupName) -Name $($nicResource.ResourceName)

                Write-Verbose "Removing NetworkInterface  $($nicResource.ResourceGroupName) / $($nicResource.ResourceName)"
                $result = Remove-AzureRmNetworkInterface -ResourceGroupName $($nicResource.ResourceGroupName) -Name $($nicResource.ResourceName) -Force

                # remove any Public IPs (attached to Nic), if necessary
                if (-not $KeepPublicIp) {
                    if ($nic.IpConfigurations.publicIpAddress) {
                        Write-Verbose "Getting Pip info for $($nic.IpConfigurations.publicIpAddress.Id)"
                        $pipId = $nic.IpConfigurations.publicIpAddress.Id
                        $pipResource = Get-AzureRmResource -ResourceId $pipId -ErrorAction 'Stop'

                        if ($pipResource) {
                            Write-Verbose "Removing Pip $($nic.IpConfigurations.publicIpAddress.Id)"
                            $result = $( Get-AzureRmPublicIpAddress -ResourceGroupName $($pipResource.ResourceGroupName) -Name $($pipResource.ResourceName) | Remove-AzureRmPublicIpAddress -Force )
                        }
                    }
                }

                # remove unused NetworkSecurityGroup
                if (-not $KeepNetworkSecurityGroup) {
                    Write-Verbose "okay to remove nsg"
                    if ($nic.NetworkSecurityGroup) {
                        Write-Verbose "attempting to remove nsg"
                        $result = Remove-PsatNetworkSecurityGroup -nsgId $nic.NetworkSecurityGroup.Id
                    }
                }

           }
        }

        # remove OSDisk, if necessary
        if (-not $KeepOsDisk) {
            # remove os managed disk
            $managedDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.id
            if ($managedDiskId) {
                $managedDiskName = $managedDiskId.Split('/')[8]
                Write-Verbose "Removing ManagedDisk $($ResourceGroupName) / $($managedDiskName)"
                $result = Remove-AzureRmDisk -ResourceGroupName $ResourceGroupName -DiskName $managedDiskName -Force
            }

            # remove os disk
            $osDisk = $vm.StorageProfile.OsDisk.Vhd.Uri
            if ($osDisk) {
                Write-Verbose "Removing OSDisk $osDisk"
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
            Write-Verbose "Checking ResourceGroup $ResourceGroupName"
            $resources = Get-AzureRmResource | Where-Object {$_.ResourceGroupName -eq "$ResourceGroupName" }
            if (-not $resources) {
                Write-Verbose "Removing resource group $ResourceGroupName"
                $result = Remove-PsatResourceGroup -Name $ResourceGroupName -ErrorAction Continue
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

Function Update-PsatVm
{
    [CmdletBinding()]

    Param(
        [parameter(Mandatory=$True)]
        [string] $ResourceGroupName,

        [parameter(Mandatory=$True)]
        [string] $FromVmName,

        [parameter(Mandatory=$False)]
        [string] $VmName,

        [parameter(Mandatory=$False)]
        [string] $VmSize,

        [parameter(Mandatory=$False)]
        [string] $AvailabilitySetId
   )

    Write-Verbose "Getting VM info for $FromVmName"

    # get vm information
    $fromVm = Get-AzureRmVm -ResourceGroupName $ResourceGroupName -VmName $FromVmName
    if (-not $fromVm) {
        Write-Error "$FromVmName VM not found."
        return
    }

    if (-not $fromVm) {
        Write-Error "Unable to get information for $FromVmName"
        return
    }

    if ($fromVm -like [array]) {
        Write-Error "$($fromVm.Count) VMs named $FromVmName exist. Please specify -ResourceGroup"
        return
    }


    # set vaules if new ones provided
    if (-not $VmSize) {
        $VmSize = $fromVm.HardwareProfile.VmSize
    }

    if (-not $AvailabilitySet) {
        $AvailabilitySetId = $vm.AvailabilitySetReference.Id
    }


    # create new config, depending with availability set
    if ($AvailabilitySetId) {
        $vm = New-AzureRmVmConfig               `
                -Name $VmName                   `
                -VmSize $VmSize
                -AvailabilitySetId $AvailabilitySetId
    } else {
        $vm = New-AzureRmVmConfig               `
                -Name $VmName                   `
                -VmSize $VmSize
    }

    # attach nics
    foreach ($nicId in $fromVm.NetworkInterfaceIDs) {
        $vm = $vm | Add-AzureRmVMNetworkInterface -Id $nicId
    }

    # set new osdisk
    if (-not $OsDiskName) {
        Write-Error "Changing disk name to $DiskName not yet available."
        return

        # copy vhd file to new destination
        # set diskname to new uri
    }
    $OsDiskName = $VmName + 'OsDisk'
    $OsDiskUri  = $fromVm.StorageProfile.OsDisk.Vhd.Uri

    $vm = $vm | Set-AzureRmVMOSDisk -Name $osDiskName -VhdUri $OSDiskUri -CreateOption 'Attach' -Windows

    # attach datadisks
    $i = 0
    foreach ($disk in $dataDisks) {
        $diskName = $VmName + 'DataDisk' + $i.ToString()
        $vm = $vm | Add-AzureRmVMDataDisk -Name 'DataDisk1' -Caching 'ReadOnly' -Lun $i -VhdUri $DataDiskVhdUri -CreateOption 'Attach'
    }

    ## Create the VM in Azure
    Write-Verbose "Creating $($vm.name)"
    New-AzureRmVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm

}
