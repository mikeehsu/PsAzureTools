[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $NicName,

    [parameter(Mandatory=$True)]
    [string] $VnetName,

    [parameter(Mandatory=$True)]
    [string] $SubnetName
)

$nic = Get-AzureRmNetworkInterface | Where-Object {$_.Name -eq $NicName }
if (-not $nic) {
    Write-Error "NetworkInterface '$nicName' not found."
    return
}

$vnet = Get-AzureRmVirtualNetwork | Where-Object {$_.Name -eq $VnetName}
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
Set-AzureRmNetworkInterface -NetworkInterface $nic

