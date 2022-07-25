<#
.SYNOPSIS
Write to a Custom Log to Azure LogAnalyzics workspace

.DESCRIPTION
Write a custom log entry to an Azure LogAnalyzics workspace

.PARAMETER ResourceGroupName
Resource Group Name of the Workspace

.PARAMETER WorkspaceName
Workspace Name of the Workspace

.PARAMETER LogType
LogType of entries

.PARAMETER LogEntry
LogEntry in JSON format to write to the workspace

.PARAMETER TimeStampField
Field in LogEntry to use as the TimeStamp of the event. If not specified, the current time will be used.

.EXAMPLE
Write-LogAnalytics.ps1 -ResourceGroupName MyResourceGroup -WorkspaceName MyWorkspace -LogType MyLogType -LogEntry '{"MyField":"MyValue"}'

.NOTES
#>

[cmdletbinding()]
param(
    [parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Alias("Name")]
    [parameter(Mandatory)]
    [string] $WorkspaceName,

    [parameter(Mandatory)]
    [string] $LogType,

    [parameter(Mandatory)]
    [string] $LogEntry,

    [parameter()]
    [string] $TimeStampField
)
# Create the function to create the authorization signature
Function BuildSignature ()
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $CustomerId,

        [Parameter()]
        [string] $SharedKey,

        [Parameter(Mandatory)]
        [string] $Date,

        [Parameter(Mandatory)]
        [string] $ContentLength,

        [Parameter(Mandatory)]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $ContentType

        [Parameter(Mandatory)]
        [string] $Resource
    )

    $xHeaders = "x-ms-date:" + $Date
    $stringToHash = $Method + "`n" + $ContentLength + "`n" + $ContentType + "`n" + $xHeaders + "`n" + $Resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($SharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $CustomerId, $encodedHash

    return $authorization
}

# Create the function to create and post the request
function PostLogAnalyticsData()
{

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $CustomerId,

        [Parameter(Mandatory)]
        [string] $SharedKey,

        [Parameter(Mandatory)]
        [string] $LogType,

        [Parameter(Mandatory)]
        [string] $LogEntry
)
    $body = ([System.Text.Encoding]::UTF8.GetBytes($LogEntry))

    $method = 'POST'
    $contentType = 'application/json'
    $rfc1123date = [DateTime]::UtcNow.ToString('r')
    $contentLength = $body.Length

    $signature = BuildSignature `
        -CustomerId $CustomerId `
        -SharedKey $SharedKey `
        -Date $rfc1123date `
        -ContentLength $contentLength `

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

        $context = Get-AzContext
    switch ($context.Environment) {
        'AzureChina' {
            $endpointSuffix = 'ods.opinsights.azure.cn'
            break
        }
        'AzureCloud' {
            $endpointSuffix = 'ods.opinsights.azure.com'
            break
        }
        'AzureUSGovernment' {
            $endpointSuffix = 'ods.opinsights.azure.us'
            break
        }
    }

    $uri = "https://" + $CustomerId + $endpointSuffix + '/api/logs' + "?api-version=2016-04-01"


    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode
}

Set-StrictMode -Version 3

# check session to make sure if it connected
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        throw"Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }

}
catch {
    throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
    return
}

$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName

$CustomerId = $workspace.CustomerId.Guid
$SharedKey = ($workspace | Get-AzOperationalInsightsWorkspaceSharedKey).PrimarySharedKey

# Submit the data to the API endpoint
PostLogAnalyticsData -CustomerId $customerId -SharedKey $sharedKey -LogEntry $LogEntry -LogType $LogType