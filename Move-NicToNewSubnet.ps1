[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $NicName,

    [parameter(Mandatory=$True)]
    [string] $VnetName,

    [parameter(Mandatory=$True)]
    [string] $SubnetName
)

Set-StrictMode -Version 3

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        return
    }

}
catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    return
}

$nic = Get-AzNetworkInterface | Where-Object {$_.Name -eq $NicName }
if (-not $nic) {
    Write-Error "NetworkInterface '$nicName' not found."
    return
}

$vnet = Get-AzVirtualNetwork | Where-Object {$_.Name -eq $VnetName}
if (-not $vnet) {
    Write-Error "VirtualNetwork '$VnetName' not found."
    return
}

$subnet = $vnet.Subnets | Where-Object {$_.Name -eq $SubnetName}
if (-not $subnet) {
    Write-Error "Subnet '$SubnetName' Subnet not found."
    return
}

$nic.IpConfigurations[0].Subnet.Id = $subnet.Id
Set-AzNetworkInterface -NetworkInterface $nic

