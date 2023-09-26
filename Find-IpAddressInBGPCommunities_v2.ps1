<#
.SYNOPSIS
Search Service Tags for an IP Address

.DESCRIPTION
Searches through the BGP Communities for a specific IP Address.

.PARAMETER IPAddress
IP Address to search for

.EXAMPLE
Find-IpAddressInBGPCommunities.ps1 40.90.23.208

#>

[CmdletBinding()]

Param (
    [Parameter(Position = 0, Mandatory = $true)]
    [string[]] $IPAddress
)

#Requires -Modules Az.Accounts
#Requires -Modules Az.Network
#Requires -Modules IPNetwork

############################################################
#
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

# load modules
if (-not (Get-Module Az.Accounts)) {
    Import-Module Az.Accounts
}

if (-not (Get-Module Az.Network)) {
    Import-Module Az.Network
}

if (-not (Get-Module IPNetwork)) {
    Import-Module IPNetwork
}

# confirm user is logged into subscription
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
        return
    }

}
catch {
    Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
    return
}

# load the BGP Communities
$serviceCommunities = Get-AzBgpServiceCommunity

# convert to IpNetwork object
$ips = @()
foreach ($ip in $IPAddress) {
    $ips += Get-IpNetwork -Address $ip
}

# search for the IP Address
$count = 0
$foundCommunities = @()
foreach ($serviceCommunity in $serviceCommunities) {
    $count++
    Write-Progress -Activity "Searching for $ipAddress" -Status "Checking $($serviceCommunity.Name)..." -PercentComplete (($count / $serviceCommunities.count) * 100)
    forEach ($bgpCommunity in $serviceCommunity.BgpCommunities) {
        forEach ($addressPrefix in $bgpCommunity.CommunityPrefixes) {
            foreach ($ip in $ips) {
                $ipPrefix = Get-IPNetwork -Address $addressPrefix
                if ($ipPrefix.Contains($ip)) {
                    $foundCommunities += [PSCustomObject] @{
                        IPAddress            = $ip.Network
                        Name                 = $serviceCommunity.name
                        CommunityName        = $bgpCommunity.CommunityName
                        ServiceSupportRegion = $bgpCommunity.ServiceSupportedRegion
                        CommunityValue       = $bgpCommunity.CommunityValue
                        CommunityPrefix      = $addressPrefix
                    }
                }
            }
        }
    }
}

Write-Progress -Activity "Searching for $ipAddress" -Completed
$foundCommunities

# no communities found
if (-not $foundCommunities) {
    Write-Host "No BGP communities found for $($ips.Network -join ', ')"
    return
}

# list any IPs that were not found in the BGP Communities
$notFound = $ips | Where-Object {$foundCommunities.IpAddress -notcontains $_.Network}
if ($notFound) {
    Write-Host "No BGP communities found for $($notFound.Network -join ', ')"
}
