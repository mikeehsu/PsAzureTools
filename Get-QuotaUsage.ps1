<#
.SYNOPSIS
Get Quota and Usage numbers for a particular provider

.PARAMETER Provider
Service provider to retrieve metrics for

.PARAMETER Location
Location retrieve metrics for

.PARAMETER ApiVersion
Api Version to use

.EXAMPLE
Get-QuotaUsage.ps1 -Provider "Microsoft.Compute" -Location "West US"


.NOTES

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ProviderNamespace,

    [Parameter(Mandatory)]
    [string] $Location,

    [Parameter()]
    [string] $ApiVersion,

    [Parameter()]
    [Microsoft.Azure.Commands.Common.Authentication.Abstractions.Core.IAzureContextContainer] $DefaultProfile
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
        if (-not $ApiVersion) {
            $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -location $Location | Where-Object {$_.ResourceTypes.ResourceTypeName -contains 'locations/usages' }
            if (-not $provider) {
                Write-Error "Provider '$ProviderNamespace/locations/usages' does not exist for $Location."
                return
            }
            $ApiVersion = $provider.resourcetypes.ApiVersions | Sort-Object -Descending | Select-Object -First 1
            if (-not $ApiVersion) {
                Write-Error "No API version found for $Provider."
                return
            }
        }

        $url = $managementUrl.TrimEnd('/') +  "/subscriptions/$subscriptionId/providers/$ProviderNamespace/locations/$Location/usages?api-version=$ApiVersion"
        $params = @{
            Uri = $url
            Method = 'GET'
        }

        if ($DefaultProfile) {
            $params.Add('DefaultProfile', $DefaultProfile)
        }

        $result = Invoke-AzRestMethod @params

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

