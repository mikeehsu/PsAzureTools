<#
.SYNOPSIS
Add routes to a route table.

.PARAMETER SourceResourceGroupName
Specifies the Resource Group that the source route table belongs to.

.PARAMETER SourceRouteTableName
Specifies the name of the source route table to update .

.PARAMETER DestResourceGroupName
Specifies the Resource Group that the destination route table belongs to.

.PARAMETER DestRouteTableName
Specifies the name of the destination route table to update .

.EXAMPLE
Copy-RouteTable.ps1 -sourceResourceGroupName 'source_rg' -SourceRouteTableName 'source-routetable' -DestResourceGroupName 'copy_rg' -DestRouteTableName 'copy-routetable'

.NOTES

#>

[CmdletBinding(SupportsShouldProcess)]

Param (
    [Parameter(Mandatory)]
    [string] $SourceResourceGroupName,

    [Parameter(Mandatory)]
    [string] $SourceRouteTableName,

    [Parameter(Mandatory)]
    [string] $DestResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestRouteTableName,

    [Parameter()]
    [string] $SourceSubscriptionName,

    [Parameter()]
    [string] $DestSubscriptionName

)

function ExpandObject {

    [Parameter()]
    $Data

    [Parameter()]
    [array] $Properties


    $cmd = '[PsCustomProperty] @{ '
    foreach($property in $Properties) {
        $cmd += + "'" + $property + "= `$Data."
    }
    $cmd += '}'



}



############################################################
# main function
Set-StrictMode -Version 3

# confirm user is logged into subscription
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

$ErrorActionPreference = "Stop"

# load source routetable
if ($SourceSubscriptiopName -and $context.Subscription.Name -ne $SourceSubscriptionName) {
    Select-AzSubscription -SubscriptionName $SourceSubscriptionName
}
$sourceRouteTable = Get-AzRouteTable -ResourceGroupName $SourceResourceGroupName -Name $SourceRouteTableName
if (-not $sourceRouteTable) {
    Write-Error "Unable to find source route table $SourceResourceGroupName/$SourceRouteTableName"
    return
}

# load destination routetable
if ($DestSubscriptionName) {
    Select-AzSubscription -SubscriptionName $DestSubscriptionName
}
$destRouteTable = Get-AzRouteTable -ResourceGroupName $DestResourceGroupName -Name $DestRouteTableName
if (-not $destRouteTable) {
    Write-Error "Unable to find destination route table $DestResourceGroupName/$DestRouteTableName"
    return
}

############################################################

# filter out existing routes
$newRoutes = @()
if ($destRouteTable.Routes.Count -gt 0) {
    $newRoutes += $sourceRouteTable.Routes | Where-Object { $destRouteTable.Routes.AddressPrefix -notcontains $_.AddressPrefix }

}
else {
    $newRoutes += $sourceRouteTable.Routes
}

# no new routes
if ($newRoutes.Count -eq 0) {
    Write-Host "No routes to copy."
    return
}

# confirm addition of routes
$i = 0;
foreach ($newRoute in $newRoutes) {
    if ($PSCmdlet.ShouldProcess($DestRouteTableName, "Add route $($newRoute.Name) with $($newRoute.AddressPrefix), $newRoute.NextHopType, $newRoute.NextHopIpAddress")) {
        Write-Progress -Activity "Copying from $SourceRouteTableName to $DestRouteTableName..." -Status "$($newRoute.Name)" -PercentComplete (($i / $newRoutes.Count) * 100)
        $result = $destRouteTable | Add-AzRouteConfig -Name $newRoute.Name -AddressPrefix $newRoute.AddressPrefix -NextHopType $newRoute.NextHopType -NextHopIpAddress $newRoute.NextHopIpAddress
        $i++
    }
}

# check for anything to do
if ($i -eq 0) {
    Write-Verbose "No new routes added."
    return
}

Write-Progress -Activity "Copying from $SourceRouteTableName to $DestRouteTableName..."  -Status "Saving changes to $DestRouteTableName"
$result = $destRouteTable | Set-AzRouteTable
Write-Progress -Activity "Copying from $SourceRouteTableName to $DestRouteTableName..."  -Completed
Write-Verbose "$($destRouteTable.ResourceGroupName)/$($destRouteTable.Name) - $i new route(s) added."
