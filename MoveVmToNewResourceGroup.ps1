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
#.PARAMETER DestinationResourceGroup
# The name of the resource group to move the virtual machine to.
#
#.EXAMPLE
# MoveVmToNewResourceGroup.ps1 -ResourceGroupName oldRg -VmName myVm -DestinationResourceGroup newRg
#
#.NOTES
#
####################################

Param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $VmName,

    [Parameter(Mandatory=$true)]
    [string] $DestinationResourceGroupName
)


############################################################
function MoveManagedDiskResourceGroup
{
    param (
        [parameter(Mandatory=$true)]
        [string] $ResourceGroupName,

        [parameter(Mandatory=$true)]
        [string] $DiskName,

        [parameter(Mandatory=$true)]
        [string] $NewResourceGroupName
    )

    $disk = Get-AzureRmDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
    $snapshotName = $disk.Name + "_snapshot"

    $snapshot = New-AzureRmSnapshotConfig -SourceUri $disk.Id -CreateOption Copy -Location $disk.Location
    $snapshot = New-AzureRmSnapshot -Snapshot $snapshot -ResourceGroupName $oldResourceGroupName -SnapshotName $snapshotName

    $diskConfig = New-AzureRmDiskConfig -AccountType $disk.AccountType -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy
    $newDisk = New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $newResourceGroupName -DiskName $disk.Name

    $status = Remove-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Force

    return $newDisk
}

############################################################
# main function

$oldResourceGroupName = $ResourceGroupName
$newResourceGroupName = $DestinationResourceGroupName

$ErrorActionPreference = "Stop"

# check parameters
if ($oldResourceGroupName -eq $newResourceGroupName)
{
    Write-Error "Source resource group $oldResourceGroupName and Destination resource group $newResourceGroupName are the same"
    return
}

# get old VM info
Write-Verbose "Getting info Resource Group $oldResourceGroupName"
$oldResourceGroup = Get-AzureRmResourceGroup -Name $oldResourceGroupName -ErrorAction SilentlyContinue
if (-not $oldResourceGroup)
{
    Write-Error "Unable to find resource group $oldResourceGroupName"
    return
}

Write-Verbose "Getting info VmName $vmName"
$oldVm = Get-AzureRMVm -ResourceGroupName $oldResourceGroupName -name $VmName -ErrorAction SilentlyContinue
if (-not $oldVm)
{
    Write-Error "Unable to find $VmName in Resource Group $oldResourceGroupName"
    return
}

# create new resource group
Write-Verbose "Creating ResourceGroup $newResourceGroupName"
$newResourceGroup = New-AzureRmResourceGroup -Name $newResourceGroupName -Location $oldResourceGroup.Location -Force

# create a OSDisk snapshot in old ResourgeGroup
Write-Verbose "Creating OSDisk Snapshot for $($oldVm.StorageProfile.OSDisk.Name)"
$newOsDisk = MoveManagedDiskResourceGroup -ResourceGroupName $oldResourceGroupName `
    -DiskName $oldVm.StorageProfile.OSDisk.Name `
    -NewResourceGroupName $NewResourceGroupName
$newOsDisk

# create DataDisk snapshots in old ResourceGroup
$newDataDisks = @()
foreach ($dataDisk in $oldVm.StorageProfile.DataDisks) {
    Write-Verbose "Creating DataDisk Snapshot for $($dataDisk.Name)"
    $newDataDisks += MoveManagedDiskResourceGroup -ResourceGroupName $oldResourceGroupName `
        -DiskName $dataDisk.Name `
        -NewResourceGroupName $NewResourceGroupName
    $newDataDisks
}

# remove the old Vm
Write-Verbose "Removing original VM $($oldVm.Name)"
Remove-AzureRmVm -ResourceGroupName $oldVm.ResourceGroupName -Name $oldVm.Name -Force


# Create the virtual machine with Managed OS disk
Write-Verbose "Creating new VM"

Write-Verbose "Setting OS Disk"
$newVm = New-AzureRmVMConfig -VMName $oldVm.Name -VMSize $oldVm.HardwareProfile.VmSize
if ($oldVm.OSProfile.WindowsConfiguration) {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Windows
} else {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Linux
}

# attach data disks
Write-Verbose "Adding Data Disks"
$i = 0
foreach ($newDataDisk in $newDataDisks) {
    Write-Output "i=$i"
    $newDataDisk
    $newVm = Add-AzureRmVMDataDisk -VM $newVm -ManagedDiskId $newDataDisk.Id -CreateOption Attach -Lun $i
    $i = $i + 1
}

# connect NIC
$newVm = Add-AzureRmVMNetworkInterface -VM $newVm -Id $oldVm.NetworkProfile.NetworkInterfaces.Id

# Allocate VM
New-AzureRmVM -VM $newVm -ResourceGroupName $newResourceGroupName -Location $oldVm.Location

#
# move other attached resources

# check NIC
foreach ($interface in $oldVm.NetworkProfile.NetworkInterfaces) {

    $resource = Get-AzureRmResource -ResourceId $interface.Id

    $nic = Get-AzureRmNetworkInterface -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name

    # check NIC itself
    if ($resource.ResourceGroupName -eq $oldResourceGroupName) {
        Write-Verbose "Moving NetworkInterface $($interface.Id)"
        Move-AzureRmResource -ResourceId $interface.Id `
            -DestinationResourceGroupName $newResourceGroupName `
            -Force
    }

    # check NSG
    if ($nic.NetworkSecurityGroup) {
        $resource = Get-AzureRmResource -ResourceId $nic.NetworkSecurityGroup.Id
        if ($resource.ResourceGroupName -eq $oldResourceGroupName) {
            Write-Verbose "Moving NetworkSecurityGroup $($nic.NetworkSecurityGroup.Id)"
            Move-AzureRmResource -ResourceId $nic.NetworkSecurityGroup.Id `
                -DestinationResourceGroupName $newResourceGroupName `
                -Force
        }
    }

    # check PublicIP
    foreach ($ipConfig in $nic.IpConfigurations) {
        if ($ipConfig.PublicIpAddress) {
            $resource = Get-AzureRmResource -ResourceId $ipConfig.PublicIpAddress.Id
            if ($resource.ResourceGroupName -eq $oldResourceGroupName) {
                Write-Verbose "Moving PublicIp $($ipConfig.PublicIpAddress.Id)"
                Move-AzureRmResource -ResourceId $ipConfig.PublicIpAddress.Id `
                    -DestinationResourceGroupName $newResourceGroupName `
                    -Force
            }
        }
    }
}

Write-Output "VM $VmName has been moved to $DestinationResourceGroupName"
Write-Output "Please verfiy the new Virtual Machine and remove the original disks once the machine is confirmed. (Virtual networks and Storage Account associated with the original resource group were not moved as they can be shared by multiple resources. Please review these resources and move as necessary.)"
