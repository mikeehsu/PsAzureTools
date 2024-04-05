<#
.SYNOPSIS
    Import pipelines from a file into an  Azure Synapse Analytics workspace.

.DESCRIPTION
    This script is used to import Azure Synapse Analytics pipelines from a JSON file.

.PARAMETER ResourceGroupName
    Specifies the name of the resource group where the workspace is located.

.PARAMETER WorkspaceName
    Specifies the name of the Synapse workspace where the pipelines will be imported.

.PARAMETER Path
    Specifies the path to the JSON file containing the pipeline definitions to be imported.

.PARAMETER PipelineName
    Specifies the name of the specific pipeline to import. If not specified, all pipelines in the JSON file will be copied.

.PARAMETER Suffix
    Specifies an optional suffix to append to the name of the copied pipelines.

.PARAMETER Overwrite
    Switch parameter to indicate whether existing pipelines in the destination workspace should be overwritten if they have the same name as the pipelines being copied.

.EXAMPLE
    .\Import-SynapsePipeline.ps1 -ResourceGroupName "MyResourceGroup" -WorkspaceName "MyWorkspace" -Path "C:\Pipelines.json" -Overwrite

    Copies all pipelines defined in the "Pipelines.json" file to the "MyWorkspace" Synapse workspace in the "MyResourceGroup" resource group, overwriting existing pipelines with the same names.
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
