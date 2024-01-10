<#
.SYNOPSIS
    A script to copy an Azure Data Factory (ADF) pipeline.

.DESCRIPTION
    This script, Copy-ADFPipeline.ps1, is used to copy an Azure Data Factory (ADF) pipeline from a source to a destination.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure account.

.PARAMETER SourceResourceGroupName
    The name of the resource group in the source Azure account where the ADF pipeline is located.

.PARAMETER SourceADFName
    The name of the source Azure Data Factory.

.PARAMETER SourcePipelineName
    The name of the pipeline in the source Azure Data Factory.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure account.

.PARAMETER DestinationResourceGroupName
    The name of the resource group in the destination Azure account where the ADF pipeline will be copied to.

.PARAMETER DestinationADFName
    The name of the destination Azure Data Factory.

.PARAMETER DestinationPipelineName
    The name of the pipeline in the destination Azure Data Factory. If not specified, the name of the source pipeline will be used.

.PARAMETER Suffix
    An optional suffix to append to the name of the copied pipeline.

.EXAMPLE
    .\Copy-ADFPipeline.ps1 -SourceSubscriptionId <value> -SourceResourceGroupName <value> -SourceADFName <value> -SourcePipelineName <value> -DestinationSubscriptionId <value> -DestinationResourceGroupName <value> -DestinationADFName <value> -DestinationPipelineName <value> -Suffix <value>
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
    [string] $SourcePipelineName,

    [Parameter()]
    [string] $DestinationSubscriptionId,

    [Parameter(Mandatory)]
    [string] $DestinationResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestinationADFName,

    [Parameter()]
    [string] $DestinationPipelineName,

    [Parameter()]
    [string] $Suffix = ''
)

function Get-ADFPipelineDetail
{
    param (
        [Parameter(Mandatory)]
        [string] $subscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ADFName,

        [Parameter(Mandatory)]
        [string] $PipelineName
    )

    $param = @{
        SubscriptionId = $subscriptionId
        ResourceGroupName = $ResourceGroupName
        ResourceProviderName = "Microsoft.DataFactory"
        ResourceType = "factories"
        Name = "$ADFName/pipelines/$PipelineName"
        ApiVersion = "2018-06-01"
    }

    $results = Invoke-AzRestMethod @param -Method GET
    if ($results.StatusCode -ne 200) {
        Write-Host
        Write-Error "Failed getting pipeline: $($results.Content)"
        return $null
    }

    return ($results.Content | ConvertFrom-Json)
}

function New-ADFPipeline
{
    param (
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ADFName,

        [Parameter(Mandatory)]
        [string] $PipelineName,

        [Parameter(Mandatory)]
        [string] $PropertiesJson
    )

    $param = @{
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        ResourceProviderName = "Microsoft.DataFactory"
        ResourceType = "factories"
        Name = "$ADFName/pipelines/$PipelineName"
        ApiVersion = "2018-06-01"
        Payload = $PropertiesJson
    }
    # Write-Host "Creating linked service: $($param | ConvertTo-Json -Depth 10)"

    $results = Invoke-AzRestMethod @param -Method PUT
    if ($results.StatusCode -ne 200) {
        Write-Host
        Write-Error "Failed creating pipeline: $($results.Content)"
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
$sourcePipelines = $sourceDataFactory | Get-AzDataFactoryV2Pipeline

# if $PipelineName is specified, filter down to just that pipeline
if ($SourcePipelineName) {
    $sourcePipelines = $sourcePipelines | Where-Object { $_.Name -eq $SourcePipelineName }
    if (-not $sourcePipelines) {
        Write-Error "Pipeline '$SourcePipelineName' not found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
        return
    }
}

# check to make sure we have pipelines to copy
if (-not $sourcePipelines) {
    Write-Error "No pipelines found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
    return
}

$sourcePipelines = $sourcePipelines | Sort-Object -Property Name

# loop through and copy all pipelines identified
$completeCount = 0
$successCount = 0
$failedCount = 0
$failedNames = @()
foreach ($pipeline in $sourcePipelines) {
    Write-Progress -Activity "Copy pipelines" -Status "$completeCount of $($sourcePipelines.Count)" -PercentComplete ($completeCount / $sourcePipelines.Count * 100)
    Write-Host "$($pipeline.Name)...working" -NoNewline

    # build name for destination pipeline
    $pipelineName = $DestinationPipelineName
    if (-not $pipelineName) {
        $pipelineName = $pipeline.Name
    }
    $pipelineName = $pipelineName + $Suffix

    # get details of pipeline
    $pipelineDetails = Get-ADFPipelineDetail -SubscriptionId $SourceSubscriptionId -ResourceGroupName $SourceResourceGroupName -ADFName $SourceADFName -Pipeline $pipeline.Name
    if (-not $pipelineDetails) {
        $failedCount++
        $failedNames += $pipeline.Name

        Write-Host "`r$($pipeline.Name)...FAILED"
        Write-Error "Pipeline '$SourcePipelineName' not found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
        return
    }

    # create JSON for new pipeline
    $newPipelineJson = @{ properties = ($pipelineDetails.properties) } | ConvertTo-Json -Depth 10

    # create new pipeline
    $newPipeline = New-ADFPipeline -SubscriptionId $DestinationSubscriptionId -ResourceGroupName $DestinationResourceGroupName -ADFName $DestinationADFName -PipelineName $pipelineName -PropertiesJson $newPipelineJson
    if (-not $newPipeline) {
        $failedCount++
        $failedNames += $dataset.Name

        Write-Host "`r$($pipeline.Name)...FAILED"
        Write-Error "Failed to create pipeline '$pipelineName' in destination data factory ($DestinationResourceGroupName/$DestinationADFName)."
    } else {
        $successCount++
        Write-Host "`r$pipelineName...created"
    }

    $completeCount++
}

Write-Host "$completeCount pipelines created/updated."
Write-Host "$failedCount pipeline copy failed."

if ($failedCount -gt 0) {
    Write-Host "Failed datasets: $($failedNames -join ', ')"
}
