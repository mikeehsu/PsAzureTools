<#
.SYNOPSIS
Convert disks on virtual machine to a specific disk type.

.DESCRIPTION
Convert all disks attached to a specific virtual machine to a specific disk type.

.PARAMETER ResourceGroupName
Specifies the name of the resource group that contains the virtual machine.

.PARAMETER VmName
Specifies the name of the virtual machine.

.PARAMETER Sku
Specifies the storage SKU for the virtual machine disks.

.PARAMETER StartVm
Indicates whether to start the virtual machine after the disks are resized.

.PARAMETER LeaveVmStopped
Indicates whether to leave the virtual machine stopped/deallocated after the disks are resized.

.EXAMPLE
Convert-VmDiskType.ps1 -ResourceGroupName 'MyGroup' -Name 'MyVm' -Sku Standard_LRS

.EXAMPLE
Get-AzVm -ResourceGroupNmae 'dev-group' | Convert-VmDiskType.ps1 -Sku Standard_LRS -LeaveVmStopped

.EXAMPLE
Get-AzVm -ResourceGroupNmae 'dev-group' | Convert-VmDiskType.ps1 -Sku Premium_LRS -StartVm
#>

[CmdletBinding()]
param (
	[Parameter(Mandatory, ValueFromPipelineByPropertyName)]
	[string] $ResourceGroupName,

	[Parameter(Mandatory, ValueFromPipelineByPropertyName)]
	[Alias('Name')]
	[string] $VmName,

	[Parameter(Mandatory)]
	[ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'Premium_LRS', 'UltraSSD_LRS')]
	[string] $Sku,

	[Parameter()]
	[switch] $StartVm,

	[Parameter()]
	[switch] $LeaveVmStopped
)

BEGIN {

}

PROCESS {
	$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
	if (-not $vm) {
		Write-Error "VM $VmName not found in resource group $ResourceGroupName"
		return
	}

	# get VM Status
	$vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop

	# get all disks attached to VM
	$disks = Get-AzDisk -ResourceGroupName $ResourceGroupName | Where-Object { $_.ManagedBy -eq $vm.Id -and $_.Sku.Name -ne $Sku }
	if (-not $disks) {
		Write-Host "No disks to convert found for VM $VmName. All disks already $Sku."
		return
	}

	# Stop and deallocate the VM before changing the disks
	if ($vmStatus.Statuses.Code -notcontains 'PowerState/deallocated') {
		Write-Verbose "Stopping VM $($vm.name)..."
		$result = $vm | Stop-AzVM -Force
		if (-not $result) {
			Write-Error "VM $($vm.Name) must be stopped. Operation aborted."
			return
		}
	}

	foreach ($disk in $disks) {
		Write-Verbose "Converting disk $($disk.Name)..."
		$disk.Sku = [Microsoft.Azure.Management.Compute.Models.DiskSku]::new($Sku)
		$result = $disk | Update-AzDisk
	}

	# finished if LeaveVmStopped is set
	if (-not $LeaveVmStopped) {
		# Start the VM if it was running already or StartVM was set
		if ($vmStatus.Statuses.Code -contains 'PowerState/running' -or $StartVm) {
			Write-Verbose "Starting VM $($vm.name)..."
			$result = Start-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName
		}
	}
}

END {
	Write-Verbose 'Done.'
}
