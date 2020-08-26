<#
.SYNOPSIS
Add routes to a route table.

.PARAMETER ResourceGroupName
This parameter specifies the Resource Group of the Route Table to update

.PARAMETER RouteTableName
This parameter specifies the name of the Route Table to update 

.PARAMETER Addresses
List of AddressPrefix

.PARAMETER NextHopType
The NextHopType to set for the new routes

.PARAMETER NextHopIpAddress
The NextHopIpAddress to set for the new routes

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

[CmdletBinding()]

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
    [ipaddress] $NextHopIpAddress,

    [Parameter()]
    [switch] $Force
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

    ############################################################
    function NewRoutes {
        param (
            $Address,
            $existingRoutes
        )
    
        $routes = @()

        if ($Address.Name) {
            $name = $Address.Name + '-'
        }

        # allows for passing in a Subnet object or AddressSpace object
        $addressPrefixes = @()
        if ($Address.AddressPrefix) {
            $addressPrefixes += $address.AddressPrefix
        }

        if ($Addresses.AddressPrefixes) {
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
    if ($Addresses.GetType().name -eq 'String') {
        $newRoutes += [PSCustomObject] @{
            Name          = $Addresses.Replace('/', '_') + '-route'
            AddressPrefix = $Addresses
        }
    }
    elseif ($Addresses.GetType().Name -eq 'Object[]' -and $Addresses[0].GetType().Name -eq 'String') {
        foreach ($addressPrefix in $Addresses) {
            $newRoutes += [PSCustomObject] @{
                Name          = $addressPrefix.Replace('/', '_') + '-route'
                AddressPrefix = $addressPrefix
            }
        }
    }
    elseif ($Addresses.GetType().Name -eq 'Object[]' -and $Addresses.Count -eq 1) {
        $newRoutes += NewRoutes -Address $Addresses

    }
    elseif ($Addresses.GetType().Name -eq 'Object[]' -and $Addresses.Count -gt 1) {
        foreach ($address in $Addresses) {
            $newRoutes += NewRoutes -Address $address
        }

    }
    else {
        Write-Error "Addresses types not supported: $Addresses"
    }

}

END {
    $existingRoutes = $routeTable.Routes.AddressPrefix
    $newRoutes = $newRoutes | Where-Object {$existingRoutes -notcontains $_.AddressPrefix}
    
    # no new routes
    if ($newRoutes.count -eq 0) {
        Write-Host "No new routes to add."
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
    if (-not $Force) {
        Write-Host "The following routes will be added (NextRouteType:$NextHopType, NextRouteIPAddress:$NextHopIpAddress):"
        foreach ($newRoute in $newRoutes) {
            Write-Host "`t$($newRoute.Name) - $($newRoute.AddressPrefix)"
        }
        $confirmation = Read-Host "Add these routes? (Y/N)"
        if ($confirmation.ToUpper() -ne 'Y') {
            Write-Host 'Command Aborted.'
            return
        }
    }

    $i = 0;
    foreach ($newRoute in $newRoutes) {
        $result = $routeTable | Add-AzRouteConfig -Name $newRoute.Name -AddressPrefix $newRoute.AddressPrefix -NextHopType $NextHopType -NextHopIpAddress $NextHopIpAddress
        $i++ 
    }

    $result = $routeTable | Set-AzRouteTable
    Write-Host "$($routeTable.ResourceGroupName)/$($routeTable.Name) updated. $i new routes added."
}
