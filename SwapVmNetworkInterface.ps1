<#
.SYNOPSIS
Switch the network interface on a virtual machine

.DESCRIPTION
This script will change the network interface on virutal machine, replacing it
with a different one.

.PARAMETER ResourceGroupName
The resource group name of the virtual machine to be moved.

.PARAMETER VmName
The name of the virutal machine to be moved.

.PARAMETER NicName
The name of network interface to add to the virtual machine.

.PARAMETER NicResourceGroupName
The name of the network interface resource group. By defaut, it will be set to
the same as specified by -ResourceGroupName

.PARAMETER ReplaceNicId
The resource id of the network interface resource to replace. By default, the primary
network interface will be replaced.

.EXAMPLE
SwapVmNetworkInterface.ps1 -ResourceGroupName myRg -VmName myVm -NicName myNic

.NOTES
#>
[CmdletBinding()]

Param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $VmName,

    [Parameter(Mandatory=$false)]
    [string] $NicResourceGroupName = $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $NicName,

    [Parameter(Mandatory=$false)]
    [string] $ReplaceNicId
)

############################################################
# main function
$PrimaryNic = $true

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Login-Az=Account) and set the proper subscription (Select-AzureRmSubscription) context before proceeding." -ErrorAction Stop
        return
    }
} catch {
    Write-Error "Please login (Login-AzAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding." -ErroAction Stop
    return
}

# check parameters
$vm = Get-AzVm -ResourceGroupName $ResourceGroupName -VmName $VmName
if (-not $vm) {
    Write-Error "Unable to find '$ResourceGroupName/$VmName' virtual machine." -ErrorAction Stop
    return
}

# set NIC id to be replaced
if ($ReplaceNicId) {
    $replaceNic = $vm.NetworkProfile.NetworkInterfaces | Where-Object {$_.Id -eq $ReplaceNicId}
    if (-not $replaceNic) {
        Write-Error "Unable to find NetworkInterfaceId $ReplaceNicId attached to $ResourceGroup/$VM" -ErrorAction Stop
        return
    }
    $PrimaryNic = $replaceNic.Primary

} else {
    if ($vm.NetworkProfile.NetworkInterfaces.count -eq 1) {
        $replaceNic = $vm.NetworkProfile.NetworkInterfaces[0]
    } else {
        $replaceNic = $vm.NetworkProfile.NetworkInterfaces | Where-Object {$_.Primary}
        if (-not $replaceNic) {
            Write-Error "Unable to find Primary Network Interface attached to $ResourceGroup/$VM. Please specify Network Interface using -ReplaceNicId." -ErrorAction Stop
            return
        }
    }
    $ReplaceNicId = $replaceNic.Id
}

$nic = Get-AzNetworkInterface -ResourceGroupName $NicResourceGroupName -Name $NicName
if (-not $nic) {
    Write-Error "Unable to find Network Interface - $ResourceGroupName/$NicName" -ErrorAction Stop
    return
}

$null = Remove-AzVMNetworkInterface -VM $vm -NetworkInterfaceIDs $ReplaceNicId -ErrorAction Stop

if ($PrimaryNic) {
    $null = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id -Primary -ErrorAction Stop
} else {
    $null = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id -ErrorAction Stop
}

$result = $vm | Update-AzVM -ErrorAction Stop
if ($result.IsSuccessStatusCode) {
    Write-Verbose "$nicName replaced successfully."
}