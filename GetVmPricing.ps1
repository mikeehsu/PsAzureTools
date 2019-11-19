# only supported with Powershell .NET framework
# needs ParsedHTML support in

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $Location,

    [Parameter(Mandatory = $false)]
    [string] $Path,

    [Parameter(Mandatory = $false)]
    [string] $Period = 'Monthly',

    [Parameter(Mandatory = $false)]
    [string] $OsType = 'Windows'
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

$factor = 730
if ($Period -eq "Daily") {
    $factor = 1
}

class VmPrice {
    [string] $instance
    [string] $vcpu
    [string] $memory
    [string] $storage
    [string] $payg
    [string] $ri1year
    [string] $ri3year
    [string] $ahub
}

$vms = @()

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

if ($OsType -eq 'windows') {
    $priceUrl = 'https://azure.microsoft.com/en-us/pricing/details/virtual-machines/windows/'
}
elseif ($OsType -eq 'linux') {
    $priceUrl = 'https://azure.microsoft.com/en-us/pricing/details/virtual-machines/linux/'
}
elseif ($OsType -eq 'redhat') {
    $priceUrl = 'https://azure.microsoft.com/en-us/pricing/details/virtual-machines/red-hat/'
}
else {
    Throw "Invalid -OSType $OsType provided"
}

$page = Invoke-WebRequest $priceUrl

$tables = $page.ParsedHtml.body.getElementsByTagName('Table')

for ($t = 0; $t -lt $tables.Length - 2; $t++) {
    $table = $tables[$t]
    foreach ($row in $($table.rows | Select-Object -Skip 1)) {
        $vm = [VmPrice]::New()
        $vm.instance = $($row.cells[1].innerHTML | Select-String -Pattern "^[^<]+" | % { $_.Matches } | % { $_.Value }).trim()
        $vm.vcpu = $($row.cells[2].innerHTML | Select-String -Pattern "^[^<]+" | % { $_.Matches } | % { $_.Value }).trim()
        $vm.memory = $row.cells[3].innerHTML
        $vm.storage = $row.cells[4].innerHTML
        $vm.payg = IsNull ([float] $($row.cells[5].innerHTML | Select-String -Pattern $locationPricePattern | % { $_.Matches } | % { $_.Value }) * $factor) ''
        $vm.ri1year = IsNull ([float] $($row.cells[6].innerHTML | Select-String -Pattern $locationPricePattern | % { $_.Matches } | % { $_.Value }) * $factor) ''
        $vm.ri3year = IsNull ([float] $($row.cells[7].innerHTML | Select-String -Pattern $locationPricePattern | % { $_.Matches } | % { $_.Value }) * $factor) ''
        $vm.ahub = IsNull ([float] $($row.cells[8].innerHTML | Select-String -Pattern $locationPricePattern | % { $_.Matches } | % { $_.Value }) * $factor) ''

        $vms += $vm
    }
}

if ($Path) {
    $vms | Export-Csv -Path $Path -NoTypeInformation
}
else {
    $vms | ConvertTo-Csv
}
