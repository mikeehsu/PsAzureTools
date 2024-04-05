<#
.SYNOPSIS
    A script to copy an Azure Synapse Analytics trigger.

.DESCRIPTION
    This script is used to copy an Azure Synapse Analytics trigger from a source to a destination.


.PARAMETER ResourceGroupName
    The name of the resource group of the Synapse workspace where the trigger will be copied to.

.PARAMETER WorkspaceName
    The name of the destination Synapse workspace.
[]
.PARAMETER TriggerName
    The name of the trigger in the destination Synapse workspace. This is only used when copying a single trigger.

.PARAMETER Suffix
    An optional suffix to append to the name of the copied trigger.

.PARAMETER Overwrite
    A switch parameter to indicate whether to overwrite the destination trigger if it already exists.

.EXAMPLE
    .\Copy-SynapseTrigger.ps1 -SourceSubscriptionId <value> -SourceResourceGroupName <value> -WorkspaceNam <value> -TriggerName <value> -DestinationSubscriptionId <value> -DestinationResourceGroupName <value> -WorkspaceName[] <value> -TriggerName <value> -Suffix <value> -Overwrite

    Replace <value> with the appropriate value for each parameter.

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
    [string[]] $TriggerName,

    [Parameter()]
    [string] $Suffix = '',

    [Parameter()]
    [switch] $Overwrite
)

function New-SynapseTrigger {
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
        name       = $TriggerName
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Verbose "$TriggerName...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        throw "Failed to submit trigger: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }


    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object { $_.key -eq 'Location' }
        if (-not $location) {
            throw "Failed (key) to create trigger: $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$TriggerName...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    if ($results.StatusCode -ne 200) {
        throw "Failed (200) to create trigger: $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not ($content.PSobject.Properties.name -like 'id')) {
        throw "Failed (on id) to create $($TriggerName): $($content.error | ConvertTo-Json -Depth 10)"
        return $null
    }

    Write-Verbose "$TriggerName...created"
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
    Write-Error "Unable to find Destination Synapse workspace $ResourceGroupName/$WorkspaceName"
    return
}

# get list of triggers in destination workspace
$existingTriggers = Get-SynapseTrigger -Synapse $synapse -ErrorAction Stop

# read file of triggers
$triggers = Get-Content -Path $Path | ConvertFrom-Json -ErrorAction Stop

# process only one trigger if specified
if ($TriggerName) {
    # filter down trigger to just the one we want
    $triggers = $triggers | Where-Object { $TriggerName -contains $_.Name }
    if (-not $triggers) {
        Write-Error "Unable to find trigger '$TriggerName' in $SourceResourceGroupName/$WorkspaceName"
        return
    }

    # convert to an array
    $triggers = @($trigger)
}

# sort list of triggers to copy
$successCount = 0
$skipCount = 0
$failedCount = 0
$failedNames = @()

$triggers = $triggers | Sort-Object -Property Name -ErrorAction Stop
foreach ($trigger in $triggers) {
    # build name for destination trigger
    $triggerName = $trigger.Name + $Suffix

    Write-Progress -Activity 'Import Triggers' -Status $triggerName -PercentComplete (($successCount + $failedCount + $skipCount) / $triggers.Count * 100)

    if (-not $Overwrite) {
        # check if trigger already exists
        $found = $existingTriggers | Where-Object { $triggerName -contains $_.Name }
        if ($found) {
            $skipCount++
            Write-Host "$($triggerName)...skipped (exists)"
            continue
        }
    }

    # create trigger
    try {
        $newService = New-SynapseTrigger -Synapse $synapse -TriggerName $triggerName -Properties $trigger.Properties
        if (-not $newService) {
            throw "Untrapped error creating trigger '$triggerName' in destination data factory ($ResourceGroupName/$WorkspaceName)."
        }
        $successCount++
        Write-Host "$triggerName...created"
    }
    catch {
        Write-Error $_
        $failedCount++
        $failedNames = $failedNames + $triggerName
        Write-Host "$($triggerName)...FAILED"
    }
}

Write-Host "$successCount triggers created/updated."
Write-Host "$skipCount triggers skipped."
Write-Host "$failedCount triggers failed."

if ($failedCount -gt 0) {
    Write-Host
    Write-Host "Failed datasets: $($failedNames -join ', ')"
}
