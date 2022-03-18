<#
.SYNOPSIS
Get Metrics for Virtual Machines directly from Microsoft.Insights

.PARAMETER Id
List of Virutal Machine Ids

.PARAMETER ResourceGroupName
Resource Group Name of Virutal Machine

.PARAMETER Name
Name of Virutal Machine

.PARAMETER StartTime
Start Time of Metrics

.PARAMETER EndTime
End Time of Metrics

.PARAMETER IntervalMinutes
Interval Minutes of Metrics

.PARAMETER MetricName
Name of Metric to retrieve

.PARAMETER Aggregation
Agregation of Metrics

.PARAMETER CsvFilePath
Path of CSV File to save metrics

.PARAMETER Delimiter
Delimiter of CSV File

.EXAMPLE
Get-VmMetrics.ps1 -Id [array] -StartTime [datetime] -EndTime [datetime] -IntervalMinutes [int] -MetricName [string] -Aggregation [string] -CsvFilePath [string]

.EXAMPLE
$vmList | Get-VmMetrics.ps1 -StartTime [datetime] -EndTime [datetime] -IntervalMinutes [int] -MetricName [string] -Aggregation [string] -CsvFilePath [string]

.EXAMPLE
Get-VmMetrics.ps1 -ResourceGroupName [string] -Name [string] -StartTime [datetime] -EndTime [datetime] -IntervalMinutes [int] -MetricName [string] -Aggregation [string] -CsvFilePath [string]

.NOTES

#>

[CmdletBinding()]
param (
    [Parameter(ParameterSetName='Id', Mandatory, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, HelpMessage='List of resource ids for virutal machines')]
    [string] $Id,

    [Parameter(ParameterSetName='Name', Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(ParameterSetName='Name', Mandatory)]
    [string] $Name,

    [Parameter(Mandatory)]
    [string] $StartTime,

    [Parameter(Mandatory)]
    [string] $EndTime,

    [Parameter()]
    [int] $IntervalMinutes = 30,

    [Parameter()]
    [ValidateSet('Percentage CPU','Network In','Network Out','Disk Read Bytes','Disk Write Bytes','Disk Read Operations/Sec','Disk Write Operations/Sec','CPU Credits Remaining','CPU Credits Consumed','Data Disk Read Bytes/sec','Data Disk Write Bytes/sec','Data Disk Read Operations/Sec','Data Disk Write Operations/Sec','Data Disk Queue Depth','Data Disk Bandwidth Consumed Percentage','Data Disk IOPS Consumed Percentage','Data Disk Target Bandwidth','Data Disk Target IOPS','Data Disk Max Burst Bandwidth','Data Disk Max Burst IOPS','Data Disk Used Burst BPS Credits Percentage','Data Disk Used Burst IO Credits Percentage','OS Disk Read Bytes/sec','OS Disk Write Bytes/sec','OS Disk Read Operations/Sec','OS Disk Write Operations/Sec','OS Disk Queue Depth','OS Disk Bandwidth Consumed Percentage','OS Disk IOPS Consumed Percentage','OS Disk Target Bandwidth','OS Disk Target IOPS','OS Disk Max Burst Bandwidth','OS Disk Max Burst IOPS','OS Disk Used Burst BPS Credits Percentage','OS Disk Used Burst IO Credits Percentage','Inbound Flows','Outbound Flows','Inbound Flows Maximum Creation Rate','Outbound Flows Maximum Creation Rate','Premium Data Disk Cache Read Hit','Premium Data Disk Cache Read Miss','Premium OS Disk Cache Read Hit','Premium OS Disk Cache Read Miss','VM Cached Bandwidth Consumed Percentage','VM Cached IOPS Consumed Percentage','VM Uncached Bandwidth Consumed Percentage','VM Uncached IOPS Consumed Percentage','Network In Total','Network Out Total','Available Memory Bytes')]
    [string] $MetricName = 'Percentage CPU',

    [Parameter()]
    [string] $Aggregation = 'Average',

    [Parameter()]
    [string] $CSVFilePath,

    [Parameter()]
    [string] $Delimiter = ','

)

BEGIN {
    # check for login
    $context = Get-AzContext
    if (-not $context) {
        Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Set-AzContext) context before proceeding.'
        return
    }

    $script:csvHeader = $false
}


