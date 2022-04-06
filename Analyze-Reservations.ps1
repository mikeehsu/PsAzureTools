<#
.SYNOPSIS
Analyze an Azure bill and show potential reservations

.DESCRIPTION
Analyze an Azure detailed usage bill and show VMs which are fully utilized (within a certain threshold) and disks which are of an eligible size.

.PARAMETER FilePath
Source path for the Azure Billing CSV file


.PARAMETER VmUtilizationThreshold
Only show Virtual Machines that pass a certain utilization threshold. Default is 0.6

.PARAMETER Delimiter
Delimiter to use for the Azure Billing CSV File. Default to ','

.EXAMPLE
Analyze-Reservations.ps1 -FilePath MyAzureBill.csv -ShowDetails -ExcelPath MyExcelResults.xlsx
#>

Param (
    [Parameter(Mandatory)]
    [string] $FilePath,

    [Parameter()]
    [string] $FamilySizeFilePath,

    [Parameter()]
    [switch] $ShowDetails,

    [Parameter()]
    [switch] $IncludeReservedVMs,

    [Parameter()]
    [string] $ExcelPath,

    [Parameter()]
    [decimal] $VmUtilizationThreshold = 0.6,

    [Parameter()]
    [string] $Delimiter = ',',

    [Parameter()]
    [string] $PriceLocation = 'USGovVirginia'
)

Set-StrictMode -Version 3

$BatchSize = 1000
$FamilyURL = 'https://isfratio.blob.core.windows.net/isfratio/ISFRatio.csv'
$eligibleDisks = @('P30', 'P40', 'P50', 'P60', 'P70', 'P80')

# check for installed modules
if ($ExcelPath)
{
    if (Get-Module -ListAvailable -Name ImportExcel) {
        Import-Module ImportExcel
    } else {
        Write-Host "To use -ExcelPath, you must have ImportExcel installed. Please use Install-Module ImportExcel to download and install module"
    }
}

#region -- define structures for resources
Class ReserveVm {
    [string] $ResourceGroup
    [string] $Name
    [string] $Location
    [DateTime] $BeginDate = [DateTime] 0
    [DateTime] $EndDate = [DateTime] 0
    [string] $Family
    [int] $FamilyRatio
    [string] $Size
    [int] $CPU
    [decimal] $Rate
    [decimal] $Usage = 0
    [decimal] $Cost = 0
    [decimal] $Utilization = 0
    [bool] $ReserveWorthy = $false
}

Class ReserveDisk {
    [string] $ResourceGroup
    [string] $Name
    [string] $Location
    [string] $Size
    [decimal] $Usage = 0
    [decimal] $Cost
}
#endregion

#region -- Get rowcount of file
# get line count using streamreader, much faster than Get-Content for large files
$lineCount = 0
$fileInfo = $(Get-ChildItem $FilePath)
try {
    $reader = New-Object IO.StreamReader $($fileInfo.Fullname) -ErrorAction Stop
    while ($null -ne $reader.ReadLine()) {
        $lineCount++
    }
    $reader.Close()
}
catch {
    throw
    return
}
#endregion

#region -- load family info
Write-Verbose "Loading Family Info..."

$familySize = @{}

if ($FamilySizeFilePath) {
    Get-Content -Path $FamilySizeFilePath | ConvertFrom-Csv | ForEach-Object {
        $familySize[$_.ArmSkuName] = [PsCustomObject] @{
            ArmSkuName                   = $_.ArmSkuName
            InstanceSizeFlexibilityGroup = $_.InstanceSizeFlexibilityGroup
            Ratio                        = $_.Ratio
        }
    }

} else {
    $header = $null
    $pageHTML = Invoke-WebRequest $FamilyUrl -UseBasicParsing
    if ($pageHTML -and $pageHtml.StatusCode -eq 200) {
        ($pageHTML.RawContent -split '\r?\n').Trim() | ForEach-Object {
            $row = $_

            if ($header) {
                # header has been set
                $rowData = $row | ConvertFrom-Csv -Header $header
                if ($rowData) {
                    $familySize[$rowData.ArmSkuName] = [PsCustomObject] @{
                        ArmSkuName                   = $rowData.ArmSkuName
                        InstanceSizeFlexibilityGroup = $rowData.InstanceSizeFlexibilityGroup
                        Ratio                        = $rowData.Ratio
                    }
                }
            } else {
                # look for header
                if ($row.Contains('InstanceSizeFlexibilityGroup')) {
                    $header = $row.Replace('?','') -Split ','
                }
            }

        }
    }
    else {
        Write-Warning "Unable to load Family Flexibility Groups from $FamilyUrl, will use Meter Sub-Category as a proxy"
    }
}
#endregion

