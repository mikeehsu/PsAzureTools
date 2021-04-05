[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string] $ResourceGroupName
)

# get all the private endpoints in the tenant
$endpoints = Search-AzGraph -Query "Resources
| where type =~ 'Microsoft.Network/privateEndpoints'
| mv-expand dnsConfig=properties.customDnsConfigs
| project Id = id, Name = name, fqdn = tostring(dnsConfig.fqdn), ipAddresses = dnsConfig.ipAddresses"

# load all current DNS record sets related to privatelink
$recordSets = [System.Collections.ArrayList] @()
$zones = Get-AzPrivateDnsZone -ResourceGroupName $ResourceGroupName | Where-Object {$_.Name.StartsWith('privatelink.')}
foreach ($zone in $zones) {
    $recordSets += Get-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -ZoneName $zone.Name | Where-Object {$_.RecordType -eq 'A'}
}

# check all endpoints and ensure the DNS recordset exist or are created
foreach ($endpoint in $endpoints) {
    $endpointName = $endpoint.fqdn.substring(0,$endpoint.fqdn.indexof('.'))
    $endpointZone = 'privatelink' + $endpoint.fqdn.substring($endpoint.fqdn.indexof('.'))

    # check for existing DNS Recordset
    $addNew = $false
    $match = $recordSets | Where-Object {$_.ZoneName -eq $endpointZone -and $_.Name -eq $endpointName}
    if ($match) {
        foreach ($ipAddress in $endpoint.IpAddresses) {
            if ($match.Records.Ipv4Address -contains $ipAddress) {
                Write-Verbose "$($endpointName).$($endpointZone) with $ipAddress already exists."
            } else {
                # IpAddress doesn't match
                Write-Verbose "$($endpointName).$($endpointZone) exists with $($match.Records.Ipv4Address). Replace record set with $ipAddress."
                Remove-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -ZoneName $endpointZone -Name $match.Name -RecordType $match.RecordType
                $addNew = $true
            }
        }
    } else {
        $addNew = $true
    }

    # create a new DNS Recordset
    if ($addNew) {
        if ($recordSets.ZoneName -notcontains $endpointZone) {
            Write-Verbose "creating zone $endpointZone"
            $Zone = New-AzPrivateDnsZone -ResourceGroupName $ResourceGroupName -Name $endpointZone -ErrorAction Stop
        }

        $records = @()
        foreach ($ipAddress in $endpoint.IpAddresses) {
            $records += New-AzPrivateDnsRecordConfig -Ipv4Address $ipAddress
        }
        Write-Verbose "Adding $($endpointName).$($endpointZone) with $($endpoint.IpAddresses -join ',')"
        $recordSet = New-AzPrivateDnsRecordSet -ResourceGroupName $ResourceGroupName -TTL 3600 -ZoneName $endpointZone  -Name $endpointName -RecordType 'A' -PrivateDnsRecords $records
    }
}

