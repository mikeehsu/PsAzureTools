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
    [Parameter(Mandatory=$false)]
    [string[]] $IpAddresses,

    [Parameter(Mandatory=$false)]
    [int[]] $Ports,

    [Parameter(Mandatory=$false)]
    [switch] $Details,

    [Parameter(Mandatory=$false)]
    [string] $FilePath,

    [Parameter(Mandatory=$false)]
    [string] $OutputPath,

    [Parameter(Mandatory=$false)]
    [switch] $Continuous,

    [Parameter(Mandatory=$false)]
    [switch] $OnlyShowFailed,

    [Parameter(Mandatory=$false)]
    [int] $Frequency = 5,

    [Parameter(Mandatory=$false)]
    [int] $TimeOut = 500
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
function GetIpInRange {

    Param(
        [parameter(Mandatory=$true)]
        [ValidatePattern("\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")]
        [string] $StartIpAddress,

        [parameter(Mandatory=$false)]
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
            } else {
                $startOctet3 = 0
            }

            if ($b -eq $endOctet2) {
                $endOctet3 = $endOctets[2]
            } else {
                $endOctet3 = 255
            }

            foreach ($c in ($startOctet3..$endOctet3)) {
                if ($b -eq $startOctet2 -and $c -eq $startOctet3) {
                    $startOctet4 = $startOctets[3]
                } else {
                    $startOctet4 = 0
                }

                if ($b -eq $endOctet2 -and $c -eq $endOctet3) {
                    $endOctet4 = $endOctets[3]
                } else {
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

$report = @()
$testCases = @()

# validate parameters
if (-not $Ports) {
    $Ports = @(80)
}

if (-not ($FilePath -or $IpAddresses)) {
    Write-Error 'Either -FilePath ore -IpAddresses must be supplied.'
    return
}

if ($OutputPath -and $Continuous) {
    Write-Error '-Continuous and -OutputPath can not be used together, please remove one and try again.'
    return
}


# setup test cases
if ($IpAddresses) {
    foreach ($IpAddress in $IpAddresses) {
        if ($ipAddress -like '*-*') {
            $ipRange = $IpAddress.Split('-')
            $startIp = $ipRange[0]
            if ($ipRange.Length -eq 1) {
                $endIp = $startIp
            } else {
                $endIp = $ipRange[1]
            }
            $ipSet = GetIpInRange -StartIpAddress $startIp -EndIpAddress $endIp
        } else {
            $ipSet = @($ipAddress)
        }

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

    if ($testFile | Get-member -MemberType 'NoteProperty' | Where-Object {$_.Name -eq 'PortsToTest'}) {
        $portsToTestIncluded = $true
    }

    if ($testFile | Get-member -MemberType 'NoteProperty' | Where-Object {$_.Name -eq 'PortsExpected'}) {
        $portsExpectedIncluded = $true
    }

    # buuld test cases
    foreach ($test in $testFile) {
        # port settings
        $portsToTest = @()
        if ($portsToTestIncluded -and ($test.PortsToTest.Trim().Length -gt 0)) {
            $portsToTest = $test.PortsToTest.Split(';')
        } else {
            $portsToTest = $Ports
        }

        $portsExpected = @()
        if ($portsExpectedIncluded) {
            if ($test.PortsExpected.Trim().Length -gt 0) {
                $portsExpected = $test.PortsExpected.Split(';')
            }
        } else {
            $portsExpected = $portsToTest
        }

        # ipAddresses
        if ($test.IpAddress -like '*-*') {
            $ipRange = $test.IpAddress.Split('-')

            $startIp = $ipRange[0]
            if ($ipRange.Length -eq 1) {
                $endIp = $startIp
            } else {
                $endIp = $ipRange[1]
            }
            $ipSet = GetIpInRange -StartIpAddress $startIp -EndIpAddress $endIp

        } else {
            $ipSet = $test.IpAddress.Split(';')
        }

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
do  {

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

    # wait for results -- since we're doing in parallel, we don't need to wait this, but it's easier
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
        } else {
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
        $report = $testCases | Select-Object -Property Status,IpAddress,PortsFailed,PortsExpected,PortsOpen
    } else {
        $report = $testCases | Select-Object -Property Status,IpAddress,PortsFailed
    }

    if ($OnlyShowFailed) {
        $report = $report | Where-Object {$_.Status -eq 'FAILED'}
    }

    # display on screen
    if ($Continuous) {
        Clear-Host
        Write-Output "Current Time: $(Get-Date -UFormat '%Y-%m-%d %H:%M:%S')"
    }

    $report | Format-Table

    if ($Continuous) {
        Start-Sleep $Frequency
    }

} While ($Continuous)

if ($OutputPath) {
    $report | Export-Csv $OutputPath
}

