##############################
#.SYNOPSIS
# Revert a VM to an existing snapshot
#
#.DESCRIPTION
# While it is not actually possible to replace the OS disk of an existing VM,
# this script will remove the VM and rebuild it from a snapshot with the same
# network interfaces, availability sets and tags.
#
#.PARAMETER ResourceGroupName
# The resource group name of the virtual machine to be rebuilt.
#
#.PARAMETER VmName
# The name of the virutal machine to be rebuilt.
#
#.PARAMETER SnapshotName
# The name of the snapshot to create a disk from.
#
#.EXAMPLE
# .\RebuildVmFromSnapshot.ps1 -ResourceGroupName myResourceGroup -VmName myVm -SnapshotName mySnapshot
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
    [string] $SnapshotName
)


############################################################
# main function

$ErrorActionPreference = "Stop"
$now = Get-Date

Write-Verbose "Getting VM info from $ResourceGroupName/$vmName"
$oldVm = Get-AzureRMVm -ResourceGroupName $ResourceGroupName -name $VmName -ErrorAction SilentlyContinue
if (-not $oldVm) {
    Write-Error "Unable to find $VmName in Resource Group $ResourceGroupName"
    return
}

# create a disk from snapshot
Write-Verbose "Getting snapshot info from $snapshotName"
$snapshot = Get-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName
if (-not $snapshot) {
    Write-Error "Unable to find $snapshotName snapshot in Resource Group $ResourceGroupName"
    return
}

$diskName = $VmName + '_osDisk_' +  $now.ToString("yyyyMMddhhmmss")
Write-Verbose "Creating disk $diskName"
$diskConfig = New-AzureRmDiskConfig -AccountType $disk.AccountType -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy
$newOsDisk = New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $ResourceGroupName -DiskName $diskName

# remove the old Vm
Write-Verbose "Removing original VM $($oldVm.Name)"
Remove-AzureRmVm -ResourceGroupName $oldVm.ResourceGroupName -Name $oldVm.Name -Force

# Create the virtual machine with Managed OS disk
$newVm = New-AzureRmVMConfig -VMName $oldVm.Name -VMSize $oldVm.HardwareProfile.VmSize
if ($oldVm.OSProfile.WindowsConfiguration) {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Windows
} else {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Linux
}

# set other setting
$newVm.AvailabilitySetReference = $oldVm.AvailabilitySetReference
$newVm.Tags = $oldVm.Tags

# attach data disks
$i = 0
foreach ($dataDisk in $oldVm.StorageProfile.DataDisks) {
    Write-Verbose "Creating DataDisk Snapshot for $($dataDisk.Name)"
    $newVm = Add-AzureRmVMDataDisk -VM $newVm -ManagedDiskId $dataDisk.ManagedDisk.Id -CreateOption Attach -Lun $i
    $i = $i + 1
}

# connect NIC
$newVm = Add-AzureRmVMNetworkInterface -VM $newVm -Id $oldVm.NetworkProfile.NetworkInterfaces.Id

# Allocate VM
Write-Verbose "Creating new VM"
$newVm | ConvertTo-Json -Depth 10
New-AzureRmVM -VM $newVm -ResourceGroupName $ResourceGroupName -Location $oldVm.Location

Write-Output "VM $VmName has been rebuilt using $SnapshotName"
Write-Output "Please verfiy the new Virtual Machine and remove the original disks once the machine is confirmed. (Virtual networks and Storage Account associated with the original resource group were not moved as they can be shared by multiple resources. Please review these resources and move as necessary.)"
