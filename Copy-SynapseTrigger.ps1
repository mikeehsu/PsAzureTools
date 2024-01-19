<#
.SYNOPSIS
    A script to copy an Azure Synapse Analytics trigger.

.DESCRIPTION
    This script is used to copy an Azure Synapse Analytics trigger from a source to a destination.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure account.

.PARAMETER SourceResourceGroupName
    The name of the resource group in the source Azure account where the Synapse trigger is located.

.PARAMETER SourceWorkspaceName
    The name of the source Synapse workspace.

.PARAMETER SourceTriggerName
    The name of the trigger in the source Synapse workspace. If not specified, all triggers will be copied.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Synapse workspace.

.PARAMETER DestinationResourceGroupName
    The name of the resource group of the Synapse workspace where the trigger will be copied to.

.PARAMETER DestinationWorkspaceName
    The name of the destination Synapse workspace.

.PARAMETER DestinationTriggerName
    The name of the trigger in the destination Synapse workspace. This is only used when copying a single trigger.

.PARAMETER Suffix
    An optional suffix to append to the name of the copied trigger.

.PARAMETER Overwrite
    A switch parameter to indicate whether to overwrite the destination trigger if it already exists.

.EXAMPLE
    .\Copy-SynapseTrigger.ps1 -SourceSubscriptionId <value> -SourceResourceGroupName <value> -SourceWorkspaceName <value> -SourceTriggerName <value> -DestinationSubscriptionId <value> -DestinationResourceGroupName <value> -DestinationWorkspaceName <value> -DestinationTriggerName <value> -Suffix <value> -Overwrite
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
    [string] $SourceTriggerName,

    [Parameter()]
    [string] $DestinationSubscriptionId,

    [Parameter(Mandatory)]
    [string] $DestinationResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DestinationWorkspaceName,

    [Parameter()]
    [string] $DestinationTriggerName,

    [Parameter()]
    [string] $Suffix = '',

    [Parameter()]
    [switch] $Overwrite
)


function Get-SynapseTrigger
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse
    )

    $uri = "$($Synapse.connectivityEndpoints.dev)/triggers?api-version=2019-06-01-preview"

    $results = Invoke-AzRestMethod -Uri $uri -Method GET
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to get trigger: $($results.Content)"
        return $null
    }

    return ($results.Content | ConvertFrom-Json).value
}

function New-SynapseTrigger
{
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse,

        [Parameter(Mandatory)]
        [string] $TriggerName,

        [Parameter(Mandatory)]
        [PSCustomObject] $Properties
    )


    $uri = "$($Synapse.connectivityEndpoints.dev)/triggers/$($TriggerName)?api-version=2019-06-01-preview"
    $payload = @{
        name = $TriggerName
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Verbose "$TriggerName...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        Write-Error "Failed to create trigger: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }


    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object {$_.key -eq 'Location'}
        if (-not $location) {
            Write-Error "Failed to create trigger: $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$TriggerName...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create trigger: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not $content.id) {
        Write-Error "Failed to create trigger: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    Write-Verbose "$TriggerName...created"

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

if ($DestinationTriggerName -and -not $SourceTriggerName) {
    Write-Error "-SourceTriggerName is required when -DestinationTriggerName is specified."
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

# get list of triggers in destination workspace
$destinationTriggers = Get-SynapseTrigger -Synapse $destinationSynapse -ErrorAction Stop


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

# get source triggers
$sourceTriggers = Get-SynapseTrigger -Synapse $sourceSynapse -ErrorAction Stop
if (-not $sourceTriggers) {
    Write-Error "No triggers found in $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

# process only one trigger if specified
if ($SourceTriggerName) {
    # filter down trigger to just the one we want
    $trigger = $sourceTriggers | Where-Object { $_.name -eq $SourceTriggerName }
    if (-not $trigger) {
        Write-Error "Unable to find trigger '$SourceTriggerName' in $SourceResourceGroupName/$SourceWorkspaceName"
        return
    }

    # convert to an array
    $sourceTriggers = @($trigger)
}

# sort list of triggers to copy
$sourceTriggers = $sourceTriggers | Sort-Object -Property Name

$successCount = 0
$failedCount = 0
$failedNames = @()
foreach ($trigger in $sourceTriggers) {
    Write-Progress -Activity "Copy Triggers" -Status "$($successCount+$failedCount) of $($sourceTriggers.Count) complete" -PercentComplete ($completeCount / $sourceTriggers.Count * 100)

    # build name for destination trigger
    $triggerName = $DestinationTriggerName
    if (-not $triggerName) {
        $triggerName = $trigger.Name
    }
    $triggerName = $triggerName + $Suffix

    Write-Host "$triggerName...working" -NoNewline

    # check if trigger already exists
    $destinationTrigger = $destinationTriggers | Where-Object { $_.name -eq $triggerName }
    if ($destinationTrigger -and -not $Overwrite) {
        $failedCount++
        $failedNames += $triggerName
        Write-Host "`r$($triggerName)...SKIPPED (already exists))"
        Write-Error "$triggerName already exists in $DestinationResourceGroupName/$DestinationWorkspaceName"
        continue
    }

    # create trigger
    $newService = New-SynapseTrigger -Synapse $destinationSynapse -TriggerName $triggerName -Properties $trigger.Properties
    if (-not $newService) {
        $failedCount++
        $failedNames = $failedNames + $triggerName
        Write-Host "`r$($triggerName)...FAILED"
        Write-Error "Failed to create trigger '$triggerName' in destination data factory ($DestinationResourceGroupName/$DestinationADFName)."
    } else {
        $successCount++
        Write-Host "`r$triggerName...created"
    }
}

Write-Host "$successCount triggers created/updated."
Write-Host "$failedCount triggers failed."

if ($failedCount -gt 0) {
    Write-Host "Failed datasets: $($failedNames -join ', ')"
}
