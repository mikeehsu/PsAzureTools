<#
.SYNOPSIS
Test network connectivity between a source IP address and one or more destination IP addresses and ports using Azure Network Watcher.

.DESCRIPTION
Tests network connectivity between a source IP address and one or more destination IP addresses and ports using Azure Network Watcher. The script can be used to diagnose network connectivity issues and verify that traffic is allowed between the source and destination IP addresses and ports.

The script requires the Azure Network Watcher service to be enabled in the Azure subscription and a Network Watcher resource to be created in the same region as the source and destination IP addresses. Additionally, the Network Watcher extension must be installed on all VMs that are used as source IP addresses.

The script supports two modes of operation: IP address mode and file mode. In IP address mode, the script tests connectivity between a single source IP address and one or more destination IP addresses and ports. In file mode, the script reads a list of source and destination IP addresses and ports from a file and tests connectivity between each source and destination pair.

.PARAMETER ResourceGroupName
Specifies the name of the resource group that contains the Network Watcher resource

.PARAMETER NetworkWatcherName
Specifies the name of the Network Watcher resource.

.PARAMETER SourceAddress
Specifies the source IP address to test connectivity from

.PARAMETER SourcePort
Specifies the source port to test connectivity from

.PARAMETER DestinationAddresses
Specifies the destination IP addresses to test connectivity to

.PARAMETER DestinationPorts
Specifies the destination ports to test connectivity to

.PARAMETER FilePath
Specifies the path to a CSV file containing the source and destination IP addresses and ports to test connectivity between. The file must contain a header row with the following column names: SourceAddress, SourcePort, DestinationAddress, DestinationPort. The script will ignore any other columns in the file.

.EXAMPLE
Test-NetworkWatcher.ps1 -ResourceGroupName "MyResourceGroup" -NetworkWatcherName "MyNetworkWatcher" -SourceAddress "10.0.0.4" -SourcePort "3389" -DestinationAddresses "10.0.0.5" -DestinationPorts 3389

#>
[CmdletBinding()]

Param(
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory=$true)]
    [string] $NetworkWatcherName,

    [Parameter(ParameterSetName='IpAddress')]
    [string] $SourceAddress,

    [Parameter(ParameterSetName='IpAddress')]
    [string] $SourcePort,

    [Parameter(ParameterSetName='IpAddress')]
    [Alias("IpAddress", "DestinationAddress")]
    [string[]] $DestinationAddresses,

    [Parameter()]
    [Alias("Port", "DestinationPort")]
    [int[]] $DestinationPorts = @(80, 443),

    [Parameter(ParameterSetName='FilePath')]
    [string] $FilePath

)

Set-StrictMode -Version Latest

Class TestCase {
    [string] $SourceAddress
    [int] $SourcePort
    [string] $DestinationAddress
    [int] $DestinationPort
    [string] $SourceId
    [int] $JobId
}

class VmIpMap {
    [array] static $vms

    VmIpMap() {
        # load IP address of all VMs in the subscription
        $query = @"
Resources
    | where type =~ 'microsoft.compute/virtualmachines'
    | project vmId = tolower(tostring(id)), vmName = name, powerState = tostring(properties.extended.instanceView.powerState.displayStatus)
    | join (Resources
        | where type =~ 'microsoft.network/networkinterfaces'
        | mv-expand ipconfig=properties.ipConfigurations
        | project vmId = tolower(tostring(properties.virtualMachine.id)), privateIp = ipconfig.properties.privateIPAddress, publicIpId = tostring(ipconfig.properties.publicIPAddress.id)
        | join kind=leftouter (Resources
            | where type =~ 'microsoft.network/publicipaddresses'
            | project publicIpId = id, publicIp = properties.ipAddress
        ) on publicIpId
        | project-away publicIpId, publicIpId1
        | summarize privateIps = make_list(privateIp), publicIps = make_list(publicIp) by vmId
    ) on vmId
    | project-away vmId1
    | sort by vmName asc
"@
        [VmIpMap]::vms = Search-AzGraph -Query $query
    }

    [PSCustomObject] GetVmByIpAddress($ipAddress) {
        foreach ($vm in [VmIpMap]::vms) {
            if ($vm.privateIps -contains $ipAddress) {
                return $vm
            }
        }
        return $null
    }
}

