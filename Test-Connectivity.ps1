<#
.SYNOPSIS
Test network connectivity to a set of IP addresses

.DESCRIPTION
This Powershell command will attempt to connect to given IP addresses on specified ports to test availability of destination addresss/ports and return the results.

For more advanced testing, you can provide a CSV with the list of IP addresses, ports and expected results. This command will return a pass (OK), or FAILED status for each test, depending on whether the connection match the expected results.

.PARAMETER IpAddresses
Array of IP addresses to test. To test a continuous set of IP Addresses, a range can be specified using a dash between two IP addresses like: 192.168.1.1-192.168.1.100

.PARAMETER Ports
Array of ports to test. Each IP address will be tested for connectivity on all of the ports provided. A failure on any of the ports will return a status of FAILED. If no ports are given, port 80 will be used by default for all IP addresses.

.PARAMETER Details

If this parameter is set, then the ports that were found to be open along with a list of ports that were expected to be open will be displayed.
.PARAMETER FilePath

To specify a different set of ports to tset for each IP address or to validate lack of connectivity you can specify a CSV file with a detailed list of IP addresses, ports to test and expected results. (See ./sample/SampleTestConnectivity.csv for example)
.PARAMETER OutputPath

If this parameter is supplied, a CSV file will be created with the test results
.PARAMETER Continuous
Setting this will cause the test to loop continously, displaying the results to the screen

.PARAMETER OnlyShowFailed
Setting this will limit the displayed results to only tests that fail.

.PARAMETER Frequency
This parameter sets the frequency of which the tests are performed. The default is every 5 seconds. This parameter is only effective when used with the -Continuous

.PARAMETER Timeout
This parameter sets the waiting period for connections before the attempt is considered a failure.

.EXAMPLE
.\TestConnectivity.ps1 .\sample\SampleTestConnectivity.csv

.EXAMPLE
.\TestConnectivity.ps1 -IPAddresses '192.168.1.1-192.168.1.20' -Continuous
#>
[CmdletBinding()]

