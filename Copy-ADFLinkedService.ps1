<#
.SYNOPSIS
    This script copies linked services from one Azure Data Factory to another.

.DESCRIPTION
    The script uses the Azure Data Factory REST API to copy linked services. It can be used to copy a single linked service or all linked services from the source Azure Data Factory.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure Data Factory. This is optional.

.PARAMETER SourceResourceGroupName
    The resource group name of the source Azure Data Factory. This is mandatory.

.PARAMETER SourceADFName
    The name of the source Azure Data Factory. This is mandatory.

.PARAMETER SourceLinkedServiceName
    The name of the linked service in the source Azure Data Factory to be copied. This is optional. If not supplied, all linked services will be copied.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure Data Factory. This is optional.

.PARAMETER DestinationResourceGroupName
    The resource group name of the destination Azure Data Factory. This is mandatory.

.PARAMETER DestinationADFName
    The name of the destination Azure Data Factory. This is mandatory.

.PARAMETER DestinationLinkedServiceName
    The name of the linked service in the destination Azure Data Factory. This is optional. This is only used when copying a single linked service.

.PARAMETER Suffix
    A suffix to append to the name of the copied linked service. This is optional.

.EXAMPLE
    .\Copy-ADFLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceADFName "sourceADF" -DestinationResourceGroupName "destinationRG" -DestinationADFName "destinationADF"

    This example copies all linked services from the source Azure Data Factory to the destination Azure Data Factory.

.EXAMPLE
    .\Copy-ADFLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceADFName "sourceADF" -SourceLinkedServiceName "sourceLS" -DestinationResourceGroupName "destinationRG" -DestinationADFName "destinationADF" -DestinationLinkedServiceName "destinationLS"

    This example copies a specific linked service from the source Azure Data Factory to the destination Azure Data Factory.

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
    [string] $SourceLinkedServiceName,

    [Parameter()]
    [string] $DestinationSubscriptionId,

    [Parameter(Mandatory)]
    [string] $DestinationResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestinationADFName,

    [Parameter()]
    [string] $DestinationLinkedServiceName,

    [Parameter()]
    [string] $Suffix = ''
)

function Get-ADFLinkedServiceDetail
{
    param (
        [Parameter(Mandatory)]
        [string] $subscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ADFName,

        [Parameter(Mandatory)]
        [string] $LinkedServiceName
    )

    $param = @{
        SubscriptionId = $subscriptionId
        ResourceGroupName = $ResourceGroupName
        ResourceProviderName = "Microsoft.DataFactory"
        ResourceType = "factories"
        Name = "$ADFName/linkedServices/$LinkedServiceName"
        ApiVersion = "2018-06-01"
    }

    $results = Invoke-AzRestMethod @param -Method GET
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to get linked service: $($results.Content)"
        return $null
    }

    return ($results.Content | ConvertFrom-Json)
}

function New-ADFLinkedService
{
    param (
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ADFName,

        [Parameter(Mandatory)]
        [string] $LinkedServiceName,

        [Parameter(Mandatory)]
        [string] $PropertiesJson
    )

    $param = @{
        SubscriptionId = $SubscriptionId
        ResourceGroupName = $ResourceGroupName
        ResourceProviderName = "Microsoft.DataFactory"
        ResourceType = "factories"
        Name = "$ADFName/linkedServices/$LinkedServiceName"
        ApiVersion = "2018-06-01"
        Payload = $PropertiesJson
    }
    # Write-Host "Creating linked service: $($param | ConvertTo-Json -Depth 10)"

    $results = Invoke-AzRestMethod @param -Method PUT
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create linked service: $($results.Content)"
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
$sourceLinkedServices = $sourceDataFactory | Get-AzDataFactoryV2LinkedService

# if $SourceLinkedServiceName is not specified, get all linked services
if ($SourceLinkedServiceName) {
    $sourceLinkedServices = $sourceLinkedServices | Where-Object { $_.Name -eq $SourceLinkedServiceName }
    if (-not $sourceLinkedServices) {
        Write-Error "Linked service '$SourceLinkedServiceName' not found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
        return
    }
}

if (-not $sourceLinkedServices) {
    Write-Error "No linked services found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
    return
}

foreach ($linkedService in $sourceLinkedServices) {
    Write-Host "Copying Linked Service: $($linkedService.Name)"
    $linkedServiceDetails = Get-ADFLinkedServiceDetail -SubscriptionId $SourceSubscriptionId -ResourceGroupName $SourceResourceGroupName -ADFName $SourceADFName -LinkedServiceName $linkedService.Name
    if (-not $linkedServiceDetails) {
        Write-Error "Linked service '$SourceLinkedServiceName' not found in source data factory ($SourceResourceGroupName/$sourceDataFactory)."
        return
    }

    # build name for destination linked service
    $linkedServiceName = $DestinationLinkedServiceName
    if (-not $linkedServiceName) {
        $linkedServiceName = $linkedService.Name
    }
    $linkedServiceName = $linkedServiceName + $Suffix

    # create JSON for new linked service
    $newServiceJson = @{ properties = ($linkedServiceDetails.Properties) } | ConvertTo-Json -Depth 10

    # create new linked service
    $newService = New-ADFLinkedService -SubscriptionId $DestinationSubscriptionId -ResourceGroupName $DestinationResourceGroupName -ADFName $DestinationADFName -LinkedServiceName $linkedServiceName -PropertiesJson $newServiceJson
    if (-not $newService) {
        Write-Error "Failed to create linked service '$linkedServiceName' in destination data factory ($DestinationResourceGroupName/$DestinationADFName)."
    }
    Write-Host "$($newService.Name) created."
}
