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
    [string] $IPAddress
)

#####################################################################
Function Get-IPv4NetworkInfo {
    <#
    .SYNOPSIS
    Gets extended information about an IPv4 network.

    .DESCRIPTION
    Gets Network Address, Broadcast Address, Wildcard Mask. and usable host range for a network given the IP address and Subnet Mask.

    .PARAMETER IPAddress
    IP Address of any ip within the network Note: Exclusive from @CIDRAddress

    .PARAMETER SubnetMask
    Subnet Mask of the network. Note: Exclusive from @CIDRAddress

    .PARAMETER CIDRAddress
    CIDR Notation of IP/Subnet Mask (x.x.x.x/y) Note: Exclusive from @IPAddress and @SubnetMask

    .PARAMETER IncludeIPRange
    Switch parameter that defines whether or not the script will return an array of usable host IP addresses within the defined network.
    Note: This parameter can cause delays in script completion for larger subnets.

    .EXAMPLE
    Get-IPv4NetworkInfo -IPAddress 192.168.1.23 -SubnetMask 255.255.255.0

    Get network information with IP Address and Subnet Mask

    .EXAMPLE
    Get-IPv4NetworkInfo -CIDRAddress 192.168.1.23/24

    Get network information with CIDR Notation

    .NOTES
    File Name  : Get-IPv4NetworkInfo.ps1
    Author     : Ryan Drane
    Date       : 5/10/16
    Requires   : PowerShell v3

    .LINK
    https://www.ryandrane.com
    https://www.ryandrane.com/2016/05/getting-ip-network-information-powershell/
    #>

    Param
    (
        [Parameter(ParameterSetName = 'IPandMask', Mandatory = $true)]
        [ValidateScript( { $_ -match [ipaddress]$_ })]
        [System.String] $IPAddress,

        [Parameter(ParameterSetName = 'IPandMask', Mandatory = $true)]
        [ValidateScript( { $_ -match [ipaddress]$_ })]
        [System.String] $SubnetMask,

        [Parameter(ParameterSetName = 'CIDR', Mandatory = $true)]
        [ValidateScript( { $_ -match '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/([0-9]|[0-2][0-9]|3[0-2])$' })]
        [System.String] $CIDRAddress,

        [Switch] $IncludeIPRange
    )

    # If @CIDRAddress is set
    if ($CIDRAddress) {
        # Separate our IP address, from subnet bit count
        $IPAddress, [int32]$MaskBits = $CIDRAddress.Split('/')

        # Create array to hold our output mask
        $CIDRMask = @()

        # For loop to run through each octet,
        for ($j = 0; $j -lt 4; $j++) {
            # If there are 8 or more bits left
            if ($MaskBits -gt 7) {
                # Add 255 to mask array, and subtract 8 bits
                $CIDRMask += [byte]255
                $MaskBits -= 8
            }
            else {
                # bits are less than 8, calculate octet bits and
                # zero out our $MaskBits variable.
                $CIDRMask += [byte]255 -shl (8 - $MaskBits)
                $MaskBits = 0
            }
        }

        # Assign our newly created mask to the SubnetMask variable
        $SubnetMask = $CIDRMask -join '.'
    }

    # Get Arrays of [Byte] objects, one for each octet in our IP and Mask
    $IPAddressBytes = ([ipaddress]::Parse($IPAddress)).GetAddressBytes()
    $SubnetMaskBytes = ([ipaddress]::Parse($SubnetMask)).GetAddressBytes()

    # Declare empty arrays to hold output
    $NetworkAddressBytes = @()
    $BroadcastAddressBytes = @()
    $WildcardMaskBytes = @()

    # Determine Broadcast / Network Addresses, as well as Wildcard Mask
    for ($i = 0; $i -lt 4; $i++) {
        # Compare each Octet in the host IP to the Mask using bitwise
        # to obtain our Network Address
        $NetworkAddressBytes += $IPAddressBytes[$i] -band $SubnetMaskBytes[$i]

        # Compare each Octet in the subnet mask to 255 to get our wildcard mask
        $WildcardMaskBytes += $SubnetMaskBytes[$i] -bxor 255

        # Compare each octet in network address to wildcard mask to get broadcast.
        $BroadcastAddressBytes += $NetworkAddressBytes[$i] -bxor $WildcardMaskBytes[$i]
    }

    # Create variables to hold our NetworkAddress, WildcardMask, BroadcastAddress
    $NetworkAddress = $NetworkAddressBytes -join '.'
    $BroadcastAddress = $BroadcastAddressBytes -join '.'
    $WildcardMask = $WildcardMaskBytes -join '.'

    # Now that we have our Network, Widcard, and broadcast information,
    # We need to reverse the byte order in our Network and Broadcast addresses
    [array]::Reverse($NetworkAddressBytes)
    [array]::Reverse($BroadcastAddressBytes)

    # We also need to reverse the array of our IP address in order to get its
    # integer representation
    [array]::Reverse($IPAddressBytes)

    # Next we convert them both to 32-bit integers
    $NetworkAddressInt = [System.BitConverter]::ToUInt32($NetworkAddressBytes, 0)
    $BroadcastAddressInt = [System.BitConverter]::ToUInt32($BroadcastAddressBytes, 0)
    # $IPAddressInt        = [System.BitConverter]::ToUInt32($IPAddressBytes,0)

    #Calculate the number of hosts in our subnet, subtracting one to account for network address.
    $NumberOfHosts = ($BroadcastAddressInt - $NetworkAddressInt) - 1

    #Calculate the max and min usable host IPs.
    if ($NumberOfHosts -gt 1) {
        $HostMinIP = [ipaddress]([convert]::ToDouble($NetworkAddressInt + 1)) | Select-Object -ExpandProperty IPAddressToString
        $HostMaxIP = [ipaddress]([convert]::ToDouble($NetworkAddressInt + $NumberOfHosts)) | Select-Object -ExpandProperty IPAddressToString

        # Declare an empty array to hold our range of usable IPs.
        $IPRange = @()

        # If -IncludeIPRange specified, calculate it
        if ($IncludeIPRange) {
            # Now run through our IP range and figure out the IP address for each.
            For ($j = 1; $j -le $NumberOfHosts; $j++) {
                # Increment Network Address by our counter variable, then convert back
                # lto an IP address and extract as string, add to IPRange output array.
                $IPRange += [ipaddress]([convert]::ToDouble($NetworkAddressInt + $j)) | Select-Object -ExpandProperty IPAddressToString
            }
        }
    }
    else {
        # brokend out to accommodate /32 blocks
        $NumberOfHosts = 1
        $HostMinIP = $IPAddress
        $HostMaxIP = $IPAddress
        $IpRange = @($IPAddress)
    }

    # Create our output object
    $obj = New-Object -TypeName psobject

    # Add our properties to it
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'IPAddress'         -Value $IPAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'SubnetMask'        -Value $SubnetMask
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'NetworkAddress'    -Value $NetworkAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'BroadcastAddress'  -Value $BroadcastAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'WildcardMask'      -Value $WildcardMask
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'NumberOfHostIPs'   -Value $NumberOfHosts
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'HostMinIp'         -Value $HostMinIP
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'HostMaxIp'         -Value $HostMaxIP
    Add-Member -InputObject $obj -MemberType NoteProperty -Name 'IPRange'           -Value $IPRange

    # Return the object
    return $obj
}

