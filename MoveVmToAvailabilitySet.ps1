##############################
#.SYNOPSIS
# Move a Virtual Machine with Managed Disks attached to a new Availability Set
#
#.DESCRIPTION
# This script will move a Virtual Machine with managed disks attached to a
# new availability set. The availability set must already exist before executing
# this command.
#
#.PARAMETER ResourceGroupName
# The resource group name of the virtual machine to be moved.
#
#.PARAMETER VmName
# The name of the virutal machine to be moved.
#
#.PARAMETER AvailabilitySetName
# The name of the availability set to move the virtual machine to.
##
#.EXAMPLE
# MoveVmToAvailabilitySet.ps1 -ResourceGroupName myRg -VmName myVm -AvailabilitySetName myAvSet
#
#.NOTES
# Because a new VM is created, you should check:
# diagnostic storage account assigned to the new VM to ensure the logs are written to the proper account
####################################

Param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $VmName,

    [Parameter(Mandatory=$true)]
    [string] $AvailabilitySetName
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

$availabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -AvailabilitySetName $AvailabilitySetName
if (-not $availabilitySet)
{
    Write-Error "Unable to find '$ResourceGroupName/$AvailabilitySetName' availability set"
    return
}

# remove the old Vm
Write-Verbose "removing original VM $($oldVm.Name)"
$null = Remove-AzureRmVm -ResourceGroupName $oldVm.ResourceGroupName -Name $oldVm.Name -Force -ErrorAction Stop

# Create the virtual machine with Managed OS disk
$osDiskId = $oldVm.StorageProfile.OsDisk.ManagedDisk.Id

#create the new VM with the availabilityset
$newVm = New-AzureRmVMConfig -VMName $oldVm.Name -VMSize $oldVm.HardwareProfile.VmSize -AvailabilitySetId $availabilitySet.Id -ErrorAction Stop

if ($oldVm.OSProfile.WindowsConfiguration) {
    Write-Verbose "setting up new VM OS Disk (Windows)"
    $result = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Windows
} else {
    Write-Verbose "setting up new VM OS Disk (Linux)"
    $result = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Linux
}

# attach data disks
Write-Verbose "assigning original Data Disks"
$i = 0
foreach ($oldDataDisk in $oldVm.StorageProfile.DataDisks) {
    $result = Add-AzureRmVMDataDisk -VM $newVm -ManagedDiskId $oldDataDisk.ManagedDisk.Id -CreateOption Attach -Lun $i
    $i = $i + 1
}

# connect original NICs
Write-Verbose 'assigning original NIC cards'
foreach ($nic in $oldVm.NetworkProfile.NetworkInterfaces) {
    $result = Add-AzureRmVMNetworkInterface -VM $newVM -Id $nic.Id
}

# Allocate VM
Write-Verbose "creating new VM"
$null = New-AzureRmVM -VM $newVm -ResourceGroupName $ResourceGroupName -Location $oldVm.Location

Write-Output "VM $VmName has been moved to the new availability set $ResourceGroupName/$AvailabilitySetName"
Write-Output "- Please verify the diagnostic storage account assigned to the new VM to ensure the logs are written to the proper account."