class TestResult {
    [string] $SourceAddress
    [int] $SourcePort
    [string] $DestinationAddress
    [int] $DestinationPort
    [string] $ConnectionStatus
    [int] $AvgLatencyInMs
    [int] $MinLatencyInMs
    [int] $MaxLatencyInMs
    [int] $ProbesSent
    [int] $ProbesFailed
    [array] $Hops
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
        [Parameter(ParameterSetName = "IPandMask", Mandatory = $true)]
        [ValidateScript( { $_ -match [ipaddress]$_ })]
        [System.String] $IPAddress,

        [Parameter(ParameterSetName = "IPandMask", Mandatory = $true)]
        [ValidateScript( { $_ -match [ipaddress]$_ })]
        [System.String] $SubnetMask,

        [Parameter(ParameterSetName = "CIDR", Mandatory = $true)]
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
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "IPAddress"         -Value $IPAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "SubnetMask"        -Value $SubnetMask
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "NetworkAddress"    -Value $NetworkAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "BroadcastAddress"  -Value $BroadcastAddress
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "WildcardMask"      -Value $WildcardMask
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "NumberOfHostIPs"   -Value $NumberOfHosts
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "HostMinIp"         -Value $HostMinIP
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "HostMaxIp"         -Value $HostMaxIP
    Add-Member -InputObject $obj -MemberType NoteProperty -Name "IPRange"           -Value $IPRange

    # Return the object
    return $obj
}

#####################################################################
function GetIpInRange {

    Param(
        [parameter(Mandatory = $true)]
        [ValidatePattern("\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")]
        [string] $StartIpAddress,

        [parameter()]
        [ValidatePattern("\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")]
        [string] $EndIpAddress = $StartIPAddress
    )

    $ipSet = @()

    $startOctets = $StartIpAddress.Split(".")
    $endOctets = $EndIpAddress.Split(".")

    if ($startOctets[0] -ne $endOctets[0]) {
        Write-Error 'Too large an IP range. Please break into smaller ranges'
        return
    }

    $startOctet1 = $startOctets[0]
    $startOctet2 = $startOctets[1]
    $startOctet3 = $startOctets[2]
    $startOctet4 = $startOctets[3]

    $endOctet1 = $endOctets[0]
    $endOctet2 = $endOctets[1]
    $endOctet3 = $endOctets[2]
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

    if ($ipAddressRange -match '\b(?:\d{1,3}\.){3}\d{1,3}\b') {
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

        } else {
            $ipSet = $IpAddressRange.Split(';')
        }
    }
    else {
        $ipSet = $IpAddressRange.Split(';')
    }

    return $ipSet

}

############################################################################

Set-StrictMode -Version Latest

$vmMap = [VmIpMap]::New()
$testCases = @()
$testResults = @()

# validate parameters
if (-not ($FilePath -or $DestinationAddresses)) {
    Write-Error 'Either -FilePath ore -ToIpAddresses must be supplied.'
    return
}

# build test cases from command line
if ($DestinationAddresses) {
    foreach ($IpAddress in $DestinationAddresses) {
        $ipSet = ParseIpAddressRange -IpAddressRange $IpAddress

        foreach ($ip in $ipSet) {
            foreach ($port in $DestinationPorts) {
                $testCase = [TestCase]::New()
                $testCase.SourceAddress = $SourceAddress
                $testCase.SourcePort = $SourcePort
                $testCase.DestinationAddress = $ip
                $testCase.DestinationPort = $port
                $testCase.SourceId = $vmMap.FindVM($SourceAddress)

                $testCases += $testCase
            }
        }
    }
}

