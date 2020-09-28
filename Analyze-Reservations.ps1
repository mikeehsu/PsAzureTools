<#
.SYNOPSIS
Analyze an Azure bill and show potential reservations

.DESCRIPTION
Analyze an Azure detailed usage bill and show VMs which are fully utilized (within a certain threshold) and disks which are of an eligible size.

.PARAMETER FilePath
Source path for the Azure Billing CSV file

.PARAMETER ShowDetails
Show the details behind the reservation recommendations

.PARAMETER ShowIneligibleVms
Show details for the virtual machines that were not recommended for reservation

.PARAMETER ShowIneligibleDisks
Show details for the disks that were not recommended for reservation

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
    [switch] $ShowDetails,

    [Parameter()]
    [switch] $ShowIneligibleVms,

    [Parameter()]
    [switch] $ShowIneligibleDisks,

    [Parameter()]
    [string] $ExcelPath,

    [Parameter()]
    [decimal] $VmUtilizationThreshold = 0.6,

    [Parameter()]
    [string] $Delimiter = ','
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
Write-Verbose "Loading column headers..."

$familySize = $null
$pageHTML = Invoke-WebRequest $FamilyUrl -UseBasicParsing
if ($pageHTML -and $pageHtml.StatusCode -eq 200) {
    $familySize = @{}
    $pageHTML.Content | ConvertFrom-Csv | ForEach-Object {
        $familySize[$_.ArmSkuName] = [PsCustomObject] @{
            ArmSkuName                   = $_.ArmSkuName
            InstanceSizeFlexibilityGroup = $_.InstanceSizeFlexibilityGroup
            Ratio                        = $_.Ratio
        }
    }
}
else {
    Write-Warning "Unable to load Family Flexibility Groups from $FamilyUrl, will use Meter Sub-Category as a proxy"
}
#endregion

#region -- find header row
Write-Verbose "Loading column headers..."

$sampleSize = 10
$rowCount = 0
$headerRowNumber = $null
$file = Get-Content -Path $filePath -Head $sampleSize -ErrorAction Stop
if (-not $file) {
    throw
}

foreach ($row in $file) {
    if ($row.Contains($Delimiter)) {
        $header = $row
        $headerRowNumber = $rowCount
        break
    }
    $rowCount++
}

if (-not $header) {
    throw "No delimiters found. Please check file or -Delimiter setting and try again."
}
#endregion

$nullDate = [DateTime] 0
$beginDate = [Datetime] 0
$endDate = [DateTime] 0

$rowCount = 0
$vms = @{}
$disks = @{}

Get-Content -Path $filePath -ErrorAction Stop |
Select-Object -Skip $headerRowNumber |
ConvertFrom-Csv -Delimiter $Delimiter |
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

    if ($row.'Meter Category' -eq 'Virtual Machines') {

        #summarize each VM
        $vm = $vms[$row.'Instance Id']
        if (-not $vm) {
            $vms[$row.'Instance ID'] = [ReserveVm]::New()

            $vm = $vms[$row.'Instance ID']
            $vm.ResourceGroup = $row.'Resource Group'
            $vm.Name = Split-Path $row.'Instance Id' -Leaf
            $vm.Location = $row.'Resource Location'

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
                $vm.Family = $row.'Meter Sub-Category'
            }
        }

        if ([DateTime] $row.'Date' -lt $vm.BeginDate -or $vm.BeginDate -eq $nullDate) {
            $vm.BeginDate = $row.'Date'
        }

        if ([DateTime] $row.'Date' -gt $vm.EndDate -or $vm.EndDate -eq $nullDate) {
            $vm.EndDate = $row.'Date'
        }

        $vm.Usage += $row.'Consumed Quantity'
        $vm.Cost += $row.'ExtendedCost'

    }
    elseif ($row.'Meter Category' -eq 'Storage' -and $row.'Meter Name'.EndsWith('Disks')) {
        # summarize disks
        $disk = $disks[$row.'Instance ID']
        if (-not $disk) {
            $disks[$row.'Instance ID'] = [ReserveDisk]::New()

            $disk = $disks[$row.'Instance ID']
            $disk.ResourceGroup = $row.'Resource Group'
            $disk.Name = Split-Path $row.'Instance Id' -Leaf
            $disk.Location = $row.'Resource Location'
            $disk.Size = $row.'Meter Name'.Replace(' Disks', '')
        }
        $disk.Usage += $row.'Consumed Quantity'
        $disk.Cost += $row.'ExtendedCost'
    }

    # update progress
    if (($rowCount % $BatchSize) -eq 0) {
        $percentage = $rowCount / $lineCount * 100
        Write-Progress -Activity "Analyzing $FilePath..." -Status "$rowCount of $lineCount processed" -PercentComplete $percentage
    }
}
Write-Progress -Activity "Analyzing $FilePath..." -Completed

