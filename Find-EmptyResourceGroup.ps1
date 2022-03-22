<#
.SYNOPSIS
    This script returns a list of all resource groups that are empty

.DESCRIPTION
    This script returns a list of all resource groups that are empty in the current subscription.

#>

# check session to make sure if it connected
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        throw"Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }

}
catch {
    throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
}

$query = @"
ResourceContainers
| where type != 'microsoft.resources/subscriptions'
| where subscriptionId == '$($context.Subscription.SubscriptionId)'
| join kind=leftouter (Resources | summarize resourceCount=count() by resourceGroup) on resourceGroup
| where isnull(resourceCount)
| project ResourceGroupName=resourceGroup, Location=location, Tags=tags, ResourceId=id
"@
Search-AzGraph -Query $query -ErrorAction Stop