#region -- find header row
Write-Verbose "Loading column headers..."

$sampleSize = 10
$file = Get-Content -Path $filePath -Head $sampleSize -ErrorAction Stop
if (-not $file) {
    throw
}

$headerRowCount = 0
$headerFound = $false
foreach ($row in $file) {
    $headerRowCount++
    if ($row.Contains('Subscription')) {
        $headerFound = $true
        break
    }
}
if (-not $headerFound) {
    throw "No header found. Please check $filePath and try again."
}
$row = $row.Replace(' ', '')
$row = $row.Replace('ExtendedCost', 'Cost')
$row = $row.Replace('ResourceId', 'InstanceId')
$row = $row.Replace('Quantity', 'ConsumedQuantity')
$header = $row -Split $Delimiter
$header

#endregion

$nullDate = [DateTime] 0
$beginDate = [Datetime] 0
$endDate = [DateTime] 0

$rowCount = 0
$vms = @{}
$disks = @{}

Get-Content -Path $filePath -ErrorAction Stop |
Select-Object -Skip $headerRowCount |
ConvertFrom-Csv -Delimiter $Delimiter -Header $header |
ForEach-Object {
    $rowCount++
    $row = $_

    #region -- get max/min dates
    if ([DateTime] $row.'Date' -lt $beginDate -or $beginDate -eq $nullDate) {
        $beginDate = [DateTime] $row.'Date'
    }
    elseif ([DateTime] $row.'Date' -gt $endDate -or $endDate -eq $nullDate) {
        $endDate = [DateTime] $row.'Date'
    }
    #endregion

    if ($row.'MeterCategory' -eq 'Virtual Machines') {

        #summarize each VM
        $vm = $vms[$row.'InstanceId']
        if (-not $vm) {
            $vms[$row.'InstanceId'] = [ReserveVm]::New()

            $vm = $vms[$row.'InstanceId']
            $vm.ResourceGroup = $row.'ResourceGroup'
            $vm.Name = Split-Path $row.'InstanceId' -Leaf
            $vm.Location = $row.'ResourceLocation'
            # $vm.Rate = $row.'ResourceRate'

            # AdditionalInfo
            $additionalInfo = $row.'AdditionalInfo' | ConvertFrom-Json
            $vm.Size = $additionalInfo.ServiceType
            $vm.CPU = $additionalInfo.VCPUs

            if ($familySize) {
                $familyInfo = $familySize[$vm.Size.Replace('_Promo','')] # -- must account for _PROMO SKUs
                if ($familyInfo) {
                    $vm.Family = $familyInfo.InstanceSizeFlexibilityGroup
                    $vm.FamilyRatio = $familyInfo.Ratio
                }
            }
            else {
                $vm.Family = $row.'MeterSubCategory'
            }
        }

        if ([DateTime] $row.'Date' -lt $vm.BeginDate -or $vm.BeginDate -eq $nullDate) {
            $vm.BeginDate = $row.'Date'
        }

        if ([DateTime] $row.'Date' -gt $vm.EndDate -or $vm.EndDate -eq $nullDate) {
            $vm.EndDate = $row.'Date'
        }

        $vm.Usage += $row.'ConsumedQuantity'
        $vm.Cost += $row.'Cost'

    }
    elseif ($row.'MeterCategory' -eq 'Storage' -and $row.'MeterName'.EndsWith('Disks')) {
        # summarize disks
        $disk = $disks[$row.'InstanceId']
        if (-not $disk) {
            $disks[$row.'InstanceId'] = [ReserveDisk]::New()

            $disk = $disks[$row.'InstanceId']
            $disk.ResourceGroup = $row.'ResourceGroup'
            $disk.Name = Split-Path $row.'InstanceId' -Leaf
            $disk.Location = $row.'ResourceLocation'
            $disk.Size = $row.'MeterName'.Replace(' Disks', '')
        }
        $disk.Usage += $row.'ConsumedQuantity'
        $disk.Cost += $row.'Cost'
    }

    # update progress
    if (($rowCount % $BatchSize) -eq 0) {
        $percentage = $rowCount / $lineCount * 100
        Write-Progress -Activity "Analyzing $FilePath..." -Status "$rowCount of $lineCount processed" -PercentComplete $percentage
    }
}
Write-Progress -Activity "Analyzing $FilePath..." -Completed

# file post processing