# build test cases from file
if ($FilePath) {
     $testFile = Import-Csv -Path $FilePath -Delimiter ','

    $portsIncluded = $false
    if ($testFile | Get-member -MemberType 'NoteProperty' | Where-Object { $_.Name -eq 'DestinationPort' }) {
        $portsIncluded = $true
    }

    # buuld test cases
    foreach ($row in $testFile) {
        # port settings
        $ports = @()
        if ($portsIncluded -and ($row.DestinationPort.Trim().Length -gt 0)) {
            $ports = $row.DestinationPort.Split(';')
        }
        else {
            $ports = $DestinationPorts
        }

        # ipAddresses
        $ipSet = ParseIpAddressRange -IpAddressRange $row.DestinationAddress

        # get VM
        $vm = $vmMap.GetVmByIpAddress($row.SourceAddress)

        foreach ($ip in $ipSet) {
            foreach ($port in $ports) {
                if (-not $vm) {
                    $testResult = [TestResult]::New()
                    $testResult.SourceAddress = $row.SourceAddress
                    $testResult.SourcePort = $row.SourcePort
                    $testResult.DestinationAddress = $ip
                    $testResult.DestinationPort = $port
                    $testResult.ConnectionStatus = "IP Address not found"
        
                    $testResults += $testResult
                    Write-Host "IP address not found - SourceAddress:$($row.SourceAddress)" -ForegroundColor Yellow
                    continue
                }
        
                if ($vm.powerState -ne 'VM running') {
                    $testResult = [TestResult]::New()
                    $testResult.SourceAddress = $row.SourceAddress
                    $testResult.SourcePort = $row.SourcePort
                    $testResult.DestinationAddress = $ip
                    $testResult.DestinationPort = $port
                    $testResult.ConnectionStatus = $vm.powerState
        
                    $testResults += $testResult
                    Write-Host "VM not running - SourceAddress:$($row.SourceAddress)" -ForegroundColor Yellow
                    continue
                }
        
                $testCase = [TestCase]::New()
                $testCase.SourceAddress = $row.SourceAddress
                $testCase.SourcePort = $row.SourcePort
                $testCase.DestinationAddress = $ip
                $testCase.DestinationPort = $port
                $testCase.SourceId = $vm.vmId

                $testCases += $testCase
            }
        }
    }
}

# submit jobs 
$jobIds =  [System.Collections.ArrayList] @()
foreach ($testCase in $testCases) {
    # correct for a bug in Test-AzNetworkWatcherConnectivity when testing against a VirtualMachine that is stopped
    $testCase.SourceId = $testCase.SourceId.Replace('/virtualmachines/', '/virtualMachines/')

    $job = Test-AzNetworkWatcherConnectivity -ResourceGroupName $ResourceGroupName -NetworkWatcherName $NetworkWatcherName `
        -SourceId $testCase.SourceId -SourcePort $testCase.SourcePort `
        -DestinationAddress $testCase.DestinationAddress -DestinationPort $testCase.DestinationPort `
        -AsJob
    $testCase.JobId = $job.Id

    $null = $jobIds.Add($job.Id)
    Write-Verbose "Submitted - Source:$($testCase.SourceAddress):$($testCase.SourcePort) Destination:$($testCase.DestinationAddress):$($testCase.DestinationPort) JobId:$($testCase.JobId)"
}

# get job results
do {
    try {
        $jobs = Wait-Job -Id $jobIds -Any -Timeout 15 
        if (-not $jobs) {
            Write-Verbose "Waiting on $($jobIds.Count) job(s) to complete..."
            continue
        }    
    } catch {
        throw $_
        break
    }

    foreach ($job in $jobs) {
        # find original test case
        $testCase = $testCases | Where-Object {$_.JobId -eq $job.Id}

        $testResult = [TestResult]::New()
        $testResult.SourceAddress = $testCase.SourceAddress
        $testResult.SourcePort = $testCase.SourcePort
        $testResult.DestinationAddress = $testCase.DestinationAddress
        $testResult.DestinationPort = $testCase.DestinationPort

        if ($job.State -eq 'Completed') {
            Write-Verbose "Completed - JobId:$($job.Id) Source:$($testResult.SourceAddress):$($testResult.SourcePort) Destination:$($testResult.DestinationAddress):$($testResult.DestinationPort)"
            $result = $job | Receive-Job

            $testResult.ConnectionStatus = $result.ConnectionStatus
            $testResult.AvgLatencyInMs = $result.AvgLatencyInMs
            $testResult.MinLatencyInMs = $result.MinLatencyInMs
            $testResult.MaxLatencyInMs = $result.MaxLatencyInMs
            $testResult.ProbesSent = $result.ProbesSent
            $testResult.ProbesFailed = $result.ProbesFailed   
            $testResult.Hops = $result.Hops | ConvertTo-Json -Depth 5 | ConvertFrom-Json
            $job | Remove-Job
        } else {
            $testResult.ConnectionStatus = "Job $($job.State)"
            Write-Host "Failed - Job $($job.Id) state $($job.State). Source:$($testResult.SourceAddress):$($testResult.SourcePort) Destination:$($testResult.DestinationAddress):$($testResult.DestinationPort). Job left in queue." -ForegroundColor Red
        }
       
        $testResults += $testResult
        $jobIds.Remove($job.Id)
    }

} until ($jobIds.Count -eq 0)

$testResults