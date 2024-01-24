<#
.SYNOPSIS
    This script copies linkedservices from one Azure Synapse workspace to another.

.DESCRIPTION
    The script uses the Azure Synapse REST API to copy linkedservices. It can be used to copy a single linkedservice or all linkedservices from the source Azure Synapse workspace.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure Synapse workspace. This is optional.

.PARAMETER SourceResourceGroupName
    The resource group name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER SourceWorkspaceName
    The name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER SourceLinkedServiceName
    The name of the linkedservice in the source Azure Synapse workspace to be copied. If this is not supplied, all linkedservices will be copied.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure Synapse workspace. This is optional.

.PARAMETER DestinationResourceGroupName
    The resource group name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER DestinationWorkspaceName
    The name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER DestinationLinkedServiceName
    The name of the linkedservice in the destination Azure Synapse workspace. This is only used when copying a single linkedservice. If this is not supplied, the name of the linkedservice in the source Azure Synapse workspace will be used.

.PARAMETER Suffix
    A suffix to append to the name of the copied linkedservice. This is optional.

.EXAMPLE
    .\Copy-SynapseLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceWorkspaceName "sourceWorkspace" -DestinationResourceGroupName "destinationRG" -DestinationWorkspaceName "destinationWorkspace"

    This example copies all linkedservices from the source Azure Synapse workspace to the destination Azure Synapse workspace.

.EXAMPLE
    .\Copy-SynapseLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceWorkspaceName "sourceWorkspace" -SourceLinkedServiceName "sourceLS" -DestinationResourceGroupName "destinationRG" -DestinationWorkspaceName "destinationWorkspace" -DestinationLinkedServiceName "destinationLS"

    This example copies a specific linkedservice from the source Azure Synapse workspace to the destination Azure Synapse workspace.

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
    [string] $Suffix = '',

    [Parameter()]
    [switch] $Overwrite
)


function Get-SynapseLinkedService
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse
    )

    $linkedservices = @()
    $uri = "$($Synapse.connectivityEndpoints.dev)/linkedservices?api-version=2019-06-01-preview"

    do {
        $results = Invoke-AzRestMethod -Uri $uri -Method GET
        if ($results.StatusCode -ne 200) {
            Write-Error "Failed to get linkedservice: $($results.Content)"
            return $null
        }

        $content = $results.Content | ConvertFrom-Json
        $linkedservices += $content.value

        if ($content.PSobject.Properties.name -like 'nextLink') {
            $uri = $content.nextLink
        } else {
            $uri = $null
        }
    } while ($uri)

    return $linkedservices
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


    $uri = "$($Synapse.connectivityEndpoints.dev)/linkedServices/$($LinkedServiceName)?api-version=2019-06-01-preview"
    $payload = @{
        name = $LinkedServiceName
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Verbose "$LinkedServiceName...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        Write-Error "Failed to create linkedservice: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }


    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object {$_.key -eq 'Location'}
        if (-not $location) {
            Write-Error "Failed to create linkedservice: $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$LinkedServiceName...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create linkedservice: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not $content.PSobject.Properties.name -like 'id') {
        Write-Error "Failed to create linkedservice: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    Write-Verbose "$LinkedServiceName...created"

    return ($results.Content | ConvertFrom-Json)
}

##
## MAIN
##
Set-StrictMode -Version 2

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

# get destination workspace
$context = Set-AzContext -SubscriptionId $DestinationSubscriptionId -ErrorAction Stop
if (-not $context) {
    Write-Error "Failed to verify context for subscription '$DestinationSubscriptionId'."
    return
}
$destinationSynapse = Get-AzSynapseWorkspace -ResourceGroupName $DestinationResourceGroupName -Name $DestinationWorkspaceName -ErrorAction Stop
if (-not $destinationSynapse) {
    Write-Error "Unable to find Destination Synapse workspace $DestinationResourceGroupName/$DestinationWorkspaceName"
    return
}

# get destination linkedservices
$destinationLinkedServices = Get-SynapseLinkedService -Synapse $destinationSynapse -ErrorAction Stop


# get source workspace
$context = Set-AzContext -SubscriptionId $SourceSubscriptionId -ErrorAction Stop
if (-not $context) {
    Write-Error "Failed to verify context for subscription '$SourceSubscriptionId'."
    return
}
$sourceSynapse = Get-AzSynapseWorkspace -ResourceGroupName $SourceResourceGroupName -Name $SourceWorkspaceName -ErrorAction Stop
if (-not $sourceSynapse) {
    Write-Error "Unable to find Source Synapse workspace $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

# get source linkedservices
$sourceLinkedServices = Get-SynapseLinkedService -Synapse $sourceSynapse -ErrorAction Stop
if (-not $sourceLinkedServices) {
    Write-Error "No linkedservices found in $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

# only one linkedservice to copy, if specified
if ($SourceLinkedServiceName) {
    $linkedService = $sourceLinkedServices | Where-Object { $_.name -eq $SourceLinkedServiceName }
    if (-not $linkedService) {
        Write-Error "Unable to find linkedservice '$SourceLinkedServiceName' in $SourceResourceGroupName/$SourceWorkspaceName"
        return
    }

    # convert to array
    $sourceLinkedServices = @($linkedService)
}

# sort list of linkedservices to copy
$sourceLinkedServices = $sourceLinkedServices | Sort-Object -Property Name

$successCount = 0
$failedCount = 0
$failedNames = @()
foreach ($linkedService in $sourceLinkedServices) {
    Write-Progress -Activity "Copy LinkedServices" -Status "$($successCount+$failedCount) of $($sourceLinkedServices.Count) complete" -PercentComplete ($successCount+$failedCount / $sourceLinkedServices.Count * 100)

    # build name for destination linkedservice
    $linkedServiceName = $DestinationLinkedServiceName
    if (-not $linkedServiceName) {
        $linkedServiceName = $linkedService.Name
    }
    $linkedServiceName = $linkedServiceName + $Suffix

    Write-Host "$linkedServiceName...working" -NoNewline

    # check if linkedservice already exists
    $destinationLinkedService = $destinationLinkedServices | Where-Object { $_.name -eq $linkedServiceName }
    if ($destinationLinkedService -and -not $Overwrite) {
        $failedCount++
        $failedNames += $linkedServiceName
        Write-Host "`r$($linkedServiceName)...SKIPPED (already exists))"
        Write-Error "$linkedServiceName already exists in $DestinationResourceGroupName/$DestinationWorkspaceName"
        continue
    }

    # create linkedservice
    $newService = New-SynapseLinkedService -Synapse $destinationSynapse -LinkedServiceName $linkedServiceName -Properties $linkedService.Properties
    if (-not $newService) {
        $failedCount++
        $failedNames = $failedNames + $linkedServiceName
        Write-Host "`r$($linkedServiceName)...FAILED"
        Write-Error "Failed to create linkedservice '$linkedServiceName' in destination data factory ($DestinationResourceGroupName/$DestinationADFName)."
    } else {
        $successCount++
        Write-Host "`r$linkedServiceName...created"
    }
}

Write-Host "$successCount linkedservice created/updated."
Write-Host "$failedCount linkedservice failed."

if ($failedCount -gt 0) {
    Write-Host "Failed LinkedServices: $($failedNames -join ', ')"
}
