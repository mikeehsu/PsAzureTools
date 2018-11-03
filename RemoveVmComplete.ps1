[CmdletBinding()]

Param(
    [parameter(Mandatory = $True, Position = 0, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True)]
    [string] $VmName,

    [parameter(Mandatory = $False)]
    [string] $ResourceGroupName,

    [parameter(Mandatory = $False)]
    [bool] $KeepNetworkInterface,

    [parameter(Mandatory = $False)]
    [bool] $KeepNetworkSecurityGroup,

    [parameter(Mandatory = $False)]
    [bool] $KeepPublicIp,

    [parameter(Mandatory = $False)]
    [bool] $KeepOsDisk,

    [parameter(Mandatory = $False)]
    [bool] $KeepDataDisk,

    [parameter(Mandatory = $False)]
    [bool] $KeepDiagnostics,

    [parameter(Mandatory = $False)]
    [bool] $KeepResourceGroup,

    [parameter(Mandatory = $False)]
    [bool] $Force
)

##########################################################################
function RemoveNetworkSecurityGroupById {

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
        $null = Remove-AzureRmNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $networkSecurityGroupName -Force
    }

    return
}

##########################################################################
function RemoveStorageBlobByUri {

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
    Remove-AzureStorageBlob -Container $container -Blob $blobName
}

##########################################################################
Write-Verbose "Getting VM info for $VmName"

# get vm information
if ($ResourceGroupName) {
    $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction 'Stop'
}
else {
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
                    $result = RemoveNetworkSecurityGroupById -nsgId $nic.NetworkSecurityGroup.Id
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
            $result = RemoveStorageBlobByUri -Uri $osDisk
        }
    }

    # remove DataDisks all data disks, if necessary
    $dataDisks = $vm.StorageProfile.DataDisks
    if (-not $KeepDataDisk) {
        foreach ($dataDisk in $dataDisks) {
            $managedDiskId = $datadisk.ManagedDisk.id
            if ($managedDiskId) {
                $managedDiskName = $managedDiskId.Split('/')[8]
                Write-Verbose "Removing Managed Disk $($ResourceGroupName) / $($managedDiskName)"
                $result = Remove-AzureRmDisk -ResourceGroupName $ResourceGroupName -DiskName $managedDiskName -Force
            }

            # remove os disk
            $vhdUri = $datadisk.Vhd.Uri
            if ($vhdUri) {
                Write-Verbose "Removing Unmanaged VHD $vhdUri"
                $result = RemoveStorageBlobByUri -Uri $vhdUri
            }
        }
    }

    # delete diagnostic logs
    if (-not $KeepDiagnostics) {
        $storageUri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri
        if ($storageUri) {
            $uriParts = $storageUri.Split('/')
            $storageAccountName = $uriParts[2].Split('.')[0]

            $storageRg = $(Get-AzureRmStorageAccount | Where-Object {$_.StorageAccountName -eq "$storageAccountName"}).ResourceGroupName
            if (-not $storageRg) {
                Write-Error "Error getting ResourceGroupName for $storageUri"
                return
            }

            $null = Set-AzureRmCurrentStorageAccount -ResourceGroupName $storageRg -StorageAccountName $storageAccountName
            $container = Get-AzureStorageContainer  | Where-Object {$_.Name -like "bootdiagnostics-*-$($vm.VmId)" }
            if ($container) {
                Write-Verbose "Removing container: $($container.name) from resourceGroup: $storageRg, storageAccount: $storageAccountName"
                Remove-AzureStorageContainer -Name $($container.name)
            }
        }
    }

    # remove ResourceGroup, if nothing else inside
    if (-not $KeepResourceGroup) {
        Write-Verbose "Checking ResourceGroup $ResourceGroupName"
        $resources = Get-AzureRmResource | Where-Object {$_.ResourceGroupName -eq "$ResourceGroupName" }
        if (-not $resources) {
            Write-Verbose "Removing resource group $ResourceGroupName"
            $result = Remove-AzureRmResourceGroup -Name $ResourceGroupName -ErrorAction Continue
        }
    }

}
catch {
    $_.Exception
    Write-Error $_.Exception.Message
    Write-Error $result
    Write-Error "Unable to reomve all components of the VM. Please check to make sure all components were properly removed."
    return
}

