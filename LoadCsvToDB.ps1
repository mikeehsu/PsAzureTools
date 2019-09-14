##############################
#.SYNOPSIS
# Load CSV file into a SQL database table.
#
#.DESCRIPTION
# This script is optimized to load a large delimited file into a
# SQL database. A mapping file provides the capability of mapping
# fields in the file to specific columns in the table. Additionally,
# the configuration allows text fields with JSON elements to be
# mapped to individual columns. (This script requires the SQLServer
# Powershell module)
#
#.PARAMETER FilePath
# This parameter specifies the path of the file to process.
#
#.PARAMETER ConfigFilePath
# This parameter specifies the path of the config file for
# mapping csv fields to table columns
#
#.PARAMETER DbServer
# This parameter specifies the SQL server to connect to
#
#.PARAMETER Database
# This parameter specifies the database to write the data to
#
#.PARAMETER Table
# This parameter specifies the table to write the data to
#
#.PARAMETER UserId
# This parameter specifies the userid for the database login
#
#.PARAMETER Password
# This parameter specifies the password for the database login
#
#.PARAMETER Delimiter
# This parameter specifies the delimiter to use when parsing the
# file specified in the -FilePath parameter
#
#.PARAMETER Skip
# This parameter specifies how many rows at the top to the
# file to skip. This should NOT include the header row that
# describes the columns.
#
#.PARAMETER BatchSize
# This parameter specifies how many rows to process before
# writing the results to the database.
#
#.PARAMETER StartOnDataRow
# This parameter specifies which data row to start loading on, 
# skipping unnecessary data rows immediately after the header.
#
#.EXAMPLE
# .\LoadCsvToDB.ps1 -FilePath SampleCsv.csv -ConfigFilePath .\Sample\SampleLoadCsvToDBForBilling.json
#
#.NOTES
#
##############################

Param (
    [Parameter(Mandatory=$true)]
    [string] $FilePath,

    [Parameter(Mandatory=$true)]
    [string] $ConfigFilePath,

    [Parameter(Mandatory=$true)]
    [string] $UserId,

    [Parameter(Mandatory=$true)]
    [string] $Password,

    [Parameter(Mandatory=$false)]
    [string] $DbServer,

    [Parameter(Mandatory=$false)]
    [string] $Database,

    [Parameter(Mandatory=$false)]
    [string] $Table,

    [Parameter(Mandatory=$false)]
    [string] $Delimiter,

    [Parameter(Mandatory=$false)]
    [string] $Skip,

    [Parameter(Mandatory=$false)]
    [int] $BatchSize,

    [Parameter(Mandatory=$false)]
    [int] $StartOnDataRow = 1
)

# load needed assemblies
Import-Module SqlServer

##############################
function MappingUpdateColumn {
    param (
        [array] $Mapping,
        [string] $FileColumn,
        [string] $DbColumn
    )

    # find all matching dbColumns
    $matches = (0..($mapping.Count-1)) | Where-Object {$mapping[$_].dbColumn -eq $DbColumn}
    if ($matches.Count -eq 0) {
        Write-Error "Unable to find table column: $DbColumn" -ErrorAction Stop
        return

    } elseif ($matches.Count -eq 0) {
        Write-Error "Found too many matching table columns for: $DbColumn" -ErrorAction Stop
        foreach ($i in $matches) {
            Write-Error $($mapping[$i].fileColumn) -ErrorAction Stop
        }
        return

    }

    $mapping[$matches[0]].fileColumn = $FileColumn
    return $mapping
}

#############################
function MappingProcessObject {

    Param (
        [array] $mapping,
        [PSCustomObject] $MapOverride,
        [string] $Prefix
    )

    foreach ($property in $mapOverride.PSObject.Properties) {
        if ($property.TypeNameOfValue -eq 'System.Management.Automation.PSCustomObject') {
            if ($Prefix) {
                $Prefix = $Prefix + ".'$($property.Name)'"
            } else {
                $Prefix = "'" + $property.Name + "'"
            }
            $mapping = MappingProcessObject -Mapping $mapping -MapOverride $property.Value -Prefix $Prefix

        } else {
            if ($Prefix) {
                $fileColumnName = $Prefix + ".'$($property.Name)'"
            } else {
                $fileColumnName = "'$($property.Name)'"
            }
            $mapping = $(MappingUpdateColumn -Mapping $mapping -FileColumn $fileColumnName -DbColumn $property.Value)
        }
    }

    return $mapping
}

