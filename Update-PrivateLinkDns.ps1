<#
.SYNOPSIS
Update DNS entries in current subscription with current Private Endpoint settings

.DESCRIPTION
Retrieve the Private Endpoint settings from subscriptions across the tenant and updates Private DNS zone entries in the current subscription.
This is useful when you have several subscriptions creating private endpoints and need to consolidate the DNS entries into a single subscription.

.PARAMETER ResourceGroupName
Resource Group Name for the Private DNS Zones

.EXAMPLE
Update-PrivateLinkDns.ps1 -ResourceGroupName myRg

.NOTES
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName
)

#####################################################################
function SearchResourceGraph
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Query
    )

    $azContext = Get-AzContext
    $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
    $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
    $authHeader = @{
        'Content-Type'='application/json'
        'Authorization'='Bearer ' + $token.AccessToken
    }

    $environment = Get-AzEnvironment -Name (Get-AzContext).Environment
    $url = $environment.ResourceManagerUrl + "providers/Microsoft.ResourceGraph/resources?api-version=2019-04-01"
    $body = [PSCustomObject] @{
        subscriptions = (Get-AzSubscription).SubscriptionId
        query = $Query
    }

    $response = Invoke-RestMethod -Uri $url -Method 'POST' -Headers $authHeader -Body ($body | ConvertTo-Json)

    $results = @()
    foreach($row in $response.data.rows) {
        $expression = ""
        for ($i=0; $i -lt $response.data.columns.length; $i++) {
            $expression += ' ' + "$($response.data.columns[$i].name) = '$($row[$i])'`n"
        }
        $results += Invoke-Expression -Command "[PSCustomObject] @{ $expression }"
    }

    return $results
}

#####################################################################

Set-StrictMode -Version 3

#region -- Confirm user is logged into subscription
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    exit
}
#endregion

$ErrorActionPreference = "Stop"

#region -- get private endpoints
$endpoints = @()
$query = "Resources
    | where type =~ 'Microsoft.Network/privateEndpoints'
    | mv-expand dnsConfig=properties.customDnsConfigs
    | project Id = id, Name = name, fqdn = tostring(dnsConfig.fqdn), ipAddresses = dnsConfig.ipAddresses"

if (Get-Module -ListAvailable -Name 'Az.ResourceGraph') {
    if (-not (Get-Module -Name 'Az.Module')) {
        Import-Module Az.ResourceGraph
    }

    $endpoints = Search-AzGraph -Query $query
}
else {
    $endpoints = SearchResourceGraph -Query $query
}
#endregion

#region -- load all current DNS record sets related to privatelink
$recordSets = [System.Collections.Generic.List[PSObject]]::New()
$zones = Get-AzPrivateDnsZone -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name.StartsWith('privatelink.') }
foreach ($zone in $zones) {
    $recordSets += Get-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -ZoneName $zone.Name | Where-Object { $_.RecordType -eq 'A' }
}
#endregion

#region -- check all endpoints and ensure the DNS recordset exist or are created
$updateCount = 0

foreach ($endpoint in $endpoints) {
    $endpointName = $endpoint.fqdn.substring(0, $endpoint.fqdn.indexof('.'))
    $endpointZone = 'privatelink' + $endpoint.fqdn.substring($endpoint.fqdn.indexof('.'))

    # check for existing DNS Recordset
    $addNew = $false
    $match = $recordSets | Where-Object { $_.ZoneName -eq $endpointZone -and $_.Name -eq $endpointName }
    if ($match) {
        foreach ($ipAddress in $endpoint.IpAddresses) {
            if ($match.Records.Ipv4Address -contains $ipAddress) {
                Write-Verbose "$($endpointName).$($endpointZone) with $ipAddress already exists."
            }
            else {
                # IpAddress doesn't match
                Write-Information "$($endpointName).$($endpointZone) exists with $($match.Records.Ipv4Address). Replace record set with $ipAddress." -InformationAction Continue
                Remove-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -ZoneName $endpointZone -Name $match.Name -RecordType $match.RecordType
                $addNew = $true
            }
        }
    }
    else {
        $addNew = $true
    }

    # create a new DNS entry
    if ($addNew) {
        # check to make sure zone exists
        if ($zones.Name -notcontains $endpointZone) {
            Write-Information "creating zone $endpointZone" -InformationAction Continue
            $Zone = New-AzPrivateDnsZone -ResourceGroupName $ResourceGroupName -Name $endpointZone -ErrorAction Stop
        }

        # create recordset
        $records = @()
        foreach ($ipAddress in $endpoint.IpAddresses) {
            $records += New-AzPrivateDnsRecordConfig -Ipv4Address $ipAddress
        }
        Write-Information "Adding $($endpointName).$($endpointZone) with $($endpoint.IpAddresses -join ',')"  -InformationAction Continue
        $recordSet = New-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -Ttl 3600 -ZoneName $endpointZone  -Name $endpointName -RecordType 'A' -PrivateDnsRecords $records
        ++$updateCount
    }
}
#endregion

Write-Information "$updateCount DNS recordsets updated" -InformationAction Continue
