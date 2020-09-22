<#
.SYNOPSIS
Expand a JSON field inside of a CSV file.

.DESCRIPTION
Expands the JSON inside of a column within a CSV file and appends the contents into separate columns at end of the original data.

.PARAMETER FilePath
Source path on the CSV file.

.PARAMETER OutputPath
Output path of the expanded data.

.PARAMETER Expand
Column names to expand.

.PARAMETER Delimiter
Delimiter to separate the property values in CSV strings.

.PARAMETER Skip
Number of rows to skip in the initial CSV file.

.PARAMETER SampleSize
Number of rows to sample for data in the JSON. This is used to create the column headings for the JSON elements

.PARAMETER BatchSize
Number of rows to cache before writing data to the output file

.EXAMPLE
Expand-CSVJSON.ps1 -FilePath MyCsvFile.txt -OutputPath MyExpanded.csv -Delimiter "`t" -Expand 'Tags'
#>


Param (
    [Parameter(Mandatory)]
    [string] $FilePath,

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [Parameter(Mandatory)]
    [array] $Expand,

    [Parameter()]
    [string] $Delimiter = ',',

    [Parameter()]
    [string] $Skip = 0,

    [Parameter()]
    [string] $SampleSize = 100,

    [Parameter()]
    [string] $BatchSize = 1000
)

#region -- Get rowcount of file
# get line count using streamreader, much faster than Get-Content for large files
$lineCount = 0
$fileInfo = $(Get-ChildItem $filePath)
try {
    $reader = New-Object IO.StreamReader $($fileInfo.Fullname) -ErrorAction Stop
    while ($null -ne $reader.ReadLine()) {
        $lineCount++
    }
    $reader.Close()
} catch {
    throw
    return
}
#endregion


#region -- Create column mapping for row data
# get columns from table
$head = $Skip + $SampleSize # skip down to header rows
Write-Verbose "Loading column headers..."
$fileColumns = Get-Content -Path $filePath -Head $head -ErrorAction Stop |
    Select-Object -Skip $skip |
    ConvertFrom-Csv -Delimiter $Delimiter

if (-not $fileColumns) {
    throw "No header found. Please check file and try again."
}

if ($($fileColumns[0] | Get-Member -Type Properties | Measure-Object).Count -eq 1) {
    throw "No delimiters found. Please check file or -Delimiter setting and try again."
}

# create a list of all json labels
Write-Verbose "Sampling data for expanded columns.."
$expandColumns = @{}
foreach($row in $fileColumns) {
    foreach ($expandField in $Expand) {
        if (-not $expandColumns[$expandField]) {
            $expandColumns[$expandField] = [PSCustomObject] @{
                ColumnName = $expandField
                ColumnObject = [PSCustomObject]@{}
                Properties = @()
            }
        }

        if ($json = Invoke-Expression ('$row.' + $expandField) | ConvertFrom-Json) {
            foreach($property in ($json | Get-Member -MemberType NoteProperty)) {
                if ($expandColumns[$expandField].Properties -notcontains $property.Name) {
                    $expandColumns[$expandField].Properties += $property.Name
                    $expandColumns[$expandField].ColumnObject | Add-Member $property.Name -MemberType NoteProperty -Value $null
                }
            }
        }
    }
}
#endregion

$outputCache = @()
$rowCount = 0
Get-Content -Path $filePath -ErrorAction Stop |
    Select-Object -Skip $Skip |
    ConvertFrom-Csv -Delimiter $Delimiter |
    ForEach-Object  {

    $rowCount++
    $fileRow = $_

    #region -- write the output file header row 
    if ($rowCount -eq 1) {
        $outLine = ''
        $csvLine = $fileRow | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter
        $outLine = $csvLine[0]

        $labels = @()
        foreach ($column in $expandColumns.Values) {
            foreach ($label in $column.properties) {
                $labels += '"' + $column.ColumnName + ':' + $label + '"'
            }
        }
        $outLine = $csvLine[0] + $Delimiter + ($labels -join $Delimiter)
        $outLine | Out-File -FilePath $OutputPath
        Write-Progress -Activity "Creating $outputPath..." 
    }
    #endregion

    # copy original data
    $csvLine = ($fileRow | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter)[1]

    #region -- build expanded columns
    foreach ($column in $expandColumns.Values) {
        $outObj = $column.ColumnObject
        # $json = Invoke-Expression ('$fileRow.' + $column.ColumnName + ' | ConvertFrom-Json')
        $json = $fileRow.($column.ColumnName) | ConvertFrom-Json
        foreach ($property in $column.Properties) {
            $outObj.$property = $json.$property
        }

        # add expanded column to output data
        $csvLine += $Delimiter + ($outObj | ConvertTo-Csv -NoTypeInformation -Delimiter $Delimiter)[1]
    }
    #endregion

    # cache output for speed
    $outputCache += $csvLine

    # flush the output cache
    if (($rowCount % $BatchSize) -eq 0) {
        $outputCache | Out-File -FilePath $OutputPath -Append
        $outputCache.Clear()

        $percentage = $rowCount / $lineCount * 100
        Write-Progress -Activity "Creating $outputPath..." -Status "$rowCount of $lineCount expanded" -PercentComplete $percentage
    }

}

$outputCache | Out-File -FilePath $OutputPath -Append
Write-Progress -Activity "Creating $outputPath..."  -Completed
