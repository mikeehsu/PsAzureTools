<#
.SYNOPSIS
Move a Virtual Machine with Managed Disks attached to a new Availability Set

.DESCRIPTION
This script will move a Virtual Machine with managed disks attached to a
new availability set. The availability set must already exist before executing
this command.

.PARAMETER ResourceGroupName
The resource group name of the virtual machine to be moved.

.PARAMETER VmName
The name of the virutal machine to be moved.

.PARAMETER AvailabilitySetName
The name of the availability set to move the virtual machine to.

.PARAMETER RemoveAvailabilitySet
Set this switch to remove the VM from an availability set

.PARAMETER VmSize
Provide a new VmSize to resize the VM

.EXAMPLE
Move-VM.ps1 -ResourceGroupName myRg -VmName myVm -AvailabilitySetName myAvSet

.NOTES
Because a new VM is created, you should check the diagnostic storage account assigned to the new VM to ensure the logs are written to the proper account
#>

Param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $VmName,

    [Parameter(ParameterSetName='AvSetName', Mandatory)]
    [Parameter(ParameterSetName='RemoveAvSet')]
    [string] $AvailabilitySetName,

    [Parameter(ParameterSetName='AvSetName')]
    [Parameter(ParameterSetName='RemoveAvSet', Mandatory)]
    [switch] $RemoveAvailabilitySet,

    [Parameter(ParameterSetName='AvSetName')]
    [Parameter(ParameterSetName='RemoveAvSet')]
    [Parameter(ParameterSetName='VmSize', Mandatory)]
    [string] $VmSize
)

############################################################

Set-StrictMode -Version 3

#region -- Confirm user is logged into subscription
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    exit
}
#endregion

$ErrorActionPreference = "Stop"
$actionsTaken = @()

#region -- verify parameters
Write-Progress -Activity "Moving VM..." -Status "checking information VM $($VmName)"
$sourceVm = Get-AzVM -ResourceGroupName $ResourceGroupName -VmName $VmName
if (-not $sourceVm)
{
    Write-Error "Unable to find '$ResourceGroupName/$VmName' virtual machine"
    return
}

if ($AvailabilitySetName -and $RemoveAvailabilitySet) {
    Write-Error "invalid parameters -AvailabilitySet and -RemoveAvailabilitySet can not be used together."
    return
}


if ($AvailabilitySetName) {
    Write-Progress -Activity "Moving VM..." -Status "checking information VM $($AvailabilitySetName)"
    $availabilitySet = Get-AzAvailabilitySet -ResourceGroupName $ResourceGroupName -AvailabilitySetName $AvailabilitySetName
    if (-not $availabilitySet)
    {
        Write-Error "Unable to find '$ResourceGroupName/$AvailabilitySetName' availability set"
        return
    }
}
#endregion

#region -- update VmSize
if ($VmSize) {
    $size = Get-AzVMSize -Location $sourceVm.Location | Where-Object {$_.Name -eq $VmSize}
    if (-not $size) {
        Write-Error "VmSize $VmSize is not available in $($sourceVm.Location)"
        return
    }

    if ($VmSize -ne $sourceVm.HardwareProfile.VmSize) {
        $actionsTaken = "Resized to $VmSize"
    }
} else {
    $VmSize = $sourceVm.HardwareProfile.VmSize
}
#endregion

#region -- Copy VM settings
$params = @{
    VmName = $sourceVm.Name
    VmSize = $VmSize
    ErrorAction = 'Stop'
}

if ($sourceVm.LicenseType) {
    $params += @{ LicenseType = $sourceVm.LicenseType }
}

if ($sourceVm.Zones) {
    $params += @{ Zone = $sourceVm.Zones}
}

if ($sourceVm.ProximityPlacementGroup) {
    $params += @{ ProximityPlacementGroupId = $sourceVm.ProximityPlacementGroup.Id}
}

if ($sourceVm.Tags) {
    $params += @{ Tags = $sourceVm.Tags}
}

#region -- update AvailabilitySet
$origAvsetName = $null
Write-Progress -Activity "Moving VM..." -Status "configuring destination $($sourceVm.Name)"
if ($sourceVm.AvailabilitySetReference -and $sourceVm.AvailabilitySetReference.Id -match '[^/]*$') {
    $origAvsetName = $matches[0]
}

if ($RemoveAvailabilitySet) {
    if ($sourceVm.AvailabilitySetReference) {
        $actionsTaken += "Removed from Availability Set: $origAvsetName"
    }

} elseif ($AvailabilitySetName) {
    if ($origAvsetName) {
        $actionsTaken += "Moved Availability Set from $origAvsetName to $($availabilitySet.Name)"
    } else {
        $actionsTaken += "Moved to Availability Set: $($availabilitySet.Name)"
    }
    $params += @{ AvailabilitySetId = $availabilitySet.Id }

} else {
    $params += @{ AvailabilitySetId = $sourceVm.AvailabilitySet.Id }
}

$newVm = New-AzVMConfig @params
#endregion

#region -- Attach all the disks
# attach OS disk
$osDiskId = $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id

if ($sourceVm.StorageProfile.OsDisk.OsType -eq 'Windows') {
    Write-Verbose "setting up new VM OS Disk (Windows)"
    $result = Set-AzVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Windows
} else {
    Write-Verbose "setting up new VM OS Disk (Linux)"
    $result = Set-AzVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Linux
}

# attach data disks
Write-Verbose "assigning original Data Disks"
$i = 0
foreach ($oldDataDisk in $sourceVm.StorageProfile.DataDisks) {
    $result = Add-AzVMDataDisk -VM $newVm -ManagedDiskId $oldDataDisk.ManagedDisk.Id -CreateOption Attach -Lun $i
    $i = $i + 1
}
#endregion

#region -- Connect original NICs
Write-Verbose 'assigning original NIC cards'
foreach ($nic in $sourceVm.NetworkProfile.NetworkInterfaces) {
    $result = Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id
}
#endregion

#region -- remove the source VM and create new VM
if ($actionsTaken.Count -eq 0) {
    Write-Host "VM $VmName - no differences to make."
    return
}


Write-Progress -Activity "Moving VM..." -Status "removing source VM $($sourceVm.Name)"
$result = Remove-AzVm -ResourceGroupName $sourceVm.ResourceGroupName -Name $sourceVm.Name -Force -ErrorAction Stop

try {
    Write-Progress -Activity "Moving VM..." -Status "creating new VM $($newVm.Name)"
    $result = New-AzVM -VM $newVm -ResourceGroupName $ResourceGroupName -Location $sourceVm.Location
    Write-Debug $result
} catch {
    throw $_
    return
}
#endregion

Write-Host "VM ($($newVm.Name)) updated"
$actionsTaken | ForEach-Object {Write-Host $('  - ' + $_) }
Write-Host "NOTE: Please verify the diagnostic storage account to ensure the logs are written to the proper location."
