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

.PARAMETER Zone
The availability zone to move the VM to.

.PARAMETER VmSize
Provide a new VmSize to resize the VM

.PARAMETER Spot
Move VM to a Spot Instance

.EXAMPLE
Move-VM.ps1 -ResourceGroupName myRg -VmName myVm -AvailabilitySetName myAvSet

.NOTES
Because a new VM is created, you should check the diagnostic storage account assigned to the new VM to ensure the logs are written to the proper account
#>

Param (
    [Parameter(ParameterSetName='Vm', Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(ParameterSetName='Vm', Mandatory)]
    [Alias('Name')]
    [string] $VmName,

    [Parameter(ParameterSetName='Vm')]
    [Parameter(ParameterSetName='AvSetName', Mandatory)]
    [string] $AvailabilitySetName,

    [Parameter(ParameterSetName='Vm')]
    [Parameter(ParameterSetName='RemoveAvSet')]
    [switch] $RemoveAvailabilitySet,

    [string] $VmSize,

    [switch] $Spot,

    [ValidateSet($null,1,2,3)]
    [int] $Zone = $null
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

#region -- update VmSize & zone
if (-not $VmSize) {
    $VmSize = $sourceVm.HardwareProfile.VmSize
}

if (-not $Zone) {
    $Zone = $sourceVm.Zones
}

if ($VmSize -ne $sourceVm.HardwareProfile.VmSize -or $Zone -ne $sourceVm.Zones) {
    Write-Progress -Activity "Moving VM..." -Status "checking for $VmSize in destination"

    # check to make sure Vm SKU is available in region
    $size = Get-AzComputeResourceSku | Where-Object {$_.ResourceType -eq 'VirtualMachines' -and $_.Name -eq $VmSize -and $_.Locations -contains $sourceVm.Location}
    if (-not $size) {
        Write-Error "VmSize $VmSize is not available in $($sourceVm.Location)"
        return
    }

    # check to make sure Vm SKU is available in a zone
    if ($Zone) {
        $size = $size | Where-Object {$_.LocationInfo.Zones -contains $Zone}
        if (-not $size) {
            Write-Error "VmSize $VmSize is not available in zone $Zone"
            return
        }
    }

    # determine actions taken
    if ($VmSize -ne $sourceVm.HardwareProfile.VmSize) {
        $actionsTaken += "Resized to $VmSize"
    }

    if ($Zone -ne $sourceVm.Zones) {
        $actionsTaken += "Moved to Zone $Zone"
    }
}
#endregion

#region -- Copy VM settings
Write-Progress -Activity "Moving VM..." -Status "configuring destination $($sourceVm.Name)"

$params = @{
    VmName = $sourceVm.Name
    VmSize = $VmSize
    ErrorAction = 'Stop'
}

if ($sourceVm.LicenseType) {
    $params += @{ LicenseType = $sourceVm.LicenseType }
}

if ($sourceVm.ProximityPlacementGroup) {
    $params += @{ ProximityPlacementGroupId = $sourceVm.ProximityPlacementGroup.Id}
}

if ($sourceVm.Tags) {
    $params += @{ Tags = $sourceVm.Tags}
}


# set the zone
if ($Zone) {
    $params += @{Zone = $Zone}
}

# update AvailabilitySet
$origAvsetName = $null
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

} elseif ($sourceVm.AvailabilitySetReference) {
    $params += @{ AvailabilitySetId = $sourceVm.AvailabilitySetReference.Id }
}

if ($Spot) {
    $params += @{ Priority = 'Spot' }
}
#endregion

# create the VM config
$newVm = New-AzVMConfig @params

#region -- Connect original NICs
Write-Progress -Activity "Moving VM..." -Status "checking network configurations"
foreach ($nic in $sourceVm.NetworkProfile.NetworkInterfaces) {
    if ($Zone) {
        $card = Get-AzNetworkInterface -ResourceId $nic.Id
        $publicIpResourceIds = $card.IpConfigurations.PublicIpAddress.Id
        foreach ($publicIpResourceId in $publicIpResourceIds) {
            $publicIp = Get-AzPublicIpAddress -Name (Split-Path $publicIpResourceId -Leaf)
            if ((-not $publicIp.Zones) -or ($publicIp.Zones -ne $Zone)) {
                Write-Error "Cannot move VM with public IP address ($($publicIp.Name)) in different zone from target zone ($Zone)."
                return
            }
        }
    }
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

#region -- if zones, snapdisks & create in zone
$diskSuffix = $null
if ($Zone -ne $sourceVm.Zones) {
    Write-Progress -Activity "Moving VM..." -Status "removing source VM $($sourceVm.Name)"

    $diskSuffix = '_copy'

    $disks = @()
    $disks += [PSCustomObject]@{
        Id = $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id
        StorageType = $sourceVm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
    }

    foreach ($dataDisk in $sourceVm.StorageProfile.DataDisks) {
        $disks += [PSCustomObject]@{
            Id = $dataDisk.ManagedDisk.Id
            StorageType = $dataDisk.ManagedDisk.StorageAccountType
        }
    }

    $disks | ForEach-Object {
        if ($_.Id -match '[^\/]+?$') {
            $diskName = $matches[0]
            $snapshotName = $diskName + '_snap'
            $diskCopyName = $diskname + $diskSuffix
        } else {
            throw "Unable to find disk name in Id:$($_.Id)"
        }

        Write-Progress -Activity "Moving VM..." -Status "Creating snapshot $snapshotName"
        $snapshotConfig =  New-AzSnapshotConfig -SourceUri $_.Id -Location $sourceVm.Location -CreateOption copy
        $snapshot = New-AzSnapshot -ResourceGroupName $sourceVm.ResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshotConfig
        Write-Verbose "snapshot $snapshotName created"

        Write-Progress -Activity "Moving VM..." -Status "Creating copy of disk $diskCopyName"
        $diskConfig = New-AzDiskConfig -SkuName $_.storageType -Location $sourceVm.Location -Zone $zone -CreateOption Copy -SourceResourceId $snapshot.Id
        $disk = New-AzDisk -ResourceGroupName $sourceVm.ResourceGroupName -DiskName $diskCopyName -Disk $diskConfig
        Write-Verbose "disk $diskCopyName created"
    }
}
#endregion

#region -- Attach all the disks
# attach OS disk
$osDiskId = $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id + $diskSuffix
if ($sourceVm.StorageProfile.OsDisk.OsType -eq 'Windows') {
    Write-Verbose "setting up OS disk (Windows)"
    $result = Set-AzVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Windows -Caching $sourceVm.StorageProfile.OsDisk.Caching
} else {
    Write-Verbose "setting up OS disk (Linux)"
    $result = Set-AzVMOSDisk -VM $newVm -ManagedDiskId $osDiskId -CreateOption Attach -Linux -Caching $sourceVm.StorageProfile.OsDisk.Caching
}

# attach data disks
Write-Verbose "assigning data disks"
$i = 0
foreach ($oldDataDisk in $sourceVm.StorageProfile.DataDisks) {
    $diskId = $oldDataDisk.ManagedDisk.Id + $diskSuffix
    $result = Add-AzVMDataDisk -VM $newVm -ManagedDiskId $diskId -CreateOption Attach -Lun $i -Caching $oldDataDisk.Caching
    $i = $i + 1
}
#endregion

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
Write-Host "      Once successful VM move has been confirmed you can remove orignal disk and snapshots, if copies were make due to changes in zone, etc"