# load VM pricing table
Write-Verbose 'Getting pricing information for Virtual Machines...'
$vmPriceTable = @{}
.\Get-PriceTable.ps1 -Location $PriceLocation -Product 'VirtualMachines' | ForEach-Object {
    $vmPriceTable[$_.name] = $_
}

#region -- calculate utilization rate
foreach ($key in $vms.Keys) {
    $vm = $vms[$key]

    if (-not $vm.EndDate) {
        $vm.EndDate = $vm.BeginDate
    }

    if ($vm.BeginDate -and $vm.EndDate) {
        $daysAlive = ([DateTime] $vm.EndDate - [DateTime] $vm.BeginDate).TotalDays + 1
        $vm.Utilization = $vm.Usage / ($daysAlive * 24)

        if ($vm.Utilization -ge $VmUtilizationThreshold -and
            $vm.FamilyRatio -ne 0 -and
            ($vm.Cost -ne 0 -or $IncludeReservedVMs) -and
            $vmPriceTable[$vm.Size].RI1YearPrice -ne 0 -and
            $vmPriceTable[$vm.Size].RI3YearPrice -ne 0) {

            $vm.ReserveWorthy = $true
        }
    }
}
#endregion

# REPORT SUMMARY

# filter eligible VMs and estimate RI costs
$reservationVms = $vms.Values
| Where-Object { $_.ReserveWorthy }
| ForEach-Object {
    $vmPrice = $vmPriceTable[$_.Size]
    if ($vmPrice) {
        $PAYGPrice       = $vmPrice.paygPrice
        $RI1YearPrice    = $vmPrice.RI1YearPrice
        $RI3YearPrice    = $vmPrice.RI3YearPrice
    } else {
        $paygPrice = 0
        $RI1YearPrice = 0
        $RI3YearPrice = 0
    }

    [PSCustomObject] @{
        ResourceGroup   = $_.ResourceGroup
        Name            = $_.Name
        BeginDate       = ('{0:M/d/yy}' -f $_.BeginDate)
        EndDate         = ('{0:M/d/yy}' -f $_.EndDate)
        Location        = $_.Location
        Family          = $_.Family
        FamilyRatio     = $_.FamilyRatio
        Size            = $_.Size
        CPU             = $_.CPU
        Rate            = $_.Rate
        Usage           = $_.Usage
        Cost            = $_.Cost
        Utilization     = $_.Utilization
        PAYG            = $PAYGPrice
        PAYGYearCost    = $PAYGPrice * 12
        RI1YearDiscount = ($PAYGPrice - $RI1YearPrice)/$PAYGPrice
        EstRI1YearCost  = $RI1YearPrice * 12
        RI3YearDiscount = ($PAYGPrice - $RI3YearPrice)/$PAYGPrice
        EstRI3YearCost  = $RI3YearPrice * 12
    }
}

if ($ShowDetails) {
    Write-Output "Recommended Virtual Machine Details"
    $reservationVms | Format-Table
}

# ineligible VMs
$ineligibleVms = $vms.Values
| Where-Object { -not $_.ReserveWorthy }
| ForEach-Object { [PSCustomObject] @{
        ResourceGroup = $_.ResourceGroup
        Name          = $_.Name
        BeginDate     = ('{0:M/d/yy}' -f $_.BeginDate)
        EndDate       = ('{0:M/d/yy}' -f $_.EndDate)
        Location      = $_.Location
        Family        = $_.Family
        Size          = $_.Size
        CPU           = $_.CPU
        Usage         = $_.Usage
        Cost          = $_.Cost
        Utilization   = $_.Utilization
    }
}

# if ($ShowIneligibleVms) {
#     Write-Output "Ineligible Virtual Machine Details"
#     $ineligibleVms | Format-Table
# }

# # group by Family
# Write-Output "Family Size Virtual Machine Summary"
# $familySummary = $reservationVms
# | Group-Object Location, Family
# | ForEach-Object {
#     $Location, $Family = ($_.Name -split ',').Trim()
#     $Count = $_.Count
#     $FamilyRatio, $CPU, $Cost, $EstRI1YearCost, $EstRI3YearCost = ($_.Group | Measure-Object -Property FamilyRatio, CPU, Cost, EstRIYearCost, EstRI3YearCost -Sum).Sum

#     [PSCustomObject] @{
#         Location    = $Location
#         Family      = $Family
#         Count       = $Count
#         FamilyRatio = $FamilyRatio
#         CPU         = $CPU
#         Cost        = $Cost
#         EstRI1YearCost = $EstRI1YearCost
#         EstRI3YearCost = $EstRI3YearCost
#     }
# }
# $familySummary | Format-Table

