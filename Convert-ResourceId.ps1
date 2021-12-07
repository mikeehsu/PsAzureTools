<#
.SYNOPSIS
Convert Azure ResourceId to Object

.DESCRIPTION
Parse the Azure ResourceId into its component parts and return an object

.PARAMETER ResourceId
ResourceId to parse

.EXAMPLE
ConvertResourceId -ResourceId $resourceId

.NOTES
#>
function ConvertResourceId
{
    [CmdletBinding()]
    param (
        [Parameter(Position=0, Mandatory, ValueFromPipeline)]
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