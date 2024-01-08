<#
.SYNOPSIS
    This script copies linked services from one Azure Synapse workspace to another.

.DESCRIPTION
    The script uses the Azure Synapse REST API to copy linked services. It can be used to copy a single linked service or all linked services from the source Azure Synapse workspace.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure Synapse workspace. This is optional.

.PARAMETER SourceResourceGroupName
    The resource group name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER SourceWorkspaceName
    The name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER SourceLinkedServiceName
    The name of the linked service in the source Azure Synapse workspace to be copied. This is optional. If this is not supplied, all linked services will be copied.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure Synapse workspace. This is optional.

.PARAMETER DestinationResourceGroupName
    The resource group name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER DestinationWorkspaceName
    The name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER DestinationLinkedServiceName
    The name of the linked service in the destination Azure Synapse workspace. This is optional.

.PARAMETER Suffix
    A suffix to append to the name of the copied linked service. This is optional.

.EXAMPLE
    .\Copy-SynapseLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceWorkspaceName "sourceWorkspace" -DestinationResourceGroupName "destinationRG" -DestinationWorkspaceName "destinationWorkspace"

    This example copies all linked services from the source Azure Synapse workspace to the destination Azure Synapse workspace.

.EXAMPLE
    .\Copy-SynapseLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceWorkspaceName "sourceWorkspace" -SourceLinkedServiceName "sourceLS" -DestinationResourceGroupName "destinationRG" -DestinationWorkspaceName "destinationWorkspace" -DestinationLinkedServiceName "destinationLS"

    This example copies a specific linked service from the source Azure Synapse workspace to the destination Azure Synapse workspace.

#>

[CmdletBinding()]
param (
    [Parameter()]
    [string] $SourceSubscriptionId,

    [Parameter(Mandatory)]
    [string] $SourceResourceGroupName,

    [Parameter(Mandatory)]
    [string] $SourceWorkspaceName,

    [Parameter()]
    [string] $SourceLinkedServiceName,

    [Parameter()]
    [string] $DestinationSubscriptionId,

    [Parameter(Mandatory)]
    [string] $DestinationResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestinationWorkspaceName,

    [Parameter()]
    [string] $DestinationLinkedServiceName,

    [Parameter()]
    [string] $Suffix = ''
)

function Get-SynapseLinkedService
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse
    )

    $uri = "$($Synapse.properties.connectivityEndpoints.dev)/linkedServices?api-version=2019-06-01-preview"

    $results = Invoke-AzRestMethod -Uri $uri -Method GET
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to get linked service: $($results.Content)"
        return $null
    }

    return ($results.Content | ConvertFrom-Json).value
}

function New-SynapseLinkedService
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse,

        [Parameter(Mandatory)]
        [string] $LinkedServiceName,

        [Parameter(Mandatory)]
        [PSCustomObject] $Properties
    )


    $uri = "$($Synapse.properties.connectivityEndpoints.dev)/linkedServices/$($LinkedServiceName)?api-version=2019-06-01-preview"
    $payload = @{
        name = $LinkedServiceName
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Host "$LinkedServiceName...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        Write-Error "Failed to create linked service: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }


    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object {$_.key -eq 'Location'}
        if (-not $location) {
            Write-Error "Failed to create linked service: $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Host "$LinkedServiceName...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create linked service: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not $content.id) {
        Write-Error "Failed to create linked service: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    Write-Host "$LinkedServiceName...created"

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

$sourceSynapse = Get-SynapseWorkspaceDetails -SubscriptionId $SourceSubscriptionId -ResourceGroupName $SourceResourceGroupName -Name $SourceWorkspaceName -ErrorAction Stop
if (-not $sourceSynapse) {
    Write-Error "Unable to find Source Synapse workspace $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

$destinationSynapse = Get-SynapseWorkspaceDetails -SubscriptionId $DestinationSubscriptionId -ResourceGroupName $DestinationResourceGroupName -Name $DestinationWorkspaceName -ErrorAction Stop
if (-not $destinationSynapse) {
    Write-Error "Unable to find Destination Synapse workspace $DestinationResourceGroupName/$DestinationWorkspaceName"
    return
}

$sourceLinkedServices = Get-SynapseLinkedService -Synapse $synapse -ErrorAction Stop
if (-not $sourceLinkedServices) {
    Write-Error "No linked services found in $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

# filter down lihkedServices to just the one we want
if ($SourceLinkedServiceName) {
    $sourceLinkedServices = $sourceLinkedServices | Where-Object { $_.name -eq $SourceLinkedServiceName }
    if (-not $linkedServices) {
        Write-Error "Unable to find linked service '$SourceLinkedServiceName' in $SourceResourceGroupName/$SourceWorkspaceName"
        return
    }

    $sourceLinkedServices = @($sourceLinkedServices)
}

# get list of linked services in destination workspace
$destinationLinkedServices = Get-SynapseLinkedService -Synapse $destinationSynapse -ErrorAction Stop

foreach ($linkedService in $sourceLinkedServices) {
    $DestinationLinkedServiceName = $linkedService.name + $Suffix

    Write-Host "Copying '$($linkedService.name)' to '$DestinationLinkedServiceName'"

    # check if linked service already exists
    $destinationLinkedService = $destinationLinkedServices | Where-Object { $_.name -eq $DestinationLinkedServiceName }
    if ($destinationLinkedService) {
        Write-Error "'$DestinationLinkedServiceName' already exists in $DestinationResourceGroupName/$DestinationWorkspaceName"
        continue
    }

    # create linked service
    $result = New-SynapseLinkedService -Synapse $destinationSynapse -LinkedServiceName $DestinationLinkedServiceName -Properties $linkedService.Properties
    if (-not $result) {
        Write-Error "$DestinationLinkedServiceName creation failed."
    }
}
