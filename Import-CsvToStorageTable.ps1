[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $StorageAccountName,

    [Parameter(Mandatory)]
    [string] $TableName,

    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter(Mandatory)]
    [string] $RowKey,

    [Parameter()]
    [string] $Delimiter = ',',

    [Parameter()]
    [int] $Skip = 0
)

$BatchSize = 100

# check for AzTable module
if (-not (Get-Module AzTable)) {
    try {
        Import-Module AzTable
    }
    catch {
        Write-Host "Please install the AzTable Storage PowerShell Module"
        exit 1
    }
}

# check for login
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}
catch {
    throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
}

# get table handle
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
$storageTable = Get-AzStorageTable -Name $TableName -Context $storageAccount.context -ErrorAction Stop
$cloudTable = $storageTable.CloudTable


#region -- Get rowcount of file
# get line count using streamreader, much faster than Get-Content for large files
$lineCount = 0
$fileInfo = $(Get-ChildItem $Path)
try {
    $reader = New-Object IO.StreamReader $($fileInfo.Fullname) -ErrorAction Stop
    while ($null -ne $reader.ReadLine()) {
        $lineCount++
    }
    $reader.Close()
} catch {
    throw
    exit 1
}

$lineCount = $lineCount - $Skip - 1
Write-Verbose "$lineCount lines in $($fileInfo.FullName)"
#endregion

$added = 0
$rowNumber = 0
Write-Progress -Activity "Loading rows to table..." -Status "$lineCount rows to add"

Get-Content -Path $Path -ErrorAction Stop |
    Select-Object -Skip $Skip |
    ConvertFrom-Csv -Delimiter $Delimiter |
    ForEach-Object  {
        $row = $_

        $rowNumber++
        if ($rowNumber -lt $StartOnDataRow) {
            continue
        }

        # build the property hash
        $hash = @{}
        $row.PSObject.Properties | ForEach-Object {
            if ($null -eq $_.Value) {
                $hash[$_.Name] = ''
            } else {
                $hash[$_.Name] = $_.Value
            }

            if ($_.Name -eq $RowKey) {
                $key = $_.Value
            }
        }

        try {
            $null = Add-AzTableRow -table $cloudTable -PartitionKey 1 -rowkey $key -property $hash
            $added++
        } catch {
            Write-Error -Exception $_.Exception
            Write-Error -Exception "Check data on $rowNumber"
        }

        # display progress
        if (($rowNumber % $BatchSize) -eq 0) {
            $percentage = $added / $lineCount * 100
            Write-Progress -Activity "Loading rows to table..." -PercentComplete $percentage
        }
}
Write-Progress -Activity "Loading rows to table..." -Completed

