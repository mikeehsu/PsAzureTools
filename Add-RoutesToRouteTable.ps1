<#
.SYNOPSIS
Add routes to a route table.

.PARAMETER ResourceGroupName
Specifies the Resource Group that the route table belongs to.

.PARAMETER RouteTableName
Specifies the name of the route table to update .

.PARAMETER Addresses
Specifies the AddressPrefixes to add to the route table. This list can be in the form of an array of AddressPrefix or an array of objects containing an AddressPrefix property, making it useful for piping in AddressSpace or Subnet arrays from a Virtual Network object.

.PARAMETER NextHopType
Specifies the NextHopType to set for the new routes.

.PARAMETER NextHopIpAddress
Specifies the NextHopIpAddress to set for the new routes.

.PARAMETER Force
If this parameter is specified, the Route Table will be updated without confirmation.

.EXAMPLE
Add-RoutesToRouteTable.ps1 -ResourceGroupName myRg -RouteTableName myRouteTable -Addresses @('10.1.0.0/24', '10.1.1.0/24') -NextHopType VirtualAppliance -NextHopIpAddress '10.3.0.1'

.EXAMPLE
(Get-AzVirtualNetwork -ResourceGroupName myRg -Name myVnet).AddressSpace | Add-RoutesToRouteTable.ps1 -ResourceGroupName myRg -RouteTableName myRouteTable -NextHopType VirtualAppliance -NextHopIpAddress '10.3.0.1'

.EXAMPLE
(Get-AzVirtualNetwork -ResourceGroupName myRg -Name myVnet).Subnets | Add-RoutesToRouteTable.ps1 -ResourceGroupName myRg -RouteTableName myRouteTable -NextHopType VirtualAppliance -NextHopIpAddress '10.3.0.1' -Force

.NOTES

#>

[CmdletBinding(SupportsShouldProcess)]

Param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [Alias('Name')]
    [string] $RouteTableName,

    [Parameter(Mandatory, ValueFromPipeline)]
    [Alias('Address')]
    [array] $Addresses,

    [Parameter(Mandatory)]
    [ValidateSet('VirtualNetwork','VirtualNetworkGateway','Internet','VirtualAppliance','None')]
    [string] $NextHopType,

    [Parameter()]
    [ipaddress] $NextHopIpAddress
)


############################################################
# main function

BEGIN {

    # validate parameters
    if ($NextHopType -eq 'VirtualAppliance' -and -not $NextHopIpAddress) {
        Write-Error "-NextHopIpAddress is required for -NextHopType of 'VirtualAppliance'"
        return
    }

    # confirm user is logged into subscription
    try {
        $result = Get-AzContext -ErrorAction Stop
        if (-not $result.Environment) {
            Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
            return
        }

    }
    catch {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        return
    }

    $ErrorActionPreference = "Stop"
    $newRoutes = @()

    # get route table
    $routeTable = Get-AzRouteTable -ResourceGroupName $ResourceGroupName -Name $RouteTableName
    if (-not $routeTable) {
        Write-Error "Unable to find route table $ResourceGroupName/$RouteTableName"
        return
    }
}

PROCESS {

    # Set-StrictMode -Version 3

    ############################################################
    function NewRoutes {
        param (
            $Address
        )

        $routes = @()

        if ($Address.Name) {
            $name = $Address.Name + '-'
        }

        # allows for passing in a Subnet object or AddressSpace object
        $addressPrefixes = @()
        if  ($address.AddressPrefix) {
            $addressPrefixes += $address.AddressPrefix
        }

        if  ($address.AddressPrefixes) {
            $addressPrefixes += $address.AddressPrefixes
        }

        foreach ($addressPrefix in $addressPrefixes) {
            $routes += [PSCustomObject] @{
                Name          = $name + $addressPrefix.Replace('/', '_') + '-route'
                AddressPrefix = $addressPrefix
            }
        }

        return $routes
    }


    ############################################################

    # determine type of array passed in
    if ($Addresses -is [string]) {
        # passed in a single string (not an array)
        $newRoutes += [PSCustomObject] @{
            Name          = $Addresses.Replace('/', '_') + '-route'
            AddressPrefix = $Addresses
        }
    }
    elseif ($Addresses -is [array] -and $Addresses[0] -is [string]) {
        # passed in a array of strings
        foreach ($addressPrefix in $Addresses) {
            $newRoutes += [PSCustomObject] @{
                Name          = $addressPrefix.Replace('/', '_') + '-route'
                AddressPrefix = $addressPrefix
            }
        }
    }
    elseif ($Addresses -is [object]) {
        # passed in a single object (pipeline passes in a single object at a time)
        $newRoutes += NewRoutes -Address $Addresses

    }
    elseif ($Addresses -is [array] -and $Addresses[0] -is [object]) {
        # passed in an array of objects
        foreach ($address in $Addresses) {
            $newRoutes += NewRoutes -Address $address
        }

    }
    else {
        Write-Error "Addresses types not supported: $Addresses"
    }

}

END {
    # filter out existing routes
    $newRoutes = $newRoutes | Where-Object {$routeTable.Routes.AddressPrefix -notcontains $_.AddressPrefix}

    # no new routes
    if (-not $newRoutes -or $newRoutes.count -eq 0) {
        Write-Verbose "No new routes to add."
        return
    }

    # validate each AddressPrefix
    foreach ($newRoute in $newRoutes) {
        if ($newRoute.AddressPrefix -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$') {
            Write-Error "Invalid AddressPrefix $($newRoute.AddressPrefix)"
            return
        }
    }

    # confirm addition of routes
    $i = 0;
    foreach ($newRoute in $newRoutes) {
        if ($PSCmdlet.ShouldProcess($RouteTableName, "Add route $($newRoute.Name) with $($newRoute.AddressPrefix), $NextHopType, $NextHopIpAddress")) {
            $result = $routeTable | Add-AzRouteConfig -Name $newRoute.Name -AddressPrefix $newRoute.AddressPrefix -NextHopType $NextHopType -NextHopIpAddress $NextHopIpAddress
            $i++
        }
    }

    # check for anything to do
    if ($i -eq 0) {
        Write-Verbose "No new routes added."
        return
    }

    $result = $routeTable | Set-AzRouteTable
    Write-Verbose "$($routeTable.ResourceGroupName)/$($routeTable.Name) - $i new route(s) added."
}
