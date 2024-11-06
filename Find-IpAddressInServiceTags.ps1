<#
.SYNOPSIS
Search Service Tags for an IP Address

.DESCRIPTION
Searches through the Sevice Tag listings for a specific IP Address.

.PARAMETER IPAddress
IP Address to search for

.PARAMETER UseAPI
If specified, the script will retrieve the Service Tags from the new Powershell SDK using your current Azure subscription context. The default is to search through the weekly Service Tags file publications at: https://docs.microsoft.com/en-us/azure/virtual-network/security-overview#service-tags-in-on-premises

.PARAMETER Environment
Environment to search in. If an environment is not provided the current environment in context is used.

.EXAMPLE
FindIpAddressInServiceTags.ps1 40.90.23.208

.EXAMPLE
Find-IpAddressInServiceTags.ps1 40.90.23.208 -UseAPI
#>

[CmdletBinding()]

Param (
    [Parameter(Position = 0, Mandatory = $true)]
    [string] $IPAddress,

    [Parameter(Mandatory = $false)]
    [switch] $UseAPI,

    [Parameter(Mandatory = $false)]
    [string] $Environment
)

$ErrorActionPreference = "Stop"

# load the service tags
if ($UseAPI) {
    # ensure login
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context.Environment) {
            throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
        }
    }
    catch {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }

    if ($Environment -and $Environment -ne $context.Environment.Name) {
        throw "-Environment must be the same as current context when -UseAPI is used. Please remove -Environment or -UseAPI."
    }
    else {
        $Environment = $context.Environment.Name
    }

    # get tags across all locations in environment
    $serviceTags = @()
    $locations = Get-AzLocation
    foreach ($location in $locations) {
        Write-Progress -Activity "Searching for $ipAddress" -Status "Loading ServiceTags for $($location.DisplayName)..."
        $serviceTags += Get-AzNetworkServiceTag -Location $location.Location
    }

}
else {
    if (-not $environment) {
        $environment = $(Get-AzContext).Environment.Name
    }

    if ($environment -eq 'AzureCloud') {
        $url = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519'

    }
    elseif ($environment -eq 'AzureUSGovernment') {
        $url = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=57063'

    }
    elseif ($environment -eq 'AzureGermanCloud') {
        $url = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=57064'

    }
    elseif ($environment -eq 'AzureChinaCloud') {
        $url = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=57062'

    }
    else {
        throw "Invaild Environment $environment. Please use -Environment or ensure that you are logged in with Connect-AzAccount."
    }

    Write-Progress "Loading $environment..."

    # find the link for file
    $pageHTML = Invoke-WebRequest $url -UseBasicParsing
    $fileLink = ($pageHTML.Links | Where-Object { $_.outerHTML -like "*click here to download manually*" }).href

    # extract the filename
    $pathParts = $fileLink.Split('/')
    $dirPath = ''
    if ($env:TEMP) {
        $dirPath = $env:TEMP + '/'
    }
    $serviceTagFilename = $dirPath + $pathParts[$pathParts.count - 1]

    # download the JSON file to the TEMP directory
    $null = Invoke-WebRequest $fileLink -PassThru -OutFile $serviceTagFilename
    $serviceTags = Get-Content -Raw -Path $serviceTagFilename | ConvertFrom-Json
}

# loop through all serviceTags and look for IpAddress
$found = 0
foreach ($service in $serviceTags.values) {
    Write-Progress -Activity "Searching for $ipAddress" -Status "Checking $($service.Name)..."
    foreach ($addressPrefix in $service.properties.addressPrefixes) {
        # skip any IPv6 addresses
        if ($addressPrefix.Contains(':')) {
            continue
        }

        $ipPrefix = Get-IPNetwork -Address $addressPrefix
        if ($ipPrefix.Contains($ipaddress)) {
            Write-Verbose "Service: $($service.name) / AddressPrefix: $addressPrefix"
            [PSCustomObject] @{
                Name          = $($service.name)
                Service       = $($service.properties.systemService)
                Region        = $($service.properties.region)
                AddressPrefix = $($addressPrefix)
            }
            $found++
        }
    }
}

Write-Host "$found entries found in $Environment"