############################################################
function PadIpAddress {
    param (
        [string] $IPAddress
    )

    $parts = $IPAddress -split '\.'
    for ($i = 0; $i -lt $parts.count; $i++) {
        $parts[$i] = $parts[$i].PadLeft(3, '0')
    }

    return $($parts -join '.')
}

############################################################
function CompareSubnet {
    # inspired by: http://www.gi-architects.co.uk/2016/02/powershell-check-if-ip-or-subnet-matchesfits/
    param (
        [Parameter(Mandatory)]
        [string] $addr1,

        [Parameter(Mandatory)]
        [string] $addr2
    )

    $mask1 = $null
    $mask2 = $null

    # Separate the network address and lenght
    $network1, [int] $subnetlen1 = $addr1.Split('/')
    $network2, [int] $subnetlen2 = $addr2.Split('/')

    #Convert network address to binary
    [uint32] $unetwork1 = NetworkToBinary $network1
    [uint32] $unetwork2 = NetworkToBinary $network2

    #Check if subnet length exists and is less then 32(/32 is host, single ip so no calculation needed) if so convert to binary
    $mask1 = $null
    if ($subnetlen1 -lt 32) {
        [uint32] $mask1 = SubToBinary $subnetlen1
    }

    $mask2 = $null
    if ($subnetlen2 -lt 32) {
        [uint32] $mask2 = SubToBinary $subnetlen2
    }

    #Compare the results
    if ($mask1 -and $mask2) {
        # If both inputs are subnets check which is smaller and check if it belongs in the larger one
        if ($mask1 -lt $mask2) {
            return CheckSubnetToNetwork $unetwork1 $mask1 $unetwork2
        }
        else {
            return CheckNetworkToSubnet $unetwork2 $mask2 $unetwork1
        }
    }
    elseif ($mask1) {
        # If second input is address and first input is subnet check if it belongs
        return CheckSubnetToNetwork $unetwork1 $mask1 $unetwork2
    }
    elseif ($mask2) {
        # If first input is address and second input is subnet check if it belongs
        return CheckNetworkToSubnet $unetwork2 $mask2 $unetwork1
    }
    else {
        # If both inputs are ip check if they match
        return CheckNetworkToNetwork $unetwork1 $unetwork2
    }
}

