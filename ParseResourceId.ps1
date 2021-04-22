<#
.SYNOPSIS
Parse Auzre ResourceId

.DESCRIPTION
Parse the Azure ResourceId into its component parts and return an object

.PARAMETER ResourceId
ResourceId to parse

.EXAMPLE
ParseResourceId -ResourceId $resourceId

.NOTES
#>
function ParseResourceId
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $ResourceId
    )

    [regex] $rx =  "\/subscriptions\/(?<SubscriptionId>(.*?))\/resourceGroups\/(?<ResourceGroupName>(.*?))\/providers\/(?<ResourceProvider>(.*))\/(?<ResourceName>(.*))$"
    $m = $rx.match($ResourceId)

    if (-not $m) {
        return $null
    }

    $resourceObj = $m.groups |
        Where-Object {$_.name -notmatch '\d+'} |
        ForEach-Object -Begin {$r = [PSCustomObject]@{}} -Process { $r | Add-Member -NotePropertyName $_.Name -NotePropertyValue $_.Value } -End { $r }

    return $resourceObj
}