Param(

    [Parameter(ParameterSetName = 'IpAddress', ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('IpAddress', 'AddressPrefixes', 'AddressPrefix')]
    [string[]] $IpAddresses,

    [Parameter(Mandatory = $false)]
    [Alias('Port')]
    [int[]] $Ports,

    [Parameter(ParameterSetName = 'FilePath')]
    [string] $FilePath,

    [Parameter()]
    [switch] $Details,

    [Parameter(Mandatory = $false)]
    [string] $OutputPath,

    [Parameter()]
    [switch] $Continuous,

    [Parameter()]
    [switch] $OnlyShowPassed,

    [Parameter()]
    [switch] $OnlyShowFailed,

    [Parameter(Mandatory = $false)]
    [int] $Frequency = 5,

    [Parameter(Mandatory = $false)]
    [int] $TimeOut = 1000
)

Set-StrictMode -Version Latest

Class TestCase {
    [string] $IpAddress
    [int[]]  $PortsToTest
    [int[]]  $PortsExpected
    [int[]]  $PortsOpen
    [int[]]  $PortsFailed
    [array]  $Connections
    [string] $Status
}


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

#####################################################################
function GetIpInRange {

    Param(
        [parameter(Mandatory = $true)]
        [ValidatePattern('\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b')]
        [string] $StartIpAddress,

        [parameter()]
        [ValidatePattern('\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b')]
        [string] $EndIpAddress = $StartIPAddress
    )

    $ipSet = @()

    $startOctets = $StartIpAddress.Split('.')
    $endOctets = $EndIpAddress.Split('.')

    if ($startOctets[0] -ne $endOctets[0]) {
        Write-Error 'Too large an IP range. Please break into smaller ranges'
        return
    }

    $startOctet1 = $startOctets[0]
    $endOctet1 = $endOctets[0]

    $startOctet2 = $startOctets[1]
    $endOctet2 = $endOctets[1]

    $startOctet3 = $startOctets[2]
    $endOctet3 = $endOctets[2]

    $startOctet4 = $startOctets[3]
    $endOctet4 = $endOctets[3]

    foreach ($a in ($startOctet1..$endOctet1)) {
        foreach ($b in ($startOctet2..$endOctet2)) {
            if ($b -eq $startOctet2) {
                $startOctet3 = $startOctets[2]
            }
            else {
                $startOctet3 = 0
            }

            if ($b -eq $endOctet2) {
                $endOctet3 = $endOctets[2]
            }
            else {
                $endOctet3 = 255
            }

            foreach ($c in ($startOctet3..$endOctet3)) {
                if ($b -eq $startOctet2 -and $c -eq $startOctet3) {
                    $startOctet4 = $startOctets[3]
                }
                else {
                    $startOctet4 = 0
                }

                if ($b -eq $endOctet2 -and $c -eq $endOctet3) {
                    $endOctet4 = $endOctets[3]
                }
                else {
                    $endOctet4 = 255
                }

                foreach ($d in ($startOctet4..$endOctet4)) {
                    $ipSet += "$a.$b.$c.$d"
                }
            }
        }
    }

    return $ipSet
}

############################################################################
Function ParseIpAddressRange {

    param (
        [Parameter(Mandatory = $true)]
        [string] $IpAddressRange
    )

    if ($IpAddressRange -like '*-*') {
        $ipRange = $IpAddressRange.Split('-')

        $startIp = $ipRange[0]
        if ($ipRange.Length -eq 1) {
            $endIp = $startIp
        }
        else {
            $endIp = $ipRange[1]
        }
        $ipSet = GetIpInRange -StartIpAddress $startIp -EndIpAddress $endIp
    }
    elseif ($IpAddressRange -like '*/*') {
        $ipSet = (Get-IPv4NetworkInfo -CIDRAddress $IpAddressRange -IncludeIPRange).IPRange

    }
    else {
        $ipSet = $test.IpAddress.Split(';')
    }

    return $ipSet

}

############################################################################

Set-StrictMode -Version 3

$report = @()
$testCases = @()

# validate parameters
if (-not $Ports) {
    $Ports = @(80, 443)
}

if (-not ($FilePath -or $IpAddresses)) {
    Write-Error 'Either -FilePath ore -IpAddresses must be supplied.'
    return
}

if ($OutputPath -and $Continuous) {
    Write-Error '-Continuous and -OutputPath can not be used together, Please remove one and try again.'
    return
}

if ($OnlyShowPassed -and $OnlyShowFailed) {
    Write-Error '-OnlyShowPassed and -OnlyShowFailed cannot be used togetehr. Please remove one and try again.'
    return
}

# setup test cases
if ($IpAddresses) {
    foreach ($IpAddress in $IpAddresses) {
        $ipSet = ParseIpAddressRange -IpAddressRange $IpAddress

        foreach ($ip in $ipSet) {
            $testCase = [TestCase]::New()
            $testCase.IpAddress = $ip
            $testCase.PortsToTest = $Ports
            $testCase.PortsExpected = $Ports

            $testCases += $testCase
        }
    }
    Write-Verbose "$IpAddress being be tested"
}

if ($FilePath) {
    $portsToTestIncluded = $false
    $portsExpectedIncluded = $false

    $testFile = Import-Csv -Path $FilePath -Delimiter ','

    if ($testFile | Get-Member -MemberType 'NoteProperty' | Where-Object { $_.Name -eq 'PortsToTest' }) {
        $portsToTestIncluded = $true
    }

    if ($testFile | Get-Member -MemberType 'NoteProperty' | Where-Object { $_.Name -eq 'PortsExpected' }) {
        $portsExpectedIncluded = $true
    }

    # buuld test cases
    foreach ($test in $testFile) {
        # port settings
        $portsToTest = @()
        if ($portsToTestIncluded -and ($test.PortsToTest.Trim().Length -gt 0)) {
            $portsToTest = $test.PortsToTest.Split(';')
        }
        else {
            $portsToTest = $Ports
        }

        $portsExpected = @()
        if ($portsExpectedIncluded) {
            if ($test.PortsExpected.Trim().Length -gt 0) {
                $portsExpected = $test.PortsExpected.Split(';')
            }
        }
        else {
            $portsExpected = $portsToTest
        }

        # ipAddresses
        $ipSet = ParseIpAddressRange -IpAddressRange $test.IpAddress

        foreach ($ip in $ipSet) {
            $testCase = [TestCase]::New()
            $testCase.IpAddress = $ip
            $testCase.PortsToTest = $portsToTest
            $testCase.PortsExpected = $portsExpected

            $testCases += $testCase
        }
    }
}

# do continuously
do {

    # execute the tests
    foreach ($test in $testCases) {
        $test.Status = $null
        $test.Connections = @()
        $test.PortsOpen = @()
        $test.PortsFailed = @()

        for ($i = 0; $i -lt $test.PortsToTest.length; $i++) {
            $test.Connections += New-Object System.Net.Sockets.TcpClient
            $null = $test.Connections[$i].BeginConnect($test.IpAddress, $test.portsToTest[$i], $null, $null)
        }
    }

    # wait for results -- wait the timeout period to give all connections the chance to complete
    Start-Sleep -Milli $TimeOut

    # check results
    foreach ($test in $testCases) {
        $test.PortsOpen = @()
        for ($i = 0; $i -lt $test.PortsToTest.length; $i++) {
            if ($test.Connections[$i].Connected) {
                $test.PortsOpen += $test.PortsToTest[$i]
            }
        }

        $temp = Compare-Object $test.PortsOpen $test.PortsExpected | Select-Object InputObject
        if ($temp) {
            $test.PortsFailed = $temp.InputObject
        }

        if ($test.PortsFailed) {
            $test.Status = 'FAILED'
        }
        else {
            $test.Status = 'OK'
        }
    }

    # clean up connections
    foreach ($test in $testCases) {
        foreach ($connection in $test.Connections) {
            $connection.Close()
        }
    }

    # display results
    if ($Details) {
        $report = $testCases | Select-Object -Property Status, IpAddress, PortsFailed, PortsExpected, PortsOpen
    }
    else {
        $report = $testCases | Select-Object -Property Status, IpAddress, PortsFailed
    }

    if ($OnlyShowFailed) {
        $report = $report | Where-Object { $_.Status -eq 'FAILED' }
    }
    elseif ($OnlyShowPassed) {
        $report = $report | Where-Object { $_.Status -eq 'OK' }
    }

    # display on screen
    if ($Continuous) {
        Clear-Host
        Write-Host "Current Time: $(Get-Date -UFormat '%Y-%m-%d %H:%M:%S')"
    }

    $report | Format-Table

    if ($Continuous) {
        Start-Sleep $Frequency
    }

} while ($Continuous)

if ($OutputPath) {
    $report | Export-Csv $OutputPath
}