############################################################
function CheckNetworkToSubnet {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory)]
        [uint32] $un2,

        [Parameter(Mandatory)]
        [uint32] $ma2,

        [Parameter(Mandatory)]
        [uint32] $un1
    )

    if ($un2 -eq ($ma2 -band $un1)) {
        return [PSCustomObject] @{
            Condition = $True
            Direction = 'LessThan'
        }
    }

    return [PSCustomObject] @{
        Condition = $False
        Direction = ''
    }
}

############################################################
function CheckSubnetToNetwork {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [uint32]$un1,

        [Parameter(Mandatory)]
        [uint32]$ma1,

        [Parameter(Mandatory)]
        [uint32]$un2
    )

    if ($un1 -eq ($ma1 -band $un2)) {
        return [PSCustomObject] @{
            Condition = $true
            Direction = 'GreaterThan'
        }
    }

    return [PSCustomObject] @{
        Condition = $false
        Direction = ''
    }
}

############################################################
function CheckNetworkToNetwork {

    parm (
        [Parameter(Mandatory)]
        [uint32] $un1,

        [Paramter(Mandatory)]
        [uint32] $un2
    )

    if ($un1 -eq $un2) {
        return [PSCustomObject] @{
            Condition = $True
            Direction = 'LessThan'
        }
    }

    return [PSCustomObject] @{
        Condition = $False
        Direction = ''
    }
}

############################################################
function SubToBinary {
    param (
        [Parameter(Mandatory)]
        [int] $sub
    )

    return ((-bnot [uint32]0) -shl (32 - $sub))
}

############################################################
function NetworkToBinary {
    param (
        [Parameter(Mandatory)]
        [string] $network
    )

    $a = [uint32[]]$network.split('.')
    return ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]
}


############################################################
function IsIpAddressInCIDR {
    Param(
        [parameter(Mandatory = $true)]
        [string] $IPAddress,

        [parameter(Mandatory = $true)]
        [string] $CIDRAddress
    )

    $result = CompareSubnet -addr1 $IPAddress -addr2 $CIDRAddress
    return ($result.Condition -and $result.Direction -eq 'LessThan')
}

############################################################
#
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

# load modules
if (-not (Get-Module -ListAvailable -Name 'Az.Network')) {
    Write-Host 'Az.Network module required.'
    return
}
Import-Module Az.Network

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

$foundCommunities = @()
foreach ($serviceCommunity in $serviceCommunities) {
    Write-Verbose "Checking service: $($serviceCommunity.Name)"
    forEach ($bgpCommunity in $serviceCommunity.BgpCommunities) {
        forEach ($addressPrefix in $bgpCommunity.CommunityPrefixes) {
            if ($(IsIpAddressInCIDR -IPAddress $ipaddress -CIDRAddress $addressPrefix)) {
                $foundCommunities += [PSCustomObject] @{
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

if ($foundCommunities) {
    Write-Verbose "$($foundCommunities.Count) entries found"
    return $foundCommunities
}
else {
    Write-Host 'No entries found'
}
