
##################################################
function Get-AzCachedAccessToken()
{
    $ErrorActionPreference = 'Stop'

    if(-not (Get-Module Az.Accounts)) {
        Import-Module Az.Accounts
    }

    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    if(-not $azProfile.Accounts.Count) {
        Write-Error "Ensure you have logged in before calling this function."
    }
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)

    $currentAzureContext = Get-AzContext
    Write-Debug ("Getting access token for tenant" + $currentAzureContext.Tenant.TenantId)
    $token = $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId)

    return $token.AccessToken
}

##################################################
function Invoke-AzRestMethod
{
    [CmdletBinding()]

    param
    (
        [string] $Method = 'GET',
        [string] $Uri,
        [string] $Body
    )

    process
    {
        # construct request body object
        $requestBodyAsJson = ConvertTo-Json -InputObject $Body -Depth 100

        # construct headers
        # 'Host'          = 'management.usgovcloudapi.net'
        $headers = @{
            'Content-Type'  = 'application/json';
            'Authorization' = "Bearer $script:azToken";
        }

        if ($Method -eq 'GET') {
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers
        } else {
            $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -Body $requestBodyAsJson
        }

        return $response
    }
}

######################## MAIN ########################

try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}
catch {
    throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
}

# initialize variables used for Azure API calls
$script:azToken = Get-AzCachedAccessToken

$environment = Get-AzEnvironment | Where-Object {$_.Name -eq $context.Environment}
$script:azArmUrl = $([uri] $environment.ResourceManagerUrl).AbsoluteUri

$ApiVersion = 'api-version=2020-01-01'
$Uri = "{0}subscriptions/{1}?{2}" -f $script:azArmUrl, $context.Subscription.Id, $ApiVersion

$response = Invoke-AzRestMethod -Method 'GET' -Uri $Uri
$response | ConvertTo-Json -Depth 10