##############################

[void][Reflection.Assembly]::LoadWithPartialName("System.Data")
[void][Reflection.Assembly]::LoadWithPartialName("System.Data.SqlClient")

$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

#REGION load mapping file
if ($ConfigFilePath) {
    $map = Get-Content $ConfigFilePath | ConvertFrom-Json

    if ($map.DbServer -and -not $DbServer) {
        $DbServer = $map.DbServer
    }

    if ($map.Database -and -not $Database) {
        $Database = $map.Database
    }

    if ($map.Table -and -not $Table) {
        $Table = $map.Table
    }

    if ($map.Delimiter -and -not $Delimiter) {
        $Delimiter = $map.Delimiter
    }

    if ($map.Skip -and -not $Skip) {
        $Skip = $map.Skip
    }

    if ($map.BatchSize -and -not $BatchSize) {
        $BatchSize = $map.BatchSize
    }
}

# check required parameters
if (-not $DBserver) {
    Write-Error '-DBServer must be supplied' -ErrorAction Stop
}

if (-not $Database) {
    Write-Error '-Database must be supplied' -ErrorAction Stop
}

if (-not $Table) {
    Write-Error '-Table must be supplied' -ErrorAction Stop
}

if (-not $Delimiter) {
    $Delimiter = ','
}

if (-not $Skip) {
    $Skip = 0
}

if (-not $BatchSize) {
    $BatchSize = 1000
}
#ENDREGION

$connectionString = "Server=$DbServer;Database=$Database;User Id=$UserId;Password=$Password"

#REGION create column mapping for row data
# get columns from table
$head = $Skip + 2 # skip down to header rows
Write-Verbose "Loading column headers..."
$fileColumns = Get-Content -Path $filePath -Head $head -ErrorAction Stop |
    Select-Object -Skip $skip |
    ConvertFrom-Csv -Delimiter $Delimiter

if (-not $fileColumns) {
    throw "No header found. Please check file and try again."
}

if ($($fileColumns | Get-Member -Type Properties | Measure-Object).Count -eq 1) {
    throw "No delimiters found. Please check file or -Delimiter setting and try again."
}

Write-Verbose "Getting columns from Usage table..."
$columns = Invoke-Sqlcmd -Query "SP_COLUMNS $Table" -ConnectionString $connectionString -ErrorAction Stop

$tableData = New-Object System.Data.DataTable
$tableRow = [Object[]]::new($columns.Count)

# map all columns from file that match database columns
$mapping = @()
for ($i=0; $i -lt $columns.Count; $i++) {
    $column = $columns[$i]

    $null = $tableData.Columns.Add($column.column_name)

    # find matching database columns & map them
    $match = $fileColumns | Get-Member -Type Properties | Where-Object {$_.name -eq $column.column_name}

    if ($match) {
        $matchConstant = $map.Constants.PSObject.Properties | Where-Object {$_.name -eq $column.column_name}
        if ($matchConstant) {
            # column also mapped to a constant, leave unmapped for constant to override later
            $fileColumnName = $null
        } else {
            $fileColumnName = "'" + $match.Name + "'"
        }
    } else {
        $fileColumnName = $null
    }

    $mapping += [PSCustomObject] @{
        fileColumn  = $fileColumnName
        dbColumn    = $column.column_name
        dbColumnNum = $i
    }
}

# override matches with columns in mapping file
if ($map) {
    $mapping = MappingProcessObject -Mapping $mapping -MapOverride $map.ColumnMappings
    if (-not $mapping) {
        return
    }
}

# check for any nested properties and map them to independent columns
$mapJsonItems = @()
foreach ($property in $map.ColumnMappings.PSObject.Properties) {
    if ($property.TypeNameOfValue -eq 'System.Management.Automation.PSCustomObject') {
        $mapJsonItems += $property.name
    }
}
#ENDREGION

#REGION Build all assignment expressions
# build column assignments
$rowExpression = ''
foreach ($item in $mapping) {
    if ((-not $item.fileColumn) -or (-not $item.dbColumn) -or ($item.fileColumn -eq "''")) {
        continue
    }

    if ($rowExpression) {
        $rowExpression += "; "
    }
    $rowExpression += "`$tableRow[$($item.dbColumnNum)] = `$fileRow." + $item.fileColumn
}

