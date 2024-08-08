[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]
    $ResourceGroupName,

    [Parameter(Mandatory)]
    [string]
    $StorageAccountName,

    [Parameter()]
    [string]
    $ContainerName = 'insights-logs-ikediagnosticlog',

    [Parameter()]
    [datetime]
    $StartDate = [datetime]::Today.Date,

    [Parameter()]
    [datetime]
    $EndDate =  [datetime]::Today.Date,

    [Parameter(Mandatory)]
    [string]
    $OutputPath
)

class GatewayLog {
    [string] $resourceName
    [string] $category
    [string] $operationName
    [datetime] $timestamp
    [string] $level
    [string] $sessionId
    [string] $remoteIp
    [string] $remotePort
    [string] $localIp
    [string] $localPort
    [string] $message
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

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$container = $storageAccount | Get-AzStorageContainer -Name $ContainerName
$blobs = $container | Get-AzStorageBlob | Where-Object { $_.BlobProperties.CreatedOn -ge $StartDate -and $_.BlobProperties.CreatedOn -le $EndDate.AddDays(1).Date }

$tmpPath = New-TemporaryFile

$outputData = @()
foreach ($blob in $blobs) {
    Write-Host "Processing $($blob.Name)"
    $blobContent = $blob | Get-AzStorageBlobContent -Destination $tmpPath -Force
    if (-not $blobContent) {
        Write-Error $_
        continue
    }

    $file = Get-Content -Path $tmpPath
    foreach ($line in $file) {
        $rawData = $line | ConvertFrom-Json

        $parseData = New-Object -TypeName GatewayLog
        $parseData.resourceName = Split-Path -Path $rawData.resourceId -Leaf
        $parseData.operationName = $rawData.operationName
        $parseData.timestamp = [datetime] $rawData.time
        $parseData.level = $rawData.level
        $parseData.sessionId = [regex]::Match($rawData.properties.message, 'SESSION_ID :{([0-9a-fA-F-]+)}').Groups[1].Value
        $parseData.remoteIp, $parseData.remotePort = [regex]::Match($rawData.properties.message, 'Remote (\d{1,3}(?:\.\d{1,3}){3}:\d+)').Groups[1].Value -split ':'
        $parseData.localIp, $parseData.localPort = [regex]::Match($rawData.properties.message, 'Local (\d{1,3}(?:\.\d{1,3}){3}:\d+)').Groups[1].Value -split ':'

        if ($parseData.remoteIp) {
            $parseData.message = [regex]::Match($rawData.properties.message, 'Local (\d{1,3}(?:\.\d{1,3}){3}:\d+):\s*(.*)').Groups[2].Value
            # not a connection messages
        }
        else {
            $parseData.message = [regex]::Match($rawData.properties.message, 'SESSION_ID :{[0-9a-fA-F-]+}\s*(.*)').Groups[1].Value
        }

        $outputData += $parseData
    }
}
$outputData | Export-Csv -Path $OutputPath -NoTypeInformation
