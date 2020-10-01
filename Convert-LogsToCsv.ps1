[CmdletBinding()]
param (
    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [Alias('Name')]
    [string] $StorageAccountName,

    [Parameter()]
    [string] $ContainerName,

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [datetime] $BeginDate,

    [Parameter()]
    [datetime] $EndDate
)

$BatchSize = 1000

# confirm user is logged into subscription
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

$ErrorActionPreference = "Stop"

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName

$blobs = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -MaxCount 100

if ($blobs.Name -match '[0-9]{4}-[0-9]{2}-[0-9]{2}') {
    $dateRegExp = '[0-9]{4}-[0-9]{2}-[0-9]{2}'
    $dateFormat = '{0:d4}-{1:d2}-{2:d2}'

} elseif ($blobs.Name -match '\/y\=[0-9]{4}\/m\=[0-9]{2}\/d\=[0-9]{2}') {
    $dateRegExp = '\/y\=[0-9]{4}\/m\=[0-9]{2}\/d\=[0-9]{2}\/'
    $dateFormat = '/y={0:d4}/m={1:d2}/d={2:d2}/'

} else {
    Write-Host 'Date format not supported.'
    return
}

# define date filter for log files
$beginStr = $null
$endStr = $null
if ($BeginDate) {
    $beginStr = $dateFormat -f $BeginDate.Year,$BeginDate.Month,$BeginDate.Day
}

if ($EndDate) {
    $endStr = $dateFormat -f $EndDate.Year,$EndDate.Month,$EndDate.Day
}

# delete any existing output file
$tempFile = New-TemporaryFile
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Force
}

$rowCount = 0
$outputCache = @()

# loop through files that match date range

Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Verbose:$false
| Where-Object {$_.Name -match $dateRegExp}
| ForEach-Object {
    $datePortion = $matches[0]
    $blob = $_

    if ((-not $beginStr -or $datePortion -ge $beginStr) -and
        (-not $endStr -or $datePortion -le $endStr)) {

        $null = $blob | Get-AzStorageBlobContent -Destination $tempFile -Force

        Get-Content $tempFile
        | ConvertFrom-Json
        | ForEach-Object {
            $data = $_

            $result =  [PSCustomObject] @{
                time = $data.time
                resourceId = $data.resourceId
                operationName = $data.operationName
                category = $data.category
                tenantId = $data.tenantId
                resultType = $data.resultType
                resultDescription = $data.resultDescription
                durationMs = $data.durationMs
                callerIpAddress = $data.callerIpAddress
                identity = $data.identity
                createdDateTime = $data.properties.createdDateTime
                userDisplayName = $data.properties.userDisplayName
                userPrincipalName = $data.properties.userPrincipalName
                userId = $data.properties.userId
                appId = $data.properties.appId
                appDisplayName = $data.properties.appDisplayName
                errorCode = $data.properties.status.errorcode
                additionalDetails = $data.properties.status.additionalDetails
                city = $data.properties.location.city
                state = $data.properties.location.state
                countryOrRegion = $data.properties.location.countryOrRegion
                mfaAuthMethod = $data.properties.mfaDetail.authMethod
                tokenIssuerType = $data.properties.tokenIssuerType
                resourceDisplayName = $data.properties.resourceDisplayName
                alternateSignInName = $data.properties.alternateSignInName
            }

            $rowCount++
            if ($rowCount -eq 1) {
                $outputCache += $result | ConvertTo-Csv
            } else {
                $outputCache += ($result | ConvertTo-Csv)[1]
            }
        }

        # flush the output cache
        if (($rowCount % $BatchSize) -eq 0) {
            $outputCache | Out-File -FilePath $OutputPath -Append
            $outputCache.Clear()
        }
    }
}

$outputCache | Out-File -FilePath $OutputPath -Append
$outputCache.Clear()





