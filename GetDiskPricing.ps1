# only supported with Powershell .NET framework
# needs ParsedHTML support to parse table data

# 11/20/2019 - currently UltraSSD pricing is not listed on the page

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $Location,

    [Parameter(Mandatory = $false)]
    [string] $Path,

    [Parameter(Mandatory = $false)]
    [string] $Period = 'Monthly'
)

$locations = @{ }
$locations['eastasia'] = 'asia-pacific-east'
$locations['southeastasia'] = 'asia-pacific-southeast'
$locations['australiacentral'] = 'australia-central'
$locations['australiacentral2'] = 'australia-central-2'
$locations['australiaeast'] = 'australia-east'
$locations['australiasoutheast'] = 'australia-southeast'
$locations['brazilsouth'] = 'brazil-south'
$locations['canadacentral'] = 'canada-central'
$locations['canadaeast'] = 'canada-east'
$locations['centralindia'] = 'central-india'
$locations['northeurope'] = 'europe-north'
$locations['westeurope'] = 'europe-west'
$locations['francecentral'] = 'france-central'
$locations['francesouth'] = 'france-south'
$locations['germanycentral'] = 'germany-central'
$locations['germanynorth'] = 'germany-north'
$locations['germanynortheast'] = 'germany-northeast'
$locations['germanywestcentral'] = 'germany-west-central'
$locations['japaneast'] = 'japan-east'
$locations['japanwest'] = 'japan-west'
$locations['koreacentral'] = 'korea-central'
$locations['koreasouth'] = 'korea-south'
$locations['southafricanorth'] = 'south-africa-north'
$locations['southafricawest'] = 'south-africa-west'
$locations['southindia'] = 'south-india'
$locations['switzerlandnorth'] = 'switzerland-north'
$locations['switzerlandwest'] = 'switzerland-west'
$locations['uaecentral'] = 'uae-central'
$locations['uaenorth'] = 'uae-north'
$locations['uksouth'] = 'united-kingdom-south'
$locations['ukwest'] = 'united-kingdom-west'
$locations['centralus'] = 'us-central'
$locations['eastus'] = 'us-east'
$locations['eastus2'] = 'us-east-2'
$locations['usgovarizona'] = 'usgov-arizona'
$locations['usgovtexas'] = 'usgov-texas'
$locations['usgovvirginia'] = 'usgov-virginia'
$locations['northcentralus'] = 'us-north-central'
$locations['southcentralus'] = 'us-south-central'
$locations['westus'] = 'us-west'
$locations['westus2'] = 'us-west-2'
$locations['westcentralus'] = 'us-west-central'
$locations['westindia'] = 'west-india'

$Location = $Location.Replace(" ", "").Replace("-", "").Trim().ToLower()
if (-not $locations[$Location]) {
    Throw "$Location location not found."
}
$locationPricePattern = '(?<="' + $locations[$Location] + '":)(.*?)(?=[,}])'

class DiskPrice {
    [string] $instance
    [string] $diskSize
    [string] $monthlyCost
    [string] $iops
    [string] $throughput
}

$disks = @()

#################################################
Function IsNull {
    [CmdletBinding()]
    param (
        [float] $value,
        [string] $default
    )

    if ($value) {
        return $value
    }
    else {
        return $default
    }

}

#################################################

$priceUrl = 'https://azure.microsoft.com/en-us/pricing/details/managed-disks/'

$page = Invoke-WebRequest $priceUrl

$tables = $page.ParsedHtml.body.getElementsByTagName('Table')

for ($t = 0; $t -lt $tables.Length - 1; $t++) {
    Write-Progress -Activity "Parsing data..." -PercentComplete $($t / $tables.Length * 100)

    $table = $tables[$t]
    foreach ($row in $($table.rows | Select-Object -Skip 1)) {
        $disk = [DiskPrice]::New()
        $disk.instance = $($row.cells[0].innerHTML -replace "<\/*\w+?>", '' ).trim()
        $disk.diskSize = $($row.cells[1].innerHTML.Replace('/', '|') | Select-String -Pattern "^[^<]+" | % { $_.Matches } | % { $_.Value }).trim()
        $disk.monthlyCost = IsNull ([float] $($row.cells[2].innerHTML | Select-String -Pattern $locationPricePattern | % { $_.Matches } | % { $_.Value })) ''
        $disk.iops = $row.cells[3].innerHTML
        $disk.throughput = $row.cells[4].innerHTML

        $disks += $disk
    }
}

if ($Path) {
    $disks | Sort-Object -Property instance | Export-Csv -Path $Path -NoTypeInformation
}
else {
    $disks | Sort-Object -Property instance | ConvertTo-Csv -NoTypeInformation
}
