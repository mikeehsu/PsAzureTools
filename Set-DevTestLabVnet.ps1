<#
.SYNOPSIS
Add a Virtual Network to a DevTestLab

.DESCRIPTION
This script will associate a Virtual Network to an existing DevTestLabs. During initial ARM & Terraform
deployment, only virtual networks within the resource group of the lab can be assigned. This script provides
a way of adding the virtual network after the deployment.

.PARAMETER DevTestLabResourceGroupName
Resource Group of the DevTestLab

.PARAMETER DevTestLabName
Name of the DevTestLab

.PARAMETER VnetResourceGroupName
Resource Group of the Virtual Netowrk to add

.PARAMETER VnetName
Name of the Virtual Network to add

.PARAMETER VnetId
Virtural Network Id of the Virtual Network to add

.EXAMPLE
Set-DevTestLabsVnet.ps1 -ResourceGroupName myRg -VmName myDtl -VnetResourceGroupName myVnetRg -VnetName myVnet

.EXAMPLE
Set-DevTestLabsVnet.ps1 -ResourceGroupName myRg -VmName myDtl -VnetId /subscriptions/xxxxx-xxxx-xxxx-xxxx-xxxxx/resourceGroups/myVnetRg/providers/Microsoft.Network/virtualNetworks/myVnet

.NOTES
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [Alias('ResourceGrouName')]
    [string] $DevTestLabResourceGroupName,

    [Parameter(Mandatory)]
    [Alias('Name')]
    [string] $DevTestLabName,

    [Parameter(ParameterSetName='VnetName', Mandatory)]
    [string] $VnetResourceGroupName,

    [Parameter(ParameterSetName='VnetName', Mandatory)]
    [string] $VnetName,

    [Parameter(ParameterSetName='VnetId', Mandatory)]
    [string] $VnetId
)

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

    # construct headers
    $headers = @{
        'Content-Type'  = 'application/json';
        'Authorization' = "Bearer $script:azToken";
    }

    if ($Method -eq 'GET' -or $Method -eq 'OPTIONS') {
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers
    } else {
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -Body $Body
    }

    return $response
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

$dtl = Get-AzResource -ResourceGroupName $DevTestLabResourceGroupName -Name $DevTestLabName
if (-not $dtl) {
    throw "DevTestLab ($DevTestLabResourceGroupName/$DevTestLabName) not found"
}

if ($PSCmdlet.ParameterSetName -eq 'VnetName') {
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $VnetResourceGroupName -Name $VnetName
    if (-not $vnet) {
        throw "Virtual Network ($ResourceGroupName/$VnetName) not found."
    }
    $VnetId = $vnet.Id

} elseif ($PSCmdlet.ParameterSetName -eq 'VnetId') {
    $resource = Get-AzResource -ResourceId $VnetId -Resource | Where-Object {$_.ResourceType -eq  'Microsoft.Network/virtualNetworks'}
    if (-not $resource) {
        throw "Virtual Network ($VnetId) not found."
    }

    $parts = $VnetId -split '/'
    $vnetName = $parts[$parts.Length - 1]

}

# initialize variables used for Azure API calls
$script:azToken = Get-AzCachedAccessToken

$environment = Get-AzEnvironment | Where-Object {$_.Name -eq $context.Environment}
$script:azArmUrl = $([uri] $environment.ResourceManagerUrl).AbsoluteUri

$restPath = $dtl.Id + "/virtualNetworks/$VnetName"
$apiVersion = '2018-10-15-preview'
$uri = "{0}{1}?api-version={2}" -f $script:azArmUrl, $restPath, $apiVersion

$body = '{"properties":{"externalProviderResourceId":"' + $vnetId + '","subnetOverrides":[]}}'

$response = Invoke-AzRestMethod -Method 'PUT' -Uri $Uri -Body $body
$response | ConvertTo-Json -Depth 10