# build mapped JSON assignments
$expandJsonExpression = ''
for ($i=0; $i -lt $mapJsonItems.count; $i++) {
    if ($expandJsonxpression) {
        $expandJsonExpression += "; "
    }

    if ($map.ColumnWrapJson -and $map.ColumnWrapJson -contains $mapJsonItems[$i]) {
        # wrap brackets around JSON string
        $expandJsonExpression += "if (`$fileRow.`'$($mapJsonItems[$i])`') { `$fileRow.'" + $mapJsonItems[$i] + "' = '{' + `$fileRow.'" + $mapJsonItems[$i] + "' + '}' | ConvertFrom-Json }"   
    } else {
        $expandJsonExpression += "if (`$fileRow.`'$($mapJsonItems[$i])`') { `$fileRow.'" + $mapJsonItems[$i] + "' = `$fileRow.'" + $mapJsonItems[$i] + "' | ConvertFrom-Json }"
    }
}

# build constant assignments
$constantExpression = ''
foreach ($constant in $map.Constants.PSObject.Properties) {
    $match = $mapping | Where-Object {$_.dbColumn -eq $constant.name}
    if (-not $match) {
        Write-Error "No column found matching $($constant.name)" -ErrorAction Stop
        return
    }

    if ($constantExpression) {
        $constantExpression += "; "
    }
    $constantExpression += "`$tableRow[$($match.dbColumnNum)] = '" + $constant.value + "'"
}
#ENDREGION

# debug output
Write-Verbose "Constants: $constantExpression"
Write-Verbose "JSON expansion: $expandJsonExpression"
Write-Verbose "Mapped Columns: $rowExpression"

#REGION load the data from file
# get line count using streamreader, much faster than Get-Content for large files
$lineCount = 0
$fileInfo = $(Get-ChildItem $filePath)
try {
    $reader = New-Object IO.StreamReader $($fileInfo.Fullname) -ErrorAction Stop
    while ($reader.ReadLine() -ne $null) {
        $lineCount++
    }
    $reader.Close()
} catch {
    throw
    return
}

Write-Verbose "$lineCount lines in $($fileInfo.FullName)"
$lineCount -= $Skip + $StartOnDataRow

# create bulkcopy connection
$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connectionstring, [System.Data.SqlClient.SqlBulkCopyOptions]::TableLock)
$bulkcopy.DestinationTableName = $Table
$bulkcopy.bulkcopyTimeout = 0
$bulkcopy.batchsize = $Batchsize

Write-Verbose "Inserting data to table..."

# initialize constant values in tableRow
if ($constantExpression) {
    Invoke-Expression $constantExpression
}

$added = 0
$rowNumber = 0
if ($StartOnDataRow -gt 1) {
    Write-Progress -Activity "Loading rows to database..." -Status "Starting on row #$StartOnDataRow"
} else {
    Write-Progress -Activity "Loading rows to database..." -Status "$lineCount rows to add"
}

# Import-Csv -Path $filePath -Delimiter $Delimiter | ForEach-Object {
Get-Content -Path $filePath -ErrorAction Stop |
    Select-Object -Skip $Skip |
    ConvertFrom-Csv -Delimiter $Delimiter |
    ForEach-Object  {

    $rowNumber++
    if ($rowNumber -ge $StartOnDataRow) {

        $fileRow = $_

        # assign expanded JSON if any
        if ($expandJsonExpression) {
            Invoke-Expression $expandJsonExpression
        }

        # assign all the mappinge
        Invoke-Expression $rowExpression

        # load the SQL datatable
        $null = $tableData.Rows.Add($tableRow)
        $added++

        if (($added % $BatchSize) -eq 0) {
            try {
                $bulkcopy.WriteToServer($tableData)
            } catch {
                Write-Output "Error on or about row $i"
                Write-Output $tableData.Rows
                throw
                return
            } finally {
                $tableData.Clear()
            }
            $percentage = $added / $lineCount * 100
            Write-Progress -Activity "Loading rows to database..." -Status "$added of $lineCount added" -PercentComplete $percentage
        }
    }
}

if ($tableData.Rows.Count -gt 0) {
    $bulkcopy.WriteToServer($tableData)
    $tableData.Clear()
}

#ENDREGION

Write-Output "$added rows have been inserted into the database."
Write-Output "Total Elapsed Time: $($elapsed.Elapsed.ToString())"

# Clean Up
$bulkcopy.Close()
$bulkcopy.Dispose()

[System.GC]::Collect()