# file post processing

#region -- calculate utilization rate
foreach ($key in $vms.Keys) {
    $vm = $vms[$key]

    if (-not $vm.EndDate) {
        $vm.EndDate = $vm.BeginDate
    }

    if ($vm.BeginDate -and $vm.EndDate) {
        $daysAlive = ([DateTime] $vm.EndDate - [DateTime] $vm.BeginDate).TotalDays + 1
        $vm.Utilization = $vm.Usage / ($daysAlive * 24)

        if ($vm.Utilization -ge $VmUtilizationThreshold -and $vm.FamilyRatio -ne 0 -and $vm.Cost -ne 0) {
            $vm.ReserveWorthy = $true
        }
    }
}
#endregion

# REPORT SUMMARY

# reservation eligible VMs
$reservationVms = $vms.Values
| Where-Object { $_.ReserveWorthy }
| ForEach-Object {
    [PSCustomObject] @{
        ResourceGroup = $_.ResourceGroup
        Name          = $_.Name
        BeginDate     = ('{0:M/d/yy}' -f $_.BeginDate)
        EndDate       = ('{0:M/d/yy}' -f $_.EndDate)
        Location      = $_.Location
        Family        = $_.Family
        FamilyRatio   = $_.FamilyRatio
        Size          = $_.Size
        CPU           = $_.CPU
        Usage         = $_.Usage
        Cost          = $_.Cost
        Utilization   = $_.Utilization
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

if ($ShowIneligibleVms) {
    Write-Output "Ineligible Virtual Machine Details"
    $ineligibleVms | Format-Table
}

# group by Family
Write-Output "Family Size Virtual Machine Summary"
$familySummary = $reservationVms
| Group-Object Location, Family
| ForEach-Object {
    $Location, $Family = ($_.Name -split ',').Trim()
    $Count = $_.Count
    $FamilyRatio, $CPU, $Cost = ($_.Group | Measure-Object -Property FamilyRatio, CPU, Cost -Sum ).Sum

    [PSCustomObject] @{
        Location    = $Location
        Family      = $Family
        Count       = $Count
        FamilyRatio = $FamilyRatio
        CPU         = $CPU
        Cost        = $Cost
    }
}
$familySummary | Format-Table

# disk reservations
$reservationDisks = $disks.Values
| Where-Object { $eligibleDisks -contains $_.Size -and $_.Cost -gt 0}
| ForEach-Object { [PSCustomObject] @{
        ResourceGroup = $_.ResourceGroup
        Name          = $_.Name
        Location      = $_.Location
        Size          = $_.Size
        Usage         = $_.Usage
        Cost          = $_.Cost
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

if ($ShowIneligibleDisks) {
    Write-Output "Ineligible Disks Details"
    $ineligibleDisks | Format-Table
}

# disk summary
$diskSummary = $reservationDisks
| Group-Object Location,Size
| ForEach-Object {
    $Location, $Size = ($_.Name -split ',').Trim()
    $Count = $_.Count
    $Cost = ($_.Group | Measure-Object -Property Cost -Sum ).Sum

    [PSCustomObject] @{
        Location = $Location
        Size     = $Size
        Count    = $Count
        Cost     = $Cost
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
        -PivotRows 'Location','Family','Size' -PivotData @{Name='Count'; FamilyRatio='Sum'; CPU='Sum'; Cost='Sum'} -PivotDataToColumn
    $reservationVms | Sort-Object -Property Family,Size,Name | Export-Excel $ExcelPath -WorkSheet 'Vm-Reservations' -AutoSize -AutoFilter -PivotTableDefinition $ptDef
    $ineligibleVms | Export-Excel $ExcelPath -WorksheetName 'Vm-Ineligible' -AutoSize -AutoFilter

    # export disks data
    $ptDef = New-PivotTableDefinition -Activate -PivotTableName 'Disk-Size-Summary' `
        -PivotRows 'Location','Size' -PivotData @{Name='Count'; Cost='Sum'} -PivotDataToColumn
    $reservationDisks | Sort-Object -Property Location,Size,Name | Export-Excel $ExcelPath -WorksheetName 'Disk-Reservations' -AutoSize -AutoFilter -PivotTableDefinition $ptDef
    $ineligibleDisks | Export-Excel $ExcelPath -WorksheetName 'Disk-Ineligible' -AutoSize -AutoFilter
}
