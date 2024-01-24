<#
.SYNOPSIS
    This script copies LinkedServices from one Azure Synapse workspace to another.

.DESCRIPTION
    The script uses the Azure Synapse REST API to copy LinkedServices. It can be used to copy a single LinkedService or all LinkedServices from the source Azure Synapse workspace.

.PARAMETER SourceSubscriptionId
    The subscription ID of the source Azure Synapse workspace. This is optional.

.PARAMETER SourceResourceGroupName
    The resource group name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER SourceWorkspaceName
    The name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER SourceLinkedServiceName
    The name of the LinkedService in the source Azure Synapse workspace to be copied. If this is not supplied, all LinkedServices will be copied.

.PARAMETER DestinationSubscriptionId
    The subscription ID of the destination Azure Synapse workspace. This is optional.

.PARAMETER DestinationResourceGroupName
    The resource group name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER DestinationWorkspaceName
    The name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER DestinationLinkedServiceName
    The name of the LinkedService in the destination Azure Synapse workspace. This is only used when copying a single LinkedService. If this is not supplied, the name of the LinkedService in the source Azure Synapse workspace will be used.

.PARAMETER Suffix
    A suffix to append to the name of the copied LinkedService. This is optional.

.EXAMPLE
    .\Copy-SynapseLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceWorkspaceName "sourceWorkspace" -DestinationResourceGroupName "destinationRG" -DestinationWorkspaceName "destinationWorkspace"

    This example copies all LinkedServices from the source Azure Synapse workspace to the destination Azure Synapse workspace.

.EXAMPLE
    .\Copy-SynapseLinkedService.ps1 -SourceResourceGroupName "sourceRG" -SourceWorkspaceName "sourceWorkspace" -SourceLinkedServiceName "sourceLS" -DestinationResourceGroupName "destinationRG" -DestinationWorkspaceName "destinationWorkspace" -DestinationLinkedServiceName "destinationLS"

    This example copies a specific LinkedService from the source Azure Synapse workspace to the destination Azure Synapse workspace.

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
            Write-Error "Failed to get LinkedService: $($results.Content)"
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
        Write-Error "Failed to create $($LinkedServiceName): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    # check status of request
    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object {$_.key -eq 'Location'}
        if (-not $location) {
            Write-Error "Failed to create $($LinkedServiceName): $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$($LinkedServiceName)...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    Write-Verbose "$LinkedServiceName...$($results.Content)"
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create $($LinkedServiceName): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not ($content.PSobject.Properties.name -like 'id')) {
        Write-Error "Failed to create $($LinkedServiceName): $($content.error | ConvertTo-Json -Depth 10)"
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

# get destination LinkedServices
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

# get source LinkedServices
$sourceLinkedServices = Get-SynapseLinkedService -Synapse $sourceSynapse -ErrorAction Stop
if (-not $sourceLinkedServices) {
    Write-Error "No LinkedServices found in $SourceResourceGroupName/$SourceWorkspaceName"
    return
}

# only one LinkedService to copy, if specified
if ($SourceLinkedServiceName) {
    $linkedService = $sourceLinkedServices | Where-Object { $_.name -eq $SourceLinkedServiceName }
    if (-not $linkedService) {
        Write-Error "Unable to find LinkedService '$SourceLinkedServiceName' in $SourceResourceGroupName/$SourceWorkspaceName"
        return
    }

    # convert to array
    $sourceLinkedServices = @($linkedService)
}

# sort list of LinkedServices to copy
$sourceLinkedServices = $sourceLinkedServices | Sort-Object -Property Name

$successCount = 0
$skipCount = 0
$failedCount = 0
$failedNames = @()
foreach ($linkedService in $sourceLinkedServices) {
    Write-Progress -Activity "Copy LinkedServices" -Status "$($successCount+$skipCount+$skipCount+$failedCount) of $($sourceLinkedServices.Count) complete" -PercentComplete (($successCount+$failedCount+$skipCount) / $sourceLinkedServices.Count * 100)

    # build name for destination LinkedService
    $linkedServiceName = $DestinationLinkedServiceName
    if (-not $linkedServiceName) {
        $linkedServiceName = $linkedService.Name
    }
    $linkedServiceName = $linkedServiceName + $Suffix

    Write-Host "$linkedServiceName...working" -NoNewline

    # check if LinkedService already exists
    $destinationLinkedService = $destinationLinkedServices | Where-Object { $_.name -eq $linkedServiceName }
    if ($destinationLinkedService -and -not $Overwrite) {
        $skipCount++
        Write-Host "`r$($linkedServiceName)...SKIPPED (already exists)"
        continue
    }

    # create LinkedService
    $newService = New-SynapseLinkedService -Synapse $destinationSynapse -LinkedServiceName $linkedServiceName -Properties $linkedService.Properties
    if (-not $newService) {
        $failedCount++
        $failedNames = $failedNames + $linkedServiceName
        Write-Host "`r$($linkedServiceName)...FAILED"
        Write-Error "Failed to create LinkedService '$linkedServiceName' in destination data factory ($DestinationResourceGroupName/$DestinationWorkspaceName)."
    } else {
        $successCount++
        Write-Host "`r$linkedServiceName...created"
    }
}

Write-Host "$successCount LinkedServices created/updated."
Write-Host "$skipCount LinkedServices skipped."
Write-Host "$failedCount LinkedServices failed."

if ($failedCount -gt 0) {
    Write-Host
    Write-Host "Failed LinkedServices: $($failedNames -join ', ')"
}
