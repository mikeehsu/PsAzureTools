
Param(
    [Parameter(Mandatory=$true)]
    [string] $FilePath,

    [Parameter(Mandatory=$false)]
    [string] $OutputPath
)


Set-StrictMode -Version Latest

Class TestEvaluation {
    [string] $IpAddress
    [string] $TcpResult
    [string] $TcpFailures
    [string] $PingResult
}

###########################################################################
function TestConnection {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $IPAddress,

        [Parameter(Mandatory = $false)]
        [bool] $Ping = $true,

        [Parameter(Mandatory = $false)]
        [int[]] $Ports = @(),

        [Parameter(Mandatory = $false)]
        [int] $Timeout = 200
    )

    Write-Verbose "$IPAddress testing connection"
    Write-Progress -Activity "Now testing $IPAddress..."

    $pingResult = $null
    if ($Ping) {
        $pingResult = $false

        $pingObj = New-Object System.Net.Networkinformation.Ping
        $pingStatus = $pingObj.Send($IPAddress, $TimeOut)

        if ($pingStatus.Status -eq 'Success') {
            $pingResult = $true
        }
    }

    $openPorts = @()
    for ($i = 1; $i -le $ports.Count; $i++) {
        $port = $Ports[($i - 1)]
        $client = New-Object System.Net.Sockets.TcpClient
        $null = $client.BeginConnect($IPAddress, $port, $null, $null)
        if ($client.Connected) {
            $openPorts += $port

        } else {
            # Wait
            Start-Sleep -Milli $TimeOut
            if ($client.Connected) {
                $openPorts += $port
            }
        }
        $client.Close()
    }

    # Return Object
    $result = New-Object PSObject -Property @{
        IpAddress = $IPAddress;
        Ping      = $pingResult;
        Ports     = $openPorts
    }

    return $result
}

#####################################################################
function TestIpRange {

    Param(
        [parameter(Mandatory=$true)]
        [ValidatePattern("\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")]
        [string] $StartIpAddress,

        [parameter(Mandatory=$false)]
        [ValidatePattern("\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b")]
        [string] $EndIpAddress = $StartIPAddress,

        [parameter(Mandatory=$false)]
        [int[]] $Ports = @(80,443,3389),

        [parameter(Mandatory=$false)]
        [bool] $Ping = $true
    )

    $result = @()

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
                    $ipAddress = "$a.$b.$c.$d"
                    $result += TestConnection -IPAddress $ipAddress -Ports $Ports -Ping $Ping
                }
            }
        }
    }

    return $result
}


#####################################################################
function TestIpSet {

    Param(
        [parameter(Mandatory=$true)]
        [array] $ipSet,

        [parameter(Mandatory=$false)]
        [int[]] $Ports = @(80,443,3389),

        [parameter(Mandatory=$false)]
        [bool] $Ping = $true
    )

    $result = @()

    foreach ($ipAddress in $ipSet) {
        $result += TestConnection -IPAddress $ipAddress -Ports $Ports -Ping $Ping
    }
    return $result
}

############################################################################

$report = @()

$tests = Import-Csv -Path $FilePath -Delimiter ','

foreach ($test in $tests) {
    # tcp settings
    $portsExpected = @()
    if ($test.PortsExpected.Trim().Length -gt 0) {
        $portsExpected = $test.PortsExpected.Split(';')
    }

    # ping settings
    if ($test.PingTest) {
        $pingTest = $test.PingTest.StartsWith('Y')
    }

    if ($test.PingExpected) {
        $pingExpected = $test.PingExpected.StartsWith('Y')
    }

    if ($test.IpAddress -like '*-*') {
        $ipRange = $test.IpAddress.Split('-')

        $startIp = $ipRange[0]
        if ($ipRange.Length -eq 1) {
            $endIp = $startIp
        } else {
            $endIp = $ipRange[1]
        }

        $testResults = TestIpRange -StartIpAddress $startIp -EndIpAddress $endIp -Ports $test.PortsToTest.Split(';') -Ping $pingTest
    } else {
        $ipSet = $test.IpAddress.Split(';')
        $testResults = TestIpSet -IpSet $ipSet -Ports $test.PortsToTest.Split(';') -Ping $pingTest
    }

    foreach($testResult in $testResults) {
        $portCompare = Compare-Object $testResult.Ports $portsExpected | Select-Object InputObject

        $testEval = [TestEvaluation]::New()
        $testEval.IpAddress = $testResult.IpAddress

        $testEval.TcpResult = 'fail'
        if ($portCompare) {
            $testEval.TcpFailures = $portCompare.InputObject -Join ':'
        } else {
            $testEval.TcpResult = 'pass'
        }

        $testEval.PingResult = 'fail'
        if ($test.pingTest -and $pingExpected -eq $testResult.ping) {
            $testEval.PingResult = 'pass'
        }

        $report += $testEval
    }
}

$report

if ($OutputPath) {
    $report | Export-Csv $OutputPath
}

