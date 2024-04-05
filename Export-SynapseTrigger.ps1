<#
.SYNOPSIS
Retrieve triggers from an Azure Synapse Analytics workspace.

.DESCRIPTION
This script retrieves triggers from an Azure Synapse Analytics workspace and writes them to a specified file in JSON format.

.PARAMETER ResourceGroupName
The name of the resource group where the Synapse workspace is located.

.PARAMETER WorkspaceName
The name of the Azure Synapse Analytics workspace.

.PARAMETER Path
The path where the JSON file containing the triggers will be saved.

.PARAMETER TriggerName
Optional. The name of the specific trigger to retrieve.

.EXAMPLE
Export-SynapseTriggers -ResourceGroupName "myResourceGroup" -WorkspaceName "myWorkspace" -Path "C:\output\triggers.json"

This example retrieves all triggers from the specified Azure Synapse Analytics workspace and saves them to "C:\output\triggers.json".

.EXAMPLE
Export-SynapseTriggers -ResourceGroupName "myResourceGroup" -WorkspaceName "myWorkspace" -Path "C:\output\triggers.json" -TriggerName "myTriggerName"

This example retrieves a specific trigger named "myTriggerName" from the specified Azure Synapse Analytics workspace and saves it to "C:\output\triggers.json".

.NOTES
File output will be in JSON format.
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
    [string[]] $TriggerName

)


function Get-SynapseTrigger {
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse
    )

    $triggers = @()
    $uri = "$($Synapse.connectivityEndpoints.dev)/triggers?api-version=2019-06-01-preview"

    do {
        $results = Invoke-AzRestMethod -Uri $uri -Method GET
        if ($results.StatusCode -ne 200) {
            Write-Error "Failed to get trigger: $($results.Content)"
            return $null
        }

        $content = $results.Content | ConvertFrom-Json
        $triggers += $content.value

        if ($content.PSobject.Properties.name -like 'nextLink') {
            $uri = $content.nextLink
        }
        else {
            $uri = $null
        }
    } while ($uri)

    return $triggers
}

##
## MAIN
##
Set-StrictMode -Version 2

# check parameters

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
    Write-Error "Unable to find Source Synapse workspace $ResourceGroupName/$WorkspaceName"
    return
}

# get list triggers
$triggers = Get-SynapseTrigger -Synapse $synapse -ErrorAction Stop
if (-not $triggers) {
    Write-Error "No triggers found in $ResourceGroupName/$WorkspaceName"
    return
}

# process only specified trigger, if specified
if ($TriggerName) {
    # filter down trigger to just the one we want
    $triggers = $triggers | Where-Object { $TriggerName -contains $_.name }
    if (-not $triggers) {
        Write-Error "Unable to find trigger '$TriggerName' in $ResourceGroupName/$WorkspaceName"
        return
    }
}

# write out triggers to file
$triggers `
    | Sort-Object -Property Name `
    | ConvertTo-Json -Depth 100 `
    | Out-File $Path

Write-Host "$($triggers.count) triggers written to $Path"