PROCESS {

    # REGION function declarations
    function Get-Metric {
        [CmdletBinding()]
        param (
            [Parameter(ParameterSetName='Name', Mandatory)]
            [string] $SubscriptionId,

            [Parameter(ParameterSetName='Name', Mandatory)]
            [string] $ResourceGroupName,

            [Parameter(ParameterSetName='Name', Mandatory)]
            [string] $Name,

            [Parameter(ParameterSetName='Id', Mandatory)]
            [string] $Id,

            [Parameter(Mandatory)]
            [datetime] $StartTime,

            [Parameter(Mandatory)]
            [datetime] $EndTime,

            [Parameter()]
            [int] $IntervalMinutes = 30,

            [Parameter(Mandatory)]
            [string] $MetricName, #'Available Memory Bytes'


            [Parameter()]
            [string] $Aggregation = 'Average'
        )


        $apiVersion = '2019-07-01'

        $start = $StartTime.ToUniversalTime().ToString('o')
        $end = $EndTime.ToUniversalTime().ToString('o')

        # create VM resourceId
        if ($PsCmdlet.ParameterSetName -eq 'Id') {
            $uri = $Id
        }
        else {
            $uri = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$Name"
        }

        # build URL for metrics query
        $uri += "/providers/microsoft.Insights/metrics?api-version=$apiVersion"
        $uri += "&timespan=$start/$end"
        $uri += "&interval=PT$($IntervalMinutes)M"
        $uri += "&metricnames=$MetricName"
        $uri += "&aggregation=$Aggregation"
        $uri += '&metricNamespace=microsoft.compute%2Fvirtualmachines&autoadjusttimegrain=true&validatedimensions=false'

        try {
            $response = Invoke-AzRestMethod -Path $uri -ErrorAction Stop
        }
        catch [Exception] {
            # catch errors in the connection
            Write-Error $_.Exception.Message
            return
        }

        # catch errors passed into the API
        if ($response.StatusCode -ne 200) {
            Write-Error $response.Content
            return
        }

        return ($response.Content | ConvertFrom-Json)
    }
    # ENDREGION function declarations

    # get metrics
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Id') {
            $Name = Split-Path $Id -Leaf
            $vmMetrics = Get-Metric -Id $Id -StartTime $StartTime -EndTime $EndTime -IntervalMinutes $IntervalMinutes -MetricName $MetricName -Aggregation $Aggregation -ErrorAction Stop
        }
        else {
            $vmMetrics = Get-Metric -SubscriptionId $context.Subscription.Id -ResourceGroupName $ResourceGroupName -Name $Name -StartTime $StartTime -EndTime $EndTime -IntervalMinutes $IntervalMinutes -MetricName $MetricName -Aggregation $Aggregation -ErrorAction Stop
        }
    }
    catch [Exception] {
        Write-Error $_.Exception.Message
        return
    }

    # build CSV header
    if ($CSVFilePath) {
        if (-not $script:csvHeader) {
            $script:csvHeader = $true
            $text = 'VmName'
            foreach ($data in $vmMetrics.value.timeseries.data) {
                $text += $Delimiter + $data.timeStamp
            }
            $text | Out-File -FilePath $CSVFilePath -Encoding UTF8
        }

        # output CSV text
        $text = $Name
        foreach ($data in $vmMetrics.value.timeseries.data) {
            $text += $Delimiter + $data.average
        }
        $text | Out-File -FilePath $CSVFilePath -Encoding UTF8 -Append

    } else {
        $vmMetrics
    }
}

END {

}
