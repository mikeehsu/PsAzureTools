<#
.SYNOPSIS
Convert/Combine log files into a single CSV file.

.DESCRIPTION
Convert and combine selected JSON log files in an Azure Storage Account into a single CSV file.

.PARAMETER ResourceGroupName
Resource Group Name of the storage account where the log files reside

.PARAMETER StorageAccountName
Storage Account Name containing the log files

.PARAMETER ContainerName
Container Name of the storage container that contains the log files

.PARAMETER BeginDate
Begin Date of the log files to combine. The log files must have a datestamp in the format YYYY-MM-DD or be in the y=YYYY/m=MM/d=MM format. If not provided, all files prior to and on -EndDate will be processed.

.PARAMETER EndDate
End Date of the log files to combine. The log files must have a datestamp in the format YYYY-MM-DD or be in the y=YYYY/m=MM/d=MM format. If not provided, all files on and after -BeginDate will be processed.

.PARAMETER Property
Properties that should be output to the CSV. You can list several property as an array. If there are nested JSON properties that need to be broken out, you can specify the individual properties using <topLevelObject>.<property>. If not provided all properties will be combined into the CSV.

.EXAMPLE
.\Convert-LogsToCsv.ps1 -ResourceGroupName MyRg -StorageAccountName mystorageacct -ContainerName 'insights-logs-signinlogs' -OutputPath output.csv -BeginDate '5/10/2020' -enddate '5/11/2020' -Property time,properties.userDisplayName

.NOTES

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [Alias('Name')]
    [string] $StorageAccountName,

    [Parameter(Mandatory)]
    [string] $ContainerName,

    [Parameter(Mandatory)]
    [string] $IpAddress,

    [Parameter()]
    [datetime] $BeginDate,

    [Parameter()]
    [datetime] $EndDate,

    [Parameter()]
    [array] $Property
)

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

$tempFile = New-TemporaryFile

$ErrorActionPreference = "Stop"

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName

$blobs = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -MaxCount 100

if ($blobs.Name -match '[0-9]{4}-[0-9]{2}-[0-9]{2}') {
    $dateRegExp = '[0-9]{4}-[0-9]{2}-[0-9]{2}'
    $dateFormat = '{0:d4}-{1:d2}-{2:d2}'

}
elseif ($blobs.Name -match '\/y\=[0-9]{4}\/m\=[0-9]{2}\/d\=[0-9]{2}') {
    $dateRegExp = '\/y\=[0-9]{4}\/m\=[0-9]{2}\/d\=[0-9]{2}\/'
    $dateFormat = '/y={0:d4}/m={1:d2}/d={2:d2}/'

}
else {
    Write-Host 'Date format not supported.'
    return
}

# define date filter for log files
$beginStr = $null
$endStr = $null
if ($BeginDate) {
    $beginStr = $dateFormat -f $BeginDate.Year, $BeginDate.Month, $BeginDate.Day
}

if ($EndDate) {
    $endStr = $dateFormat -f $EndDate.Year, $EndDate.Month, $EndDate.Day
}

# loop through files that match date range
class TupleClass {
    [datetime] $timestamp
    [double] $unixTimestamp
    [int] $order
    [string] $sourceIp
    [string] $destinationIp
    [int] $sourcePort
    [int] $destinationPort
    [string] $protocol
    [string] $trafficFlow
    [string] $trafficDecision
}

$tupleList = [System.Collections.ArrayList]::New()
$order = 0

$blobs = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Verbose:$false | Where-Object { $_.Name -match $dateRegExp } | Sort-Object -Property Name

foreach ($blob in $blobs) {
    if ((-not $beginStr -or $datePortion -ge $beginStr) -and
        (-not $endStr -or $datePortion -le $endStr)) {

        # Write-Host $blob.name
        try {
            $null = $blob | Get-AzStorageBlobContent -Destination $tempFile -Force
        } catch {
            try {
                $tempFile = New-TemporaryFile
                $null = $blob | Get-AzStorageBlobContent -Destination $tempFile -Force
            } catch {
                throw $_
            }
        }

        # Write-Progress -Activity "Processing $storageAccountName/$ContainerName" -Status $blob.Name

        $data = Get-Content $tempFile | ConvertFrom-Json
        foreach ($row in $data.records.properties.flows.flows.flowTuples) {
            if ($row -like "*$ipAddress*") {
                $order = $order + 1
                $tuple = [TupleClass]::New()
                $tuple.unixTimestamp, $tuple.sourceIp, $tuple.destinationIp, $tuple.sourcePort, $tuple.destinationPort, $tuple.protocol, $tuple.trafficFlow, $tuple.trafficDecision = $row -split ','
                $tuple.timestamp =  (Get-Date 01.01.1970)+([System.TimeSpan]::fromseconds($tuple.unixtimestamp))
                $tuple.order = $order
                $null = $tupleList.Add($tuple)
            }
        }
    }
}

$tupleList
