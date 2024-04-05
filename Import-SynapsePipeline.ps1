<#
.SYNOPSIS
    A script to copy an Azure Synapse Analytics pipeline.

.DESCRIPTION
    This script, Copy-SynapsePipeline.ps1, is used to copy an Azure Synapse Analytics pipeline from a source to a destination.

.PARAMETER ResourceGroupName
    The name of the resource group in the destination Azure account where the Synapse pipeline will be copied to.

.PARAMETER WorkspaceName
    The name of the destination Synapse workspace.

.PARAMETER PipelineName
    The name of the pipeline in the destination Synapse workspace. Only used when copying a single pipeline.

.PARAMETER Suffix
    An optional suffix to append to the name of the copied pipeline.

.PARAMETER Overwrite
    A switch parameter to indicate whether to overwrite the destination pipeline if it already exists.

#>


[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $WorkspaceName,

    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter()]
    [string[]] $PipelineName,

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

function New-SynapsePipeline {
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse,

        [Parameter(Mandatory)]
        [string] $name,

        [Parameter(Mandatory)]
        [PSCustomObject] $Properties
    )

    $uri = "$($Synapse.connectivityEndpoints.dev)/pipelines/$($name)?api-version=2019-06-01-preview"
    $payload = @{
        name       = $name
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Verbose "$name...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        throw "Failed (submission) to create $($name): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    # check status of request
    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object { $_.key -eq 'Location' }
        if (-not $location) {
            Write-Error "Failed (nokey) to create ($name): $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$($name)...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    # Write-Verbose "$LinkedServiceName...$($results.Content)"
    if ($results.StatusCode -ne 200) {
        throw "Failed (200) to create ($name): $($results | ConvertTo-Json -Depth 100)"
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not ($content.PSobject.Properties.name -like 'id')) {
        throw "Failed (no id) to create ($name): $($content.error | ConvertTo-Json -Depth 100)"
    }

    Write-Verbose "$name...created"
    return ($results.Content | ConvertFrom-Json)
}

##
## MAIN
##
Set-StrictMode -Version 2

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
        return
    }

}
catch {
    Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
    return
}

# get destination workspace
$synapse = Get-AzSynapseWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
if (-not $synapse) {
    Write-Error "Unable to find Synapse workspace $ResourceGroupName/$WorkspaceName"
    return
}

# get list of pipelines in workspace
$existingPipelines = Get-SynapsePipeline -Synapse $synapse -ErrorAction Stop

# read file
$pipelines = Get-Content $Path | ConvertFrom-Json

# process only one pipeline if specified
if ($PipelineName) {
    # filter down pipeline to just the one we want
    $pipeline = $pipelines | Where-Object { $PipelineName -contains $_.name}
    if (-not $pipeline) {
        Write-Error "Unable to find pipeline '$PipelineName' in $ResourceGroupName/$WorkspaceName"
        return
    }

    # convert to an array
    $pipelines = @($pipeline)
}

# sort list of pipelines to copy
$pipelines = $pipelines | Sort-Object -Property Name

$successCount = 0
$skipCount = 0
$failedCount = 0
$failedNames = @()
foreach ($pipeline in $pipelines) {

    $name = $pipeline.Name + $Suffix
    Write-Progress -Activity 'Copy Pipelines' -Status "$name" -PercentComplete (($successCount + $failedCount + $skipCount) / $pipelines.Count * 100)

    if (-not $Overwrite) {
        # check if pipeline already exists
        $found = $existingPipelines | Where-Object {$PipelineName -contains $_.name }
        if ($found) {
            $skipCount++
            Write-Host "$name...skipped (exists)"
            continue
        }
    }

    # create pipeline
    try {
        $newService = New-SynapsePipeline -Synapse $synapse -name $name -Properties $pipeline.Properties
        if (-not $newService) {
            throw "Untrapped error creating pipeline '$name' in destination data factory ($ResourceGroupName/$WorkspaceName)."
        }
        $successCount++
        Write-Host "$name...created"
    } catch {
        Write-Error $_
        $failedCount++
        $failedNames = $failedNames + $name
        Write-Host "$name...FAILED"
    }
}

Write-Host "$successCount pipelines created/updated."
Write-Host "$skipCount pipelines skipped."
Write-Host "$failedCount pipelines failed."

if ($failedCount -gt 0) {
    Write-Host
    Write-Host "Failed datasets: $($failedNames -join ', ')"
}
