##############################
#.SYNOPSIS
# Rebuild existing VM using a snapshot, existing disk or availability set.
#
#.DESCRIPTION
# Rebuild an existing Virtual Machine. This script can replace the OS disk
# with an existing disk, build a disk from a snapshot, or just recreate the
# virtual machine in a new availability set. This script will keep the same
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
#.PARAMETER DiskName
# The name of a disk to attach as the OS disk instead of creating a snapshot.
# This currently only supports Managed Disks.
#
#.PARAMETER AvailabilitySet
# The name of the snapshot to create a disk from.

#
#.EXAMPLE
# .\RebuildVm.ps1 -ResourceGroupName myResourceGroup -VmName myVm -SnapshotName mySnapshot
#
#.NOTES
#
####################################

Param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $VmName,

    [Parameter(Mandatory=$false)]
    [string] $SnapshotName,

    [Parameter(Mandatory=$false)]
    [string] $DiskName,

    [Parameter(Mandatory=$false)]
    [string] $AvailabilitySetName
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

# check to make sure one of the necessary parameters are provided
if (-not ($SnapshotName -or $DiskName -or $AvailabilitySetName)) {
    Write-Error "Nothing to do. Please provide one of -SnapshotName -DiskName or -AvailabilitySetName"
    return
}

# default new VM values to existing old VM
#
# set default disk
$oldDiskResourceGroupName = $oldVm.StorageProfile.osDisk.ManagedDisk.Id.Split("/")[4]
$oldDiskName              = $oldVm.StorageProfile.osDisk.ManagedDisk.Id.Split("/")[8]

$newOsDisk = Get-AzureRmDisk -ResourceGroupName $oldDiskResourceGroupName -DiskName $oldDiskName

# set default availability set
$availabilitySetReference = $oldVm.AvailabilitySetReference

if ($SnapshotName) {
    # check to make sure -Diskname isn't provided
    if ($DiskName) {
        Write-Error "-SnapshotName and -DiskName are exclusive options. Please use only one or the other."
        return
    }

    # create a disk from snapshot
    Write-Verbose "Getting snapshot info from $snapshotName"
    $snapshot = Get-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName
    if (-not $snapshot) {
        Write-Error "Unable to find $snapshotName snapshot in Resource Group $ResourceGroupName"
        return
    }

    $vmDiskName = $VmName + '_osDisk_' +  $now.ToString("yyyyMMddhhmmss")
    Write-Verbose "Creating disk $diskName"
    $diskConfig = New-AzureRmDiskConfig -AccountType $disk.AccountType -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy
    $newOsDisk = New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $ResourceGroupName -DiskName $vmDiskName
}

if ($DiskName) {
    # set OS disk to diskname provided
    $newOsDisk = Get-AzureRmDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
}


if ($AvailabilitySetName) {
    $availabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $AvailabilitySetName
    if (-not $availabilitySet) {
        Write-Error "Unable to find $AvailabilitySetName availability set in Resource Group $ResourceGroupName"
        return
    }

    $availabilitySetReference = $availabilitySet.Id
}


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
$newVm.AvailabilitySetReference = $availabilitySetReference
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

# create the new VM
Write-Verbose "Creating new VM"
$newVm | ConvertTo-Json -Depth 10
New-AzureRmVM -VM $newVm -ResourceGroupName $ResourceGroupName -Location $oldVm.Location

Write-Output "VM $VmName has been rebuilt"
Write-Output "Please verfiy the new Virtual Machine and remove the original disks once the machine is confirmed. (Virtual networks and Storage Account associated with the original resource group were not moved as they can be shared by multiple resources. Please review these resources and move as necessary.)"
