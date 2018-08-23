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

    Write-Verbose "Creating snapshot for disk $($ResourceGroupName)/$($DiskName)"
    $disk = Get-AzureRmDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName
    $snapshotName = $disk.Name + "_snapshot"

    if ($disk.length -ne 1) {
        Write-Error "Disk not found for $($ResourceGroupName)/$($DiskName)" -ErrorAction Stop
        return
    }

    $snapshot = New-AzureRmSnapshotConfig -SourceUri $disk.Id -CreateOption Copy -Location $disk.Location
    $snapshot = New-AzureRmSnapshot -Snapshot $snapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName

    $diskConfig = New-AzureRmDiskConfig -AccountType $disk.Sku.Name -Location $snapshot.Location -SourceResourceId $snapshot.Id -CreateOption Copy
    $newDisk = New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $newResourceGroupName -DiskName $disk.Name

    $null = Remove-AzureRmSnapshot -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName -Force

    return $newDisk
}

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
    Write-Error "Unable to find VM named $VmName in Resource Group $oldResourceGroupName"
    return
}

# create new resource group
Write-Verbose "Creating ResourceGroup $newResourceGroupName"
$null = New-AzureRmResourceGroup -Name $newResourceGroupName -Location $oldResourceGroup.Location -Force

# create a OSDisk snapshot in old ResourgeGroup
$newOsDisk = MoveManagedDiskResourceGroup -ResourceGroupName $oldResourceGroupName `
    -DiskName $oldVm.StorageProfile.OSDisk.Name `
    -NewResourceGroupName $NewResourceGroupName `
    -ErrorAction Stop
$newOsDisk

# create DataDisk snapshots in old ResourceGroup
$newDataDisks = @()
foreach ($dataDisk in $oldVm.StorageProfile.DataDisks) {
    Write-Verbose "Creating DataDisk Snapshot for $($dataDisk.Name)"
    $newDataDisks += MoveManagedDiskResourceGroup -ResourceGroupName $oldResourceGroupName `
        -DiskName $dataDisk.Name `
        -NewResourceGroupName $NewResourceGroupName `
        -ErrorAction Stop
    $newDataDisks
}

# remove the old Vm
Write-Verbose "Removing original VM $($oldVm.Name)"
Remove-AzureRmVm -ResourceGroupName $oldVm.ResourceGroupName -Name $oldVm.Name -Force -ErrorAction Stop

# Create the virtual machine with Managed OS disk
Write-Verbose "Creating new VM"

Write-Verbose "Setting OS Disk"
$newVm = New-AzureRmVMConfig -VMName $oldVm.Name -VMSize $oldVm.HardwareProfile.VmSize -ErrorAction Stop
if ($oldVm.OSProfile.WindowsConfiguration) {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Windows
} else {
    $newVm = Set-AzureRmVMOSDisk -VM $newVm -ManagedDiskId $newOsDisk.Id -CreateOption Attach -Linux
}

# attach data disks
Write-Verbose "Adding Data Disks"
$i = 0
foreach ($newDataDisk in $newDataDisks) {
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
Write-Output "- Please verify the diagnostic storage account assigned to the new VM to ensure the logs are written to the proper account."
Write-Output "- Please verfiy the new Virtual Machine and remove the original disks once the machine is confirmed."
Write-Output "- Review any Virtual networks and Storage Account associated with the original resource group. These resources were not moved as they can be shared by multiple resources. You may manually move these resourcesas necessary."
