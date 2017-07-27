<#
.SYNOPSIS

Create or update a RouteTable with IP addressed necessary to reach services on the public internet
.DESCRIPTION

This Powershell command takes an XML file with a list of IP addresses to be whitelisted and creates a RouteTable for a specified region. Additionally, it can associate the RouteTable with the necessary subnets.

The list of Azure IP addresses can be found at: https://www.microsoft.com/en-us/download/details.aspx?id=41653

.PARAMETER PublicIpFilename

Name of XML file containing the whitelisted public IP address
.PARAMETER PublicIpRegion

Region from the IP address file to load

.PARAMETER RouteTableName

Name of RouteTable to create/update
.PARAMETER ResourceGroupName

Name of ResourceGroup which the RouteTable is in or should be created in
.PARAMETER Location

Location that RouteTable should be created in, if it does not exist
.PARAMETER VnetName

Name of VirtualNetwork the subnets to associate to the RouteTable are located in
.PARAMETER SubnetName

Name of Subnet or Subnets to associate with the RouteTable. If more than one subnet should be associate, an arrary of Subnetnames may be supplied. For example @('subnet1', 'subnet2')
.PARAMETER ApplyToAllSubnets

Set this switch if you want to apply the RouteTable to all subnets within the given VirtualNetwork supplied in -VnetName
.PARAMETER AdditionalIpFilename

Name of file containing additional IP address to add to the RouteTable
.PARAMETER Limit

Maxiumum number of IP address to read from the file specified by PublicIpFilename
.EXAMPLE

.\CreateWhitelistRouteTable.ps1 -PublicIpFilename .\PublicIPs_20170222.xml -PublicIpRegion 'useast' -ResourceGroupName 'Networks' -RouteTableName 'RouteTest' -Location 'East US' -Limit 80 -AdditionlIpFileName 'whitlistedsites.txt' -VnetName 'MyVnet' -ApplyToAllSubnets
#>
[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $PublicIpFilename,

    [parameter(Mandatory=$True)]
    [string] $PublicIpRegion,

    [parameter(Mandatory=$True)]
    [string] $RouteTableName,

    [parameter(Mandatory=$True)]
    [string] $ResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $Location,

    [parameter(Mandatory=$False)]
    [string] $VnetName,

    [parameter(Mandatory=$False)]
    [array] $SubnetName,

    [parameter(Mandatory=$False)]
    [switch] $ApplyToAllSubnets,

    [parameter(Mandatory=$False)]
    [string] $AdditionalIpFilename,

    [parameter(Mandatory=$False)]
    [int] $Limit = 90
)

# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (! $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login and set the proper subscription context before proceeding."
    exit;
}

# verify parameters
if ($SubnetName) {
    if (-not $VnetName)  {
        Write-Error "VnetName required,when associating RouteTable to Subnets."
        return
    }
}

if ($ApplyToAllSubnets) {
    if (-not $VnetName) {
        Write-Error "VnetName required when specifying -ApplyToAllSubnets."
        return
    }
}

if ($VnetName) {
    if (-not $SubnetName -and -not $ApplyToAllSubnets) {
        Write-Error "Either -SubnetName or -ApplyToAllSubnets needed when using VnetName."
        return
    }
}


# clean up parameters
$Location = $Location.Replace(' ', '').ToLower()


# load XML file with public IPs to whitelist
[xml] $publicIpXml = Get-Content $PublicIpFilename
if (-not $publicIpXml) {
    Write-Error "Unable to open $PublicIpFilename"
    return
}

# create/get routetable
$routeTable = Get-AzureRmRouteTable -Name $RouteTableName -ResourceGroupName $ResourceGroupName -ErrorAction 'SilentlyContinue'
if (! $routeTable) {
    Write-Output "creating new RouteTable $RouteTableName"
    $routeTable = New-AzureRmRouteTable `
        -Name $RouteTableName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -ErrorAction 'Stop'
} else {
    # clear out existing routes
    Write-Output "clearing existing routes from Route Table $RouteTableName"

    # make a copy of the routename, since routeTable will be updated
    $routeNames = $routeTable.Routes | Select-Object Name

    foreach ($routeName in $routeNames.Name) {
        $routeTable = $routeTable | Remove-AzureRmRouteConfig -Name $routeName
    }
}

# isolate IPs for region
$publicIpRanges = $publicIpXml.AzurePublicIpAddresses.Region | Where-Object {$_.Name -eq $PublicIpRegion}

# check limit
if ($publicIpRanges.IpRange.count -gt $Limit) {
    Write-Warning "Only first $Limit of $($publicIpRanges.IpRange.count) in region will be loaded. Limit set to $Limit. Use -Limit to increase limit."
} else {
    Write-Output "loading $($publicIpRanges.IpRange.count) IP Addresses into $RouteTable"
}

# create routes
$i = 0
foreach ($ipRange in $publicIpRanges.IpRange) {
    $i++

    # check to see if route table limit reached
    if ($i -gt $Limit) {
        $i--
        Write-Verbose "Limit of $($i) reached."
        break
    }

    $routeTable = $routeTable | Add-AzureRmRouteConfig  -Name "AzureWhiteList_$($i)" `
        -NextHopType 'INTERNET' `
        -AddressPrefix $ipRange.Subnet `
        -ErrorAction 'Stop'
}

# add additional IP addresses
if ($AdditionalIpFilename) {
    Write-Host "adding additional IPs from $AdditionalIpFilename"
    $additonalIps = Get-Content $AdditionalIpFilename
    foreach ($ip in $additonalIps) {
        $i++

        $ipAddressPrefix = $ip.trim()
        $routeTable = $routeTable | Add-AzureRmRouteConfig  -Name "AzureWhiteList_$($i)" `
            -NextHopType 'INTERNET' `
            -AddressPrefix $ipAddressPrefix `
            -ErrorAction 'Stop'
    }
}


# flush config to routeTable
Write-Output "saving Routes to RouteTable"
$result = Set-AzureRmRouteTable -RouteTable $routeTable

# associate routetable to vnet
if (-not $VnetName) {
    return
}
Write-Output "associating RouteTable to VirtualNetwork $VnetName"

# get vnet information
$resource = Get-AzureRmResource | Where-Object {$_.Name -eq $VnetName -and $_.ResourceType -eq 'Microsoft.Network/virtualNetworks'}
if (-not $resource) {
    Write-Error "VirtualNetwork $VnetName not found."
    return
}

if ($resource -is [array]) {
    Write-Error "Multiple networks named $VnetName were found."
    return
}

# loop through and associate routeTable to subnets
$vnet = Get-AzureRmVirtualNetwork -Name $VnetName -ResourceGroupName $resource.ResourceGroupName -ErrorAction 'Stop'
foreach ($subnet in $vnet.Subnets) {
    if ((($SubnetName -contains $subnet.name) -or ($ApplyToAllSubnets)) -and ($subnet.name -ne 'GatewaySubnet')) {
        Write-Host "associating RouteTable $RouteTableName to Subnet $($VnetName)/$($subnet.Name)"
        $result = Set-AzureRmVirtualNetworkSubnetConfig `
                    -VirtualNetwork $vnet `
                    -Name $subnet.Name `
                    -AddressPrefix $subnet.AddressPrefix `
                    -RouteTableId $routeTable.Id |
                Set-AzureRmVirtualNetwork
    }
}
