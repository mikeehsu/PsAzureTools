<#
.SYNOPSIS
Synchronize Virtual Machine Network Interfaces between two Resource Groups, making sure the network interfaces used by the destination VM matches that of the ones used by the source VM.

.DESCRIPTION
This script is used to attach network interfaces in the -DestinationResourceGroupName with the same virtual machine names found in -SourceResourceGroupName

.PARAMETER SourceResourceGroupName
The resource group name of the resource group to use as the template.

.PARAMETER DestinationResourceGroupName
The resource group name of the resource group to update.

.EXAMPLE
.\SyncVmNetworkInterfaces.ps1 -SourceResourceGroupName myproject-rg -DestinationResourceGroupName myproject-dr-rg

.NOTES
#>
[CmdletBinding()]

Param (
    [Parameter(Mandatory=$true)]
    [string] $SourceResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $DestinationResourceGroupName
)

############################################################
# main function

$sourceVms = Get-AzVm -ResourceGroupName $SourceResourceGroupName
if (-not $sourceVms) {
    Write-Error "Unable to find Virtual Machiens in Source Resource Group $sourceResourceGroupName" -ErrorAction Stop
    return
}

foreach ($sourceVm in $sourceVms) {
    Write-Verbose "Working on Virtual Machine $($sourceVm.Name)"

    $destVm = Get-AzVm -ResourceGroupName $DestinationResourceGroupName -Name $sourceVm.name -ErrorAction SilentlyContinue
    if (-not $destVm) {
        Write-Warning "Virtual Machine ($($sourceVm.Name)) was not found in $DestinationResourceGroupName"
        continue
    }

    # if ($destVm.StatusCode -ne "Stopped") {
    #     Write-Warning "Virtuapl Machine ($($sourceVm.Name)) needs to be stopped in order to update network interface"
    #     continue
    # }
    $removedNic = @()
    foreach ($nic in $($destVm.NetworkProfile.NetworkInterfaces)) {
        $removedNic = Remove-AzVMNetworkInterface -VM $destVm -NetworkInterfaceIDs $nic.Id -ErrorAction Stop
        Write-Verbose "NIC $($removedNic.Name) removed"
    }

    foreach ($sourceNic in $sourceVm.NetworkProfile.NetworkInterfaces) {
        $nicName = ($sourceNic.Id -split '/')[-1]
        $nic = Get-AzNetworkInterface -ResourceGroupName $DestinationResourceGroupName -Name $nicName
        if (-not $nic) {
            Write-Warning "Network Interface ($DestinationResourceGroupName/$nicName) was not found"
            continue
        }

        if ($sourceNic.Primary) {
            $null = Add-AzVMNetworkInterface -VM $destVm -Id $nic.Id -Primary -ErrorAction Stop
        } else {
            $null = Add-AzVMNetworkInterface -VM $destVm -Id $nic.Id -ErrorAction Stop
        }

        Write-Verbose "Updating Virtual Machine $($destVm.Name)"
        $result = $destVm | Update-AzVM -ErrorAction Stop
        if ($result.IsSuccessStatusCode) {
            Write-Verbose "$nicName replaced successfully."
        }
    }

}

