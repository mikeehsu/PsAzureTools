[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]

Param(
    [Parameter(Position = 0, Mandatory, ParameterSetName = 'Vm', ValueFromPipeline)]
    [Object[]] $Vm,

    [Parameter(Mandatory, ParameterSetName = 'VmName', ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'VmName', ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [Alias('Name')]
    [string] $VmName,

    [switch] $KeepNetworkInterface,

    [switch] $KeepNetworkSecurityGroup,

    [switch] $KeepPublicIp,

    [switch] $KeepOsDisk,

    [switch] $KeepDataDisk,

    [switch] $KeepDiagnostics,

    [switch] $KeepResourceGroup,

    [switch] $Force
)

##########################################################################
function RemoveNetworkSecurityGroupById {

    [CmdletBinding()]

    Param(
        [parameter(Mandatory = $True)]
        [string] $nsgId
    )

    $parts = $nsgId.Split('/')
    $resourceGroupName = $parts[4]
    $networkSecurityGroupName = $parts[8]

    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $networkSecurityGroupName
    if ($nsg.NetworkInterfaces -or $nsg.Subnets) {
        Write-Verbose "NetworkSecurityGroup $($resourceGroupName) / $($networkSecurityGroupName) is still being used"
    }
    else {
        Write-Verbose "Removing NetworkSecurityGroup $($resourceGroupName) / $($networkSecurityGroupName)"
        $null = Remove-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Name $networkSecurityGroupName -Force
    }

    return
}

##########################################################################
function RemoveStorageBlobByUri {

    Param(
        [parameter(Mandatory = $True)]
        [string] $Uri
    )

    Write-Verbose "Removing StorageBlob $Uri"
    $uriParts = $Uri.Split('/')
    $storageAccountName = $uriParts[2].Split('.')[0]
    $container = $uriParts[3]
    $blobName = $uriParts[4..$($uriParts.Count - 1)] -Join '/'

    $resourceGroupName = $(Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq "$storageAccountName" }).ResourceGroupName
    if (-not $resourceGroupName) {
        Write-Error "Error getting ResourceGroupName for $Uri"
        return
    }

    Write-Verbose "Removing blob: $blobName from resourceGroup: $resourceGroupName, storageAccount: $storageAccountName, container: $container"
    Set-AzCurrentStorageAccount -ResourceGroupName "$resourceGroupName" -StorageAccountName "$storageAccountName"
    Remove-AzStorageBlob -Container $container -Blob $blobName
}

##########################################################################

#region check parameters
if ($PSCmdlet.ParameterSetName -eq 'Vm') {
    $ResourceGroupName = $vm.ResourceGroupName
    $VmName = $vm.Name

}

Write-Verbose "Getting VM info for $VmName"
# get vm information
if ($ResourceGroupName) {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction 'Stop'
}
else {
    $vm = Get-AzVM | Where-Object { $_.Name -eq $VmName }

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
    if (-not $PSCmdlet.ShouldContinue("Are you sure?", "Remove $($ResourceGroupName)/$($VmName)")) {
        Write-Host 'Command Aborted.'
        return
    }
    $ConfirmImpact="Low"
}
#endregion

try {
    #region delete the VM
    if ($Force -or $PSCmdlet.ShouldProcess($VmName, "Remove-AzVm")) {
        Write-Verbose "Removing VirtualMachine $($ResourceGroupName) / $($VmName)"
        $result = Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -ErrorAction 'Stop'
    }
    #endregion

    #region all Nics, if necessary
    if (-not $KeepNetworkInterface) {
        $nicIds = $vm.NetworkProfile.Networkinterfaces.Id

        foreach ($nicId in $nicIds) {
            Write-Verbose "Get NICs info for $nicId"
            $nicResource = Get-AzResource -ResourceId $nicId -ErrorAction 'Stop'
            $nic = Get-AzNetworkInterface -ResourceGroupName $($nicResource.ResourceGroupName) -Name $($nicResource.Name)

            if ($Force -or $PSCmdlet.ShouldProcess($nicResource.Name, "Remove-AzNetworkInterface")) {
                Write-Verbose "Removing NetworkInterface $($nicResource.ResourceGroupName) / $($nicResource.Name)"
                $result = Remove-AzNetworkInterface -ResourceGroupName $($nicResource.ResourceGroupName) -Name $($nicResource.Name) -Force
            }

            # remove any Public IPs (attached to Nic), if necessary
            if (-not $KeepPublicIp) {
                if ($nic.IpConfigurations.publicIpAddress) {
                    Write-Verbose "Getting public IP $($nic.IpConfigurations.publicIpAddress.Id)"
                    $pipId = $nic.IpConfigurations.publicIpAddress.Id
                    $pipResource = Get-AzResource -ResourceId $pipId -ErrorAction 'Stop'

                    if ($pipResource) {
                        if ($Force -or $PSCmdlet.ShouldProcess($pipResource.Name, "Remove-AzPublicIpAddress")) {
                            Write-Verbose "Removing public IP $($nic.IpConfigurations.publicIpAddress.Id)"
                            $result = $( Get-AzPublicIpAddress -ResourceGroupName $($pipResource.ResourceGroupName) -Name $($pipResource.Name) | Remove-AzPublicIpAddress -Force )

                        }
                    }
                }
            }
            else {
                Write-Verbose "Keeping public IP..."
            }

            # remove unused NetworkSecurityGroup
            if (-not $KeepNetworkSecurityGroup) {
                if ($nic.NetworkSecurityGroup) {
                    Write-Verbose "Removing network security group $($nic.NetworkSecurityGroup.Id)"
                    $result = RemoveNetworkSecurityGroupById -nsgId $nic.NetworkSecurityGroup.Id
                }
            }
            else {
                Write-Verbose "Keeping network security group..."
            }
        }
    }
    else {
        Write-Verbose "Keeping network interface(s)... $($vm.NetworkInterfaceIDs)"
    }
    #endregion

    #region OSDisk, if necessary
    if (-not $KeepOsDisk) {
        # remove os managed disk
        $managedDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.id
        if ($managedDiskId) {
            $managedDiskName = $managedDiskId.Split('/')[8]
            if ($Force -or $PSCmdlet.ShouldProcess($managedDiskName, "Remove-AzDisk")) {
                Write-Verbose "Removing ManagedDisk $($ResourceGroupName) / $($managedDiskName)"
                $result = Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $managedDiskName -Force

            }
        }
        # remove os disk
        $osDisk = $vm.StorageProfile.OsDisk.Vhd.Uri
        if ($osDisk) {
            if ($Force -or $PSCmdlet.ShouldProcess($osDisk, "Remove Storage Blob")) {
                Write-Verbose "Removing OSDisk $osDisk"
                $result = RemoveStorageBlobByUri -Uri $osDisk
            }
        }
    }
    else {
        Write-Verbose "Keeping OS disks..."
    }
    #endregion

    #region DataDisks all data disks, if necessary
    $dataDisks = $vm.StorageProfile.DataDisks
    if (-not $KeepDataDisk) {
        foreach ($dataDisk in $dataDisks) {
            $managedDiskId = $datadisk.ManagedDisk.id
            if ($managedDiskId) {
                $managedDiskName = $managedDiskId.Split('/')[8]
                if ($Force -or $PSCmdlet.ShouldProcess($managedDiskName, "Remove-AzDisk")) {
                    Write-Verbose "Removing Managed Disk $($ResourceGroupName) / $($managedDiskName)"
                    $result = Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $managedDiskName -Force
                }
            }

            # remove os disk
            $vhdUri = $datadisk.Vhd.Uri
            if ($vhdUri) {
                if ($Force -or $PSCmdlet.ShouldProcess($vhdUri, "Remove Storage Blob")) {
                    Write-Verbose "Removing Unmanaged VHD $vhdUri"
                    $result = RemoveStorageBlobByUri -Uri $vhdUri -WhatIf:$WhatIfPreference
                }
            }
        }
    }
    else {
        Write-Verbose "Keeping data disks..."
    }
    #endregion

    #region diagnostic logs
    if (-not $KeepDiagnostics) {
        $storageUri = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri
        if ($storageUri) {
            $uriParts = $storageUri.Split('/')
            $storageAccountName = $uriParts[2].Split('.')[0]

            $storageRg = $(Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq "$storageAccountName" }).ResourceGroupName
            if (-not $storageRg) {
                Write-Error "Error getting ResourceGroupName for $storageUri"
                return
            }

            $null = Set-AzCurrentStorageAccount -ResourceGroupName $storageRg -StorageAccountName $storageAccountName
            $container = Get-AzStorageContainer | Where-Object { $_.Name -like "bootdiagnostics-*-$($vm.VmId)" }
            if ($container) {
                if ($Force -or $PSCmdlet.ShouldProcess("$storageAccountName/$($container.Name)", "Remove-AzStorageContainer")) {
                    Write-Verbose "Removing container: $($container.name) from resourceGroup: $storageRg, storageAccount: $storageAccountName"
                    Remove-AzStorageContainer -Name $($container.name) -Force
                }
            }
        }
    }
    else {
        Write-Verbose "Keeping diagnostic logs... $($vm.DiagnosticsProfile.BootDiagnostics.StorageUri)"
    }
    #endregion

    #region ResourceGroup, if nothing else inside
    if (-not $KeepResourceGroup) {
        Write-Verbose "Checking ResourceGroup $ResourceGroupName"
        $resources = Get-AzResource -ResourceGroupName$ ResourceGroupName -ErrorAction 'Stop'
        if (-not $resources) {
            if ($Force -or $PSCmdlet.ShouldProcess("$ResourceGroupName", "Remove-AzResourceGroup")) {
                Write-Verbose "Removing resource group $ResourceGroupName"
                $result = Remove-AzResourceGroup -Name $ResourceGroupName -ErrorAction Continue
            }
        }
    }
    else {
        Write-Verbose "Keeping resource group... $ResourceGroupName"
    }
    #endregion

}
catch {
    $_.Exception
    Write-Error $_.Exception.Message
    Write-Error $result
    Write-Error "Unable to reomve all components of the VM. Please check to make sure all components were properly removed."
    return
}

