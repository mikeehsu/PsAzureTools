<#
.SYNOPSIS
Get Quota and Usage numbers for a particular provider

.PARAMETER Provider
Service provider to retrieve metrics for

.PARAMETER Location
Location retrieve metrics for

.EXAMPLE
Get-QuotaUsage.ps1 -Provider "Microsoft.Compute" -Location "West US"


.NOTES

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $Provider,

    [Parameter(Mandatory)]
    [string] $Location,

    [Parameter()]
    [string] $ApiVersion = '2024-07-01'
)

BEGIN {
    # check parameters
    $Location = $Location.Replace(' ','').ToLower()

    # check for login
    $context = Get-AzContext
    if (-not $context) {
        Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Set-AzContext) context before proceeding.'
        return
    }
    $subscriptionId = $context.Subscription.Id

    $managementUrl = (Get-AzEnvironment -Name $context.Environment.Name).ResourceManagerUrl
}


PROCESS {

    try {
        $url = $managementUrl.TrimEnd('/') +  "/subscriptions/$subscriptionId/providers/$Provider/locations/$Location/usages?api-version=$ApiVersion"
        $result = Invoke-AzRestMethod -Uri $url
    } catch [Exception] {
        Write-Error $_.Exception.Message
        return
    }

    if ($result.StatusCode -ne 200) {
        Write-Error $result.Content
        return
    }

    ($result.Content | ConvertFrom-Json).value
}

END {

}
