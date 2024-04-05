<#
.SYNOPSIS
    A script to copy an Azure Synapse Analytics pipeline.

.DESCRIPTION
    This script, Copy-SynapsePipeline.ps1, is used to copy an Azure Synapse Analytics pipeline from a source to a destination.

.PARAMETER SubscriptionId
    The subscription ID of the source Azure account.

.PARAMETER ResourceGroupName$ResourceGroupName
    The name of the resource group in the source Azure account where the Synapse pipeline is located.

.PARAMETER WorkspaceName$WorkspaceName
    The name of the source Synapse workspace.

.PARAMETER PipelineName
    The name of the pipeline in the source Synapse workspace. If not specified, all pipelines will be copied.

.EXAMPLE
    .\Copy-SynapsePipeline.ps1 -SourceSubscriptionId <value> -SourceResourceGroupName <value> -WorkspaceName$WorkspaceName <value> -PipelineName <value> -DestinationSubscriptionId <value> -DestinationResourceGroupName <value> -DestinationWorkspaceName <value> -DestinationPipelineName <value> -Suffix <value> -Overwrite

    Replace <value> with the appropriate value for each parameter.


    #>


[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $WorkspaceName,

    [Parameter()]
    [string[]] $PipelineName,

    [Parameter()]
    [string] $Path
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

##
## MAIN
##

Set-StrictMode -Version 2

# check parameters
if (-not $SubscriptionId) {
    $SubscriptionId = (Get-AzContext).Subscription.Id
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

# get source workspace
$synapse = Get-AzSynapseWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
if (-not $synapse) {
    Write-Error "Unable to find Source Synapse workspace $ResourceGroupName/$WorkspaceName"
    return
}

# get source pipelines
$pipelines = Get-SynapsePipeline -Synapse $synapse -ErrorAction Stop
if (-not $pipelines) {
    Write-Error "No pipelines found in $ResourceGroupName/$WorkspaceName"
    return
}

# process only one pipeline if specified
if ($PipelineName) {
    # filter down pipeline to just the one we want
    $pipeline = $pipelines | Where-Object { $_.name -eq $PipelineName }
    if (-not $pipeline) {
        Write-Error "Unable to find pipeline '$PipelineName' in $ResourceGroupName/$WorkspaceName"
        return
    }

    # convert to an array
    $pipelines = @($pipeline)
}

# sort list of pipelines to copy
$pipelines = $pipelines | Sort-Object -Property Name

$pipelines `
    | Sort-Object -Property Name `
    | ConvertTo-Json -Depth 100 `
    | Out-File -FilePath $Path

Write-Host "$($pipelines.Count) pipelines exported to $Path"