# disk reservations
# load VM pricing table
Write-Verbose 'Getting pricing information for Disks...'
$diskPriceTable = @{}
.\Get-PriceTable.ps1 -Location $PriceLocation -Product 'Disks' | ForEach-Object {
    $disk = $_
    $name = $_.Name.split(' ')[0]
    $diskPriceTable[$name] = $disk
}

$reservationDisks = $disks.Values
| Where-Object { $eligibleDisks -contains $_.Size -and ($_.Cost -gt 0 -or $IncludeReservedVMs) }
| ForEach-Object { [PSCustomObject] @{
        ResourceGroup   = $_.ResourceGroup
        Name            = $_.Name
        Location        = $_.Location
        Size            = $_.Size
        Usage           = $_.Usage
        Cost            = $_.Cost
        PAYGYearCost    = $diskPriceTable[$_.Size].PaygPrice * 12
        EstRI1YearCost  = $diskPriceTable[$_.Size].RI1YearPrice * 12
    }
}

if ($ShowDetails) {
    Write-Output "Recommended Disks Details"
    $reservationDisks | Format-Table
}

# ineligile disks
$ineligibleDisks = $disks.Values
| Where-Object { $eligibleDisks -notcontains $_.Size -or $_.Cost -eq 0}
| ForEach-Object { [PSCustomObject] @{
        ResourceGroup = $_.ResourceGroup
        Name          = $_.Name
        Location      = $_.Location
        Size          = $_.Size
        Usage         = $_.Usage
        Cost          = $_.Cost
    }
}

# if ($ShowIneligibleDisks) {
#     Write-Output "Ineligible Disks Details"
#     $ineligibleDisks | Format-Table
# }

# disk summary
$diskSummary = $reservationDisks
| Group-Object Location,Size
| ForEach-Object {
    $Location, $Size = ($_.Name -split ',').Trim()
    $Count = $_.Count
    $Cost, $EstRI1YearCost = ($_.Group | Measure-Object -Property Cost,EstRI1YearCost -Sum ).Sum

    [PSCustomObject] @{
        Location     = $Location
        Size         = $Size
        Count        = $Count
        Cost         = $Cost
        EstRI1YearCost = $EstRI1YearCost
    }
}
Write-Output "Recommended Disks Summary"
$diskSummary | Format-Table

$totalDays = ([DateTime] $endDate - [DateTime] $beginDate).TotalDays + 1

Write-Output ("Date Range: {0:M/dd/yyyy} thru {1:M/dd/yyyy}" -f $beginDate, $endDate)
Write-Output "# of Days: $totalDays"
Write-Output ""
Write-Output "# of Virtual Machines identified: $($vms.Count)"
Write-Output "# of Virtual Machines recommended: $($reservationVms.Count)"
Write-Output "# of Virtual Machines not recommended: $($ineligibleVms.Count)"
Write-Output ""
Write-Output "# of Disks identified: $($disks.Count)"
Write-Output "# of Disks recommended: $($reservationDisks.Count)"
Write-Output "# of Disks Ineligible: $($ineligibleDisks.Count)"

if ($ExcelPath) {
    if (Test-Path $ExcelPath) {
        Remove-Item $ExcelPath
    }

    # export Vm data
    $ptDef = New-PivotTableDefinition -Activate -PivotTableName 'Vm-Family-Summary' `
        -PivotRows 'Location','Family','Size' -PivotData @{Name='Count'; FamilyRatio='Sum'; CPU='Sum'; Cost='Sum'; PAYGYearCost='Sum'; EstRI1YearCost='Sum'; EstRI3YearCost='Sum'} -PivotDataToColumn
    $reservationVms | Sort-Object -Property Family,Size,Name | Export-Excel $ExcelPath -WorkSheet 'Vm-Reservations' -AutoSize -AutoFilter -PivotTableDefinition $ptDef
    $ineligibleVms | Export-Excel $ExcelPath -WorksheetName 'Vm-Ineligible' -AutoSize -AutoFilter

    # export disks data
    $ptDef = New-PivotTableDefinition -Activate -PivotTableName 'Disk-Size-Summary' `
        -PivotRows 'Location','Size' -PivotData @{Name='Count'; Cost='Sum'; EstRI1YearCost='Sum'} -PivotDataToColumn
    $reservationDisks | Sort-Object -Property Location,Size,Name | Export-Excel $ExcelPath -WorksheetName 'Disk-Reservations' -AutoSize -AutoFilter -PivotTableDefinition $ptDef
    $ineligibleDisks | Export-Excel $ExcelPath -WorksheetName 'Disk-Ineligible' -AutoSize -AutoFilter
}
