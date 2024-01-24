<#
.SYNOPSIS
    A script to copy an Azure Synapse Analytics pipeline.

.DESCRIPTION
    This script, Copy-SynapsePipeline.ps1, is used to copy an Azure Synapse Analytics pipeline from a source to a destination.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure account.

.PARAMETER SourceResourceGroupName
    The name of the resource group in the source Azure account where the Synapse pipeline is located.

.PARAMETER SourceWorkspaceName
    The name of the source Synapse workspace.

.PARAMETER SourcePipelineName
    The name of the pipeline in the source Synapse workspace. If not specified, all pipelines will be copied.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure account.

.PARAMETER DestinationResourceGroupName
    The name of the resource group in the destination Azure account where the Synapse pipeline will be copied to.

.PARAMETER DestinationWorkspaceName
    The name of the destination Synapse workspace.

.PARAMETER DestinationPipelineName
    The name of the pipeline in the destination Synapse workspace. Only used when copying a single pipeline.

.PARAMETER Suffix
    An optional suffix to append to the name of the copied pipeline.

.PARAMETER Overwrite
    A switch parameter to indicate whether to overwrite the destination pipeline if it already exists.

.EXAMPLE
    .\Copy-SynapsePipeline.ps1 -SourceSubscriptionId <value> -SourceResourceGroupName <value> -SourceWorkspaceName <value> -SourcePipelineName <value> -DestinationSubscriptionId <value> -DestinationResourceGroupName <value> -DestinationWorkspaceName <value> -DestinationPipelineName <value> -Suffix <value> -Overwrite
    Replace <value> with the appropriate value for each parameter.
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
    [string] $SourcePipelineName,

    [Parameter()]
    [string] $DestinationSubscriptionId,

    [Parameter(Mandatory)]
    [string] $DestinationResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestinationWorkspaceName,

    [Parameter()]
    [string] $DestinationPipelineName,

    [Parameter()]
    [string] $Suffix = '',

    [Parameter()]
    [switch] $Overwrite
)


function Get-SynapsePipeline
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse
    )

    $pipelines = @()
    $uri = "$($Synapse.connectivityEndpoints.dev)/pipelines?api-version=2019-06-01-preview"

    do {
        $results = Invoke-AzRestMethod -Uri $uri -Method GET
        if ($results.StatusCode -ne 200) {
            Write-Error "Failed to get pipeline: $($results.Content)"
            return $null
        }

        $content = $results.Content | ConvertFrom-Json
        $pipelines += $content.value

        if ($content.PSobject.Properties.name -like 'nextLink') {
            $uri = $content.nextLink
        } else {
            $uri = $null
        }
    } while ($uri)

    return $pipelines
}

function New-SynapsePipeline
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse,

        [Parameter(Mandatory)]
        [string] $PipelineName,

        [Parameter(Mandatory)]
        [PSCustomObject] $Properties
    )


    $uri = "$($Synapse.connectivityEndpoints.dev)/pipelines/$($PipelineName)?api-version=2019-06-01-preview"
    $payload = @{
        name = $PipelineName
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Verbose "$PipelineName...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        Write-Error "Failed to create $($PipelineName): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    # check status of request
    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object {$_.key -eq 'Location'}
        if (-not $location) {
            Write-Error "Failed to create ($PipelineName): $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$($PipelineName)...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    # Write-Verbose "$LinkedServiceName...$($results.Content)"
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create ($PipelineName): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not $content.PSobject.Properties.name -like 'id') {
        Write-Error "Failed to create ($PipelineName): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    if ($content.PSobject.Properties.name -like 'status' -and $content.status -eq 'Failed') {
        Write-Error "Failed to create $($PipelineName): $($content.error | ConvertTo-Json -Depth 10)"
        return $null
    }

    Write-Verbose "$PipelineName...created"

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

if ($DestinationPipelineName -and -not $SourcePipelineName) {
    Write-Error "-SourcePipelineName is required when -DestinationPipelineName is specified."
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

# get list of pipelines in destination workspace
$destinationPipelines = Get-SynapsePipeline -Synapse $destinationSynapse -ErrorAction Stop


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

# get source pipelines
$sourcePipelines = Get-SynapsePipeline -Synapse $sourceSynapse -ErrorAction Stop
if (-not $sourcePipelines) {
    Write-Error "No pipelines found in $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

# process only one pipeline if specified
if ($SourcePipelineName) {
    # filter down pipeline to just the one we want
    $pipeline = $sourcePipelines | Where-Object { $_.name -eq $SourcePipelineName }
    if (-not $pipeline) {
        Write-Error "Unable to find pipeline '$SourcePipelineName' in $SourceResourceGroupName/$SourceWorkspaceName"
        return
    }

    # convert to an array
    $sourcePipelines = @($pipeline)
}

# sort list of pipelines to copy
$sourcePipelines = $sourcePipelines | Sort-Object -Property Name

$successCount = 0
$failedCount = 0
$failedNames = @()
foreach ($pipeline in $sourcePipelines) {
    Write-Progress -Activity "Copy Pipelines" -Status "$($successCount+$failedCount) of $($sourcePipelines.Count) complete" -PercentComplete ($successCount+$failedCount / $sourcePipelines.Count * 100)

    # build name for destination pipeline
    $pipelineName = $DestinationPipelineName
    if (-not $pipelineName) {
        $pipelineName = $pipeline.Name
    }
    $pipelineName = $pipelineName + $Suffix

    Write-Host "$pipelineName...working" -NoNewline

    # check if pipeline already exists
    $destinationPipeline = $destinationPipelines | Where-Object { $_.name -eq $pipelineName }
    if ($destinationPipeline -and -not $Overwrite) {
        $failedCount++
        $failedNames += $pipelineName
        Write-Host "`r$($pipelineName)...SKIPPED (already exists))"
        continue
    }

    # create pipeline
    $newService = New-SynapsePipeline -Synapse $destinationSynapse -PipelineName $pipelineName -Properties $pipeline.Properties
    if (-not $newService) {
        $failedCount++
        $failedNames = $failedNames + $pipelineName
        Write-Host "`r$($pipelineName)...FAILED"
        Write-Error "Failed to create pipeline '$pipelineName' in destination data factory ($DestinationResourceGroupName/$DestinationWorkspaceName)."
    } else {
        $successCount++
        Write-Host "`r$pipelineName...created"
    }
}

Write-Host "$successCount pipelines created/updated."
Write-Host "$failedCount pipelines failed."

if ($failedCount -gt 0) {
    Write-Host "Failed datasets: $($failedNames -join ', ')"
}
