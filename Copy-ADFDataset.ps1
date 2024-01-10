<#
.SYNOPSIS
    A script to copy an Azure Data Factory (ADF) dataset.

.DESCRIPTION
    This script, Copy-ADFDataset.ps1, is used to copy an Azure Data Factory (ADF) dataset from a source to a destination.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure account.

.PARAMETER SourceResourceGroupName
    The name of the resource group in the source Azure account where the ADF dataset is located.

.PARAMETER SourceADFName
    The name of the source Azure Data Factory.

.PARAMETER SourceDatasetName
    The name of the dataset in the source Azure Data Factory.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure account.

.PARAMETER DestinationResourceGroupName
    The name of the resource group in the destination Azure account where the ADF dataset will be copied to.

.PARAMETER DestinationADFName
    The name of the destination Azure Data Factory.

.PARAMETER DestinationDatasetName
    The name of the dataset in the destination Azure Data Factory.

.PARAMETER Suffix
    An optional suffix to append to the name of the copied dataset.

.EXAMPLE
    .\Copy-ADFDataset.ps1 -SourceSubscriptionId <value> -SourceResourceGroupName <value> -SourceADFName <value> -SourceDatasetName <value> -DestinationSubscriptionId <value> -DestinationResourceGroupName <value> -DestinationADFName <value> -DestinationDatasetName <value> -Suffix <value>
    Replace <value> with the appropriate value for each parameter.

.NOTES
    Additional information about the script goes here.

.AUTHOR
    Enter the author's name here.

#>

[CmdletBinding()]
param (
    [Parameter()]
    [string] $SourceSubscriptionId,

    [Parameter(Mandatory)]
    [string] $SourceResourceGroupName,

    [Parameter(Mandatory)]
    [string] $SourceADFName,

    [Parameter()]
    [string] $SourceDatasetName,

    [Parameter()]
    [string] $DestinationSubscriptionId,

    [Parameter(Mandatory)]
    [string] $DestinationResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestinationADFName,

    [Parameter()]
    [string] $DestinationDatasetName,

    [Parameter()]
    [string] $Suffix = ''
)

function Get-ADFDatasetDetail
{
    param (
        [Parameter(Mandatory)]
        [string] $subscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ADFName,

        [Parameter(Mandatory)]
        [string] $DatasetName
    )

    $param = @{
        SubscriptionId = $subscriptionId
        ResourceGroupName = $ResourceGroupName
        ResourceProviderName = "Microsoft.DataFactory"
        ResourceType = "factories"
        Name = "$ADFName/datasets/$DatasetName"
        ApiVersion = "2018-06-01"
    }

    $results = Invoke-AzRestMethod @param -Method GET
    if ($results.StatusCode -ne 200) {
        Write-Host
        Write-Error "Failed getting dataset: $($results.Content)"
        return $null
    }

    return ($results.Content | ConvertFrom-Json)
}

function New-ADFDataset
{
    param (
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ADFName,

        [Parameter(Mandatory)]
        [string] $DatasetName,

        [Parameter(Mandatory)]
        [string] $PropertiesJson
    )

    $param = @{
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        ResourceProviderName = "Microsoft.DataFactory"
        ResourceType = "factories"
        Name = "$ADFName/datasets/$DatasetName"
        ApiVersion = "2018-06-01"
        Payload = $PropertiesJson
    }
    # Write-Host "Creating linked service: $($param | ConvertTo-Json -Depth 10)"

    $results = Invoke-AzRestMethod @param -Method PUT
    if ($results.StatusCode -ne 200) {
        Write-Host
        Write-Error "Failed creating dataset: $($results.Content)"
        return $null
    }

    return ($results.Content | ConvertFrom-Json)
}

##
## MAIN
##

# check parameters
if (-not $SourceSubscriptionId) {
    $SourceSubscriptionId = (Get-AzContext).Subscription.Id
}

if (-not $DestinationSubscriptionId) {
    $DestinationSubscriptionId = $SourceSubscriptionId
}

if ($DestinationLinkedServiceName -and -not $SourceLinkedServiceName) {
    Write-Error "-SourceLinkedServiceName is required when -DestinationLinkedServiceName is specified."
    return
}

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        return
    }

}
catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    return
}


# double-check login to both source & destination subscriptions
$context = Set-AzContext -SubscriptionId $DestinationSubscriptionId -ErrorAction Stop
if (-not $context) {
    Write-Error "Failed to verify context for subscription '$DestinationSubscriptionId'."
    return
}

$context = Set-AzContext -SubscriptionId $SourceSubscriptionId -ErrorAction Stop
if (-not $context) {
    Write-Error "Failed to verify context for subscription '$SourceSubscriptionId'."
    return
}

$sourceDataFactory = Get-AzDataFactoryV2 -ResourceGroupName $SourceResourceGroupName -Name $SourceADFName
$sourceDatasets = $sourceDataFactory | Get-AzDataFactoryV2Dataset

# if $DatasetName is specified, filter down to just that dataset
if ($SourceDatasetName) {
    $sourceDatasets = $sourceDatasets | Where-Object { $_.Name -eq $SourceDatasetName }
    if (-not $sourceDatasets) {
        Write-Error "Dataset '$SourceDatasetName' not found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
        return
    }
}

# check to make sure we have datasets to copy
if (-not $sourceDatasets) {
    Write-Error "No datasets found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
    return
}

$sourceDatasets = $sourceDatasets | Sort-Object -Property Name

# loop through and copy all datasets identified
$completeCount = 0
$successCount = 0
$failedCount = 0
$failedNames = @()
foreach ($dataset in $sourceDatasets) {
    Write-Progress -Activity "Copy dDatasets" -Status "$completeCount of $($sourceDatasets.Count)" -PercentComplete ($completeCount / $sourceDatasets.Count * 100)
    Write-Host "$($dataset.Name)...working" -NoNewline

    # build name for destination dataset
    $datasetName = $DestinationDatasetName
    if (-not $datasetName) {
        $datasetName = $dataset.Name
    }
    $datasetName = $datasetName + $Suffix

    # get details of dataset
    $datasetDetails = Get-ADFDatasetDetail -SubscriptionId $SourceSubscriptionId -ResourceGroupName $SourceResourceGroupName -ADFName $SourceADFName -Dataset $dataset.Name
    if (-not $datasetDetails) {
        $failedCount++
        $failedNames += $dataset.Name

        Write-Host "`r$($dataset.Name)...FAILED"
        Write-Error "Dataset '$SourceDatasetName' not found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
        return
    }

    # create JSON for new dataset
    $newDatasetJson = @{ properties = ($datasetDetails.properties) } | ConvertTo-Json -Depth 10

    # create new dataset
    $newDataset = New-ADFDataset -SubscriptionId $DestinationSubscriptionId -ResourceGroupName $DestinationResourceGroupName -ADFName $DestinationADFName -DatasetName $datasetName -PropertiesJson $newDatasetJson
    if (-not $newDataset) {
        $failedCount++
        $failedNames += $dataset.Name

        Write-Host "`r$($dataset.Name)...FAILED"
        Write-Error "Failed to create dataset '$datasetName' in destination data factory ($DestinationResourceGroupName/$DestinationADFName)."
    } else {
        $successCount++
        Write-Host "`r$datasetName...created"
    }

    $completeCount++
}

Write-Host "$successCount datasets created/updated."
Write-Host "$failedCount dataset copy failed."

if ($failedCount -gt 0) {
    Write-Host "Failed Datasets: $($failedNames -join ', ')"
}