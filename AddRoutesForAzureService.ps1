##############################
#.SYNOPSIS
# Add routes to a route table for Azure Services defined in the Service Tag files
#
#.DESCRIPTION
# Creates routes in an existing Route Table for the various services specified
# in the Azure Service Tag files posted in the online resources. You can specify
# a combination of specific services and/or locations for the services that you
# want to add.
#
#.PARAMETER ResourceGroupName
# This parameter specifies the Resource Group of the Route Table 
# to update.
#
#.PARAMETER RouteTableName
# This parameter specifies the name of the Route Table to update 
#
#.PARAMETER Location
# If this parameter is specified, the IP Address for the given location will be
# added to the Route Table. This parameter can be used in conjunction with the
# Service parameter to further narrow the list of IPs to add.
#
#.PARAMETER Service
# If this parameter is specified, the IP Address for the given service will be
# added to the Route Table. This parameter can be used in conjunction with the
# Location parameter to further narrow the list of IPs to add.
#
#.PARAMETER Force
# If this parameter is specified, the Route Table will be updated without confirmation. 
#
#.EXAMPLE
# AddRoutesForAzureServices.ps1 -ResourceGroupName myRg -RouteTableName myRouteTable
#
#.NOTES
#
##############################

[CmdletBinding()]

Param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $RouteTableName,

    [Parameter(Mandatory=$false)]
    [string] $Location = $null,

    [Parameter(Mandatory=$false)]
    [string] $Service = $null,

    [Parameter(Mandatory=$False)]
    [switch] $Force
)


############################################################
# main function

# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
    exit
}

$ErrorActionPreference = "Stop"

$environment = $(Get-AzureRmSubscription).ExtendedProperties.Environment
if ($environment -eq 'AzureUSGovernment') {
    $url = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=57063'

} elseif ($environment -eq 'AzureCloud') {
    $url = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519'

} else {
    Write-Error "Sorry $environment is currently not supported."
    return
}

# verify route table
$routeTable = Get-AzureRmRouteTable -ResourceGroupName $ResourceGroupName -Name $RouteTableName
if (-not $routeTable) {
    Write-Error "Unable to find $ResourceGroupName/$RouteTableName routetable."
    return
}


# find the link for file
$pageHTML = Invoke-WebRequest $url -UseBasicParsing
$fileLink = ($pageHTML.Links | Where-Object {$_.outerHTML -like "*click here to download manually*"}).href

# extract the filename
$pathParts = $fileLink.Split('/')
$serviceTagFilename = $env:TEMP + '\' + $pathParts[$pathParts.count-1]

# download the JSON file to the TEMP directory
$null = Invoke-WebRequest $fileLink -PassThru -OutFile $serviceTagFilename
$serviceTags = Get-Content -Raw -Path $serviceTagFilename | ConvertFrom-Json

# build the tagName
$tagName = ''
if ($Service) {
    $tagName = $Service
}

if ($Location) {
    if ([string]::IsNullOrEmpty($tagName)) {
        $tagName += 'AzureCloud.'
    } else {
        $tagName += '.'
    }

    $tagName += $Location
}

if ([string]::IsNullOrEmpty($tagName)) {
    $tagName += 'AzureCloud'
}

# find the IPs for the tag
$tagAddressPrefixes = ($serviceTags.Values | Where-Object {$_.Name -eq $tagName}).properties.addressprefixes

$newPrefixes = @()
foreach($tagAddressPrefix in $tagAddressPrefixes) {
    $route = $routeTable.Routes | Where-Object {$_.AddressPrefix -eq $tagAddressPrefix}
    if (-not $route) {
        $newPrefixes += $tagAddressPrefix
    }
}

# no new routes
if ($newPrefixes.count -eq 0) {
    Write-Output "No new routes to add."
    return
}

# confirm addition of routes
if (-not $Force) {
    Write-Output "The following routes will be added:"
    $newPrefixes
    $confirmation = Read-Host "Add these routes? (Y/N)"
    if ($confirmation.ToUpper() -ne 'Y') {
        Write-Output 'Command Aborted.'
        return
    }
}

$i = 0;
foreach ($prefix in $newPrefixes) {
    do {
        $i++
        $routeName = $tagName + '-' +  $("{0:d3}" -f $i)
    } until ($routeTable.routes | Where-Object {$_.Name -eq 'Route-2'});
    $result = $routeTable | Add-AzureRmRouteConfig -Name $routeName -AddressPrefix $prefix -NextHopType 'Internet'
}

$result = $routeTable | Set-AzureRmRouteTable
Write-Output "$($routeTable.ResourceGroupName)/$($routeTable.Name) has been updated."