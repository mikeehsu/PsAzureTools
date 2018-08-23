##############################
#.SYNOPSIS
# Move a Virtual Machine with Managed Disks attached to a new Resource Group
#
#.DESCRIPTION
# This script will move a Virtual Machine with managed disks attached to a
# new resource group. If the resource group does not exist, it will be create.
# This script will make a snapshot of the managed disks and create a new disks
# in the new resource group. Additionally, it will move any network interfaces,
# network security group, or public ip addresses that may be associated with
# the virtual machine and in the same resource group.
#
#.PARAMETER ResourceGroupName
# The resource group name of the virtual machine to be moved.
#
#.PARAMETER VmName
# The name of the virutal machine to be moved.
#
#.PARAMETER VnetName
# The name of virtual network to move machine to.
#
#.PARAMETER SubnetName
# The name of the subnet to move the virtual machine to.
#
#.EXAMPLE
# MoveVmToNewVnet.ps1 -ResourceGroupName myRg -VmName myVm -VnetName newVnetName -SubnetName newSubnetName
#
#.NOTES
# Because the new Vnet is likely to have a different IP range, the items need
# to be verified after the move:
# - Diagnostic Storage Accounts. A new diagnostic storage account may have been assigned.
# - Static IP addresses. After the move, the NIC card will be reset to Dynamic
# - Network Security Groups. The existing NSG will not be reattached to the new NIC
# - Public IP Addresses. Any existing public IP addresses will not be associated to the NIC
####################################

Param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $VmName,

    [Parameter(Mandatory=$true)]
    [string] $VnetName,

    [Parameter(Mandatory=$true)]
    [string] $SubnetName
)



############################################################
# main function

# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
    exit
}

$ErrorActionPreference = "Stop"

# check parameters
$oldVm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -VmName $VmName
if (-not $oldVm)
{
    Write-Error "Unable to find '$ResourceGroupName/$VmName' virtual machine"
    return
}

$vnet = Get-AzureRmVirtualNetwork | Where-Object {$_.Name -eq $VnetName}
if (-not $vnet) {
    Write-Error "VirtualNetwork '$VnetName' not found."
    return
}

$subnet = $vnet.Subnets | Where-Object {$_.Name -eq $SubnetName}
if (-not $subnet) {
    Write-Error "Subnet '$SubnetName' Subnet not found."
    return
}


# remove the old Vm
Write-Verbose "removing original VM $($oldVm.Name)"
$null = Remove-AzureRmVm -ResourceGroupName $oldVm.ResourceGroupName -Name $oldVm.Name -Force -ErrorAction Stop

# Create the virtual machine with Managed OS disk
Write-Verbose "setting OS Disk"
$osDiskId = $oldVm.StorageProfile.OsDisk.ManagedDisk.Id

$newVm = New-AzureRmVMConfig -VMName $oldVm.Name -VMSize $oldVm.HardwareProfile.VmSize -ErrorAction Stop
if ($oldVm.OSProfile.WindowsConfiguration) {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Windows
} else {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Linux
}

# attach data disks
Write-Verbose "Adding Data Disks"
$i = 0
foreach ($oldDataDisk in $oldVm.StorageProfile.DataDisks) {
    $newVm = Add-AzureRmVMDataDisk -VM $newVm -ManagedDiskId $oldDataDisk.ManagedDisk.Id -CreateOption Attach -Lun $i
    $i = $i + 1
}

# connect NIC
Write-Verbose 'configuring new NIC'
$nicResourceGroupName = $oldVm.NetworkProfile.NetworkInterfaces.Id.split('/')[4]
$nicName = $oldVm.NetworkProfile.NetworkInterfaces.Id.split('/')[8]
$oldNic = Get-AzureRmNetworkInterface -ResourceGroupName $nicResourceGroupName -Name $nicName

$oldIpConfig = $oldNic.IpConfigurations[0]
$newIpConfig = New-AzureRmNetworkInterfaceIpConfig `
    -Name $oldIpConfig.Name `
    -Subnet $subnet
#    -PrivateIpAddress $oldIpConfig.PrivateIpAddress

Write-Verbose 'removing old NIC'
$null = Remove-AzureRmNetworkInterface -ResourceGroupName $nicResourceGroupName -Name $nicName  -Force -ErrorAction Stop

$newNic = New-AzureRmNetworkInterface -Name $nicName `
    -ResourceGroupName $nicResourceGroupName `
    -Location $oldVm.Location `
    -IpConfiguration $newIpConfig

$newVm = Add-AzureRmVMNetworkInterface -VM $newVm -Id $newNic.Id

# Allocate VM
Write-Verbose "creating new VM"
$null = New-AzureRmVM -VM $newVm -ResourceGroupName $ResourceGroupName -Location $oldVm.Location

Write-Output "VM $VmName has been moved to the new subnet $VnetName/$SubnetName"
Write-Output "- Please verify the diagnostic storage account assigned to the new VM to ensure the logs are written to the proper account."
Write-Output "- If you were using static IP addresses, you will need to assign these. The IP assignment was set to Dynamic as part of the move"
Write-Output "- Please verify any Network Security Groups attached to the NIC. These were not reattached to the new NIC."
Write-Output "- Please verify and reattach any Public IP addresses. These were not reattached to the new NIC. "
