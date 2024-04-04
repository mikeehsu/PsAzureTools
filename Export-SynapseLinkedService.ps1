<#
.SYNOPSIS
    This script copies LinkedServices from one Azure Synapse workspace to another.

.DESCRIPTION
    The script uses the Azure Synapse REST API to copy LinkedServices. It can be used to copy a single LinkedService or all LinkedServices from the source Azure Synapse workspace.

.PARAMETER $ResourceGroupName
    The resource group name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER $WorkspaceName
    The name of the source Azure Synapse workspace. This is mandatory.

.PARAMETER $LinkedServiceName
    The name of the LinkedService in the source Azure Synapse workspace to be copied. If this is not supplied, all LinkedServices will be copied.

.EXAMPLE
    .\Export-SynapseLinkedService.ps1 -ResourceGroupName "sourceRG" -WorkspaceName "sourceWorkspace" -Path LinkedServices.json
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $WorkspaceName,

    [Parameter()]
    [string[]] $LinkedServiceName,

    [Parameter(Mandatory)]
    [string] $Path
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

##
## MAIN
##
Set-StrictMode -Version 2

# check parameters

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

# get synapse workspace
$synapse = Get-AzSynapseWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
if (-not $synapse) {
    Write-Error "Unable to find Synapse workspace $ResourceGroupName/$WorkspaceName"
    return
}

# get source LinkedServices
$linkedServices = Get-SynapseLinkedService -Synapse $synapse -ErrorAction Stop
if (-not $linkedServices) {
    Write-Error "No LinkedServices found in $ResourceGroupName/$WorkspaceName"
    return
}

# only one LinkedService to copy, if specified
if ($LinkedServiceName) {
    $linkedServices = $linkedServices | Where-Object { $LinkedServiceName -contains $_.name }
    if (-not $linkedServices) {
        Write-Error "Unable to find LinkedService '$LinkedServiceName' in $ResourceGroupName/$WorkspaceName"
        return
    }

    # convert to array
    $linkedServices = @($linkedServices)
}

# sort list of LinkedServices to copy
$linkedServices `
    | Sort-Object -Property Name `
    | ConvertTo-Json -Depth 10 `
    | Out-File $Path

Write-Host "$($linkedServices.Count) linked services exported to $Path"
