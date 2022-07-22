<#
.SYNOPSIS
Copy Tags from the Resource Group to all Resources inside of it.

.DESCRIPTION
Copy Tags from the Resource Group to all Resources inside of it.

.PARAMETER ResourceGroupName
Name of the Resource Group to copy tags

.EXAMPLE
Copy-ResourceTags -ResourceGroupName MyResourceGroup
#>

[CmdletBinding()]

Param (
    [Parameter(Mandatory=$true, Position=0)]
    [Alias("Name")]
    [string] $ResourceGroupName
)

#################################################
# MAIN

#confirm user is logged into subscription
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
    }
}
catch {
    throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
}


$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
Get-AzResource -ResourceGroupName $ResourceGroupName | Foreach-Object {
    Write-Host "Updating $($_.ResourceName)"
    Set-AzResource -ResourceId $_.ResourceId -Tag $resourceGroup.Tags -Force
}

