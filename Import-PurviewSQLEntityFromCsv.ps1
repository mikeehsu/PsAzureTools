<#
.SYNOPSIS
    Manages metadata related to databases, tables, and columns in Azure Purview.

.DESCRIPTION
    This script provides a set of parameters for interacting with Azure Purview. It allows you to manage metadata associated with databases, tables, and columns. Use this script to streamline metadata operations within your Azure environment.

.PARAMETER Path
    Specifies the path to the CSV metadata file.

.PARAMETER ResourceGroupName
    The name of the Azure Resource Group.

.PARAMETER PurviewAccountName
    The name of the Azure Purview Account.

.PARAMETER DbServerName
    The name of the database server. This database server name will be applied to the entire file. This parameter cannot be used with -DbServerHeader.

.PARAMETER DbServerHeader
    The header of the column that contains the database server name. This parameter cannot be used with -DbServerName.

.PARAMETER DbInstanceName
    The name of the database instance (default: 'MSSQLSERVER'). This database instance name will be applied to the entire file. This cannot be used with -DbInstanceHeader.

.PARAMETER DbInstanceHeader
    The header of the column that contains the database instance name. This cannot be used with -DbInstanceName.

.PARAMETER SchemaName
    The name of the database schema (default: 'dbo'). This database schema name will be applied to the entire file. This parameter cannot be used with -SchemaHeader.

.PARAMETER SchemaHeader
    The header of the column that contains the database schema name. This parameter cannot be used with -SchemaName.

.PARAMETER DbName
    The name of the database. This database name will be applied to the entire file. This parameter cannot be used with -DbHeader.

.PARAMETER DbHeader
    The header of the column that contains the database name. This parameter cannot be used with -DbName.

.PARAMETER TableName
    The name of the table. This table name will be applied to the entire file. This parameter cannot be used with -TableHeader.

.PARAMETER TableHeader
    The header for the table.

.PARAMETER ColumnHeader
    The header for the column.

.PARAMETER DataTypeHeader
    The header for the data type.

.PARAMETER DescriptionHeader
    Optional description for the table or column.

.PARAMETER GlossaryName
    The name of the glossary to lookup the glossary term. If this is used, -GlossaryHeader must also be specified.

.PARAMETER  GlossaryHeader
    The header of the column that contains the glossary terms to apply. If this is used, -GlossaryName must also be specified.

.PARAMETER ClassificationHeader
    The header for classification information.

.EXAMPLE
    .\Manage-PurviewMetadata.ps1 -Path "C:\MyResource" -ResourceGroupName "MyRG" -PurviewAccountName "MyPurview" -DbServerName "MyServer" -DbInstanceName "SQL2019" -DbName "MyDatabase" -TableHeader "MyTable" -ColumnHeader "MyColumn" -DataTypeHeader "nvarchar(50)" -DescriptionHeader "This table contains customer data."

.NOTES
    - Ensure you have the necessary Azure credentials.
    - Run this script with the required parameters to manage metadata in Azure Purview.
    - Handle any errors that may occur during execution.
#>

#Requires -Modules Az.Accounts, Az.Purview

param(

    [Parameter(Mandatory = $true)]
    [string] $Path,

    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string] $PurviewAccountName,

    [Parameter()]
    [string] $DbServerName,

    [Parameter()]
    [string] $DbServerHeader,

    [Parameter()]
    [string] $DbInstanceName = 'MSSQLSERVER',

    [Parameter()]
    [string] $DbInstanceHeader,

    [Parameter()]
    [string] $SchemaName = 'dbo',

    [Parameter()]
    [string] $SchemaHeader,

    [Parameter()]
    [string] $DbName,

    [Parameter()]
    [string] $DbHeader,

    [Parameter()]
    [string] $TableName,

    [Parameter()]
    [string] $TableHeader = 'Table',

    [Parameter(Mandatory = $true)]
    [string] $ColumnHeader = 'Column',

    [Parameter(Mandatory = $true)]
    [string] $DataTypeHeader = 'DataType',

    [Parameter()]
    [string] $DescriptionHeader,

    [Parameter()]
    [string] $GlossaryName,

    [Parameter()]
    [string] $GlossaryHeader,

    [Parameter()]
    [string] $ClassificationHeader
)


function CreateSchema {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $ServerName,

        [Parameter()]
        [string] $DbInstanceName,

        [Parameter()]
        [string] $DbName,

        [Parameter()]
        [string] $SchemaName
    )

    $entities = @()


    # build database entity
    $global:guid--
    $dbGuid = $global:guid.ToString()

    $database = [PSCustomObject] @{
        typeName = 'mssql_db'
        guid = $dbGuid
        attributes = [PSCustomObject] @{
            qualifiedName = "mssql://$ServerName/$DbInstanceName/$DbName"
            name = $DbName
        }
        relationshipAttributes = @{}
    }
    $entities = $entities + $database

    # build schema entity
    $global:guid--
    $schemaGuid = $global:guid.ToString()

    $schema = [PSCustomObject] @{
        typeName = 'mssql_schema'
        guid = $schemaGuid
        attributes = [PSCustomObject] @{
            qualifiedName = "mssql://$ServerName/$DbInstanceName/$DbName/$SchemaName"
            name = $SchemaName
        }
        relationshipAttributes = @{}
    }
    $entities = $entities + $schema

    # send schema creation request
    $objectName = "$ServerName/$DbInstanceName/$DbName/$SchemaName"
    $data = [PSCustomObject] @{
        entities = $entities
    }
    $body = $data | ConvertTo-Json -Depth 100

    try {
        $response = Invoke-RestMethod -Method Post -Uri "$($global:atlasUrl)/entity/bulk?isOverwrite=true" -Body $body -Headers $global:headers
        $schemaGuid = $response.guidAssignments.$schemaGuid
        if ($response | Get-Member -Name 'mutatedEntities' -MemberType Properties) {
            Write-Host "$objectName (guid=$schemaGuid)...schema updated successfully"
        } else {
            Write-Host "$objectName (guid=$schemaGuid)...no changes needed"
        }
        return $schemaGuid
    } catch {
        $exception = $_.Exception.Response
        Write-Host "$objectName...creation failed. Error: $($exception.StatusCode.Value__)-$($exception.ReasonPhrase)"
        Write-Error $_.ErrorDetails.Message
    }

    return $null
}

function GetGlossary {

    param (
        [Parameter()]
        [string] $Name
    )

    try {
        $glossaries = Invoke-RestMethod -Method Get -Uri "$($global:atlasUrl)/glossary" -Headers $global:headers
    } catch {
        $exception = $_.Exception.Response
        Write-Host "Glossary retrieval failed: " $exception.StatusCode.value__ "-" $exception.ReasonPhrase
        Write-Error $_.ErrorDetails.Message
        return $null
    }

    foreach ($glossary in $glossaries) {
        if ($glossary.name -eq $Name) {
            return $glossary
        }
    }

    return $null
}

function GetTermGuid {
    [CmdletBinding()]
    param (
        [Parameter()]
        [PSCustomObject] $Glossary,

        [Parameter()]
        [string] $Term
    )

    if (-not $Term) {
        return $null
    }

    foreach ($glossaryTerm in $Glossary.terms) {
        if ($glossaryTerm.displayText.endswith($Term)) {
            return $glossaryTerm.termGuid
        }
    }

    return $null
}

##
## MAIN
##

Set-StrictMode -Version 2

# check required parameters
if (-not $PSBoundParameters.ContainsKey("DbServerName") -and -not $PSBoundParameters.ContainsKey("DbServerHeader")) {
    Write-Error "-ServerName or -ServerHeader is required"
    return
}

if (-not $PSBoundParameters.ContainsKey("DbInstanceName") -and -not $PSBoundParameters.ContainsKey("DbInstanceHeader")) {
    Write-Error "-DbInstanceName or -DbInstanceHeader is required"
    return
}

if (-not $PSBoundParameters.ContainsKey("DbName") -and -not $PSBoundParameters.ContainsKey("DbHeader")) {
    Write-Error "-DbName or -DbHeader is required"
    return
}

if (-not $PSBoundParameters.ContainsKey("TableName") -and -not $PSBoundParameters.ContainsKey("TableHeader")) {
    Write-Error "-TableName or -TableHeader is required"
    return
}


# check parameters that must NOT be used together
if ($PSBoundParameters.ContainsKey("DbServerName") -and $PSBoundParameters.ContainsKey("DbServerHeader")) {
    Write-Error "-DbServerName and -DbServerHeader cannot be used together"
    return
}

if ($PSBoundParameters.ContainsKey("DbInstanceName") -and $PSBoundParameters.ContainsKey("DbInstanceHeader")) {
    Write-Error "-DbInstanceName and -DbInstanceHeader cannot be used together"
    return
}

if ($PSBoundParameters.ContainsKey("DbName") -and $PSBoundParameters.ContainsKey("DbHeader")) {
    Write-Error "-DbName and -DbHeader cannot be used togethe"
    return
}

if ($PSBoundParameters.ContainsKey("TableName") -and $PSBoundParameters.ContainsKey("TableHeader")) {
    Write-Error "-TableName and -TableHeader cannot be used together"
    return
}


# check optional parameter that must be used together
if ([string]::IsNullOrEmpty($GlossaryName) -ne [string]::IsNullOrEmpty($GlossaryHeader)) {
    Write-Error "-GlossaryName and -GlossaryHeader must be used together"
    return
}

# check CSV headers for required columns
$csvHeader = Get-Content -Path $Path | Select-Object -First 2 | ConvertFrom-Csv

if ($PSBoundParameters.ContainsKey("DbServerHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $ServerHeader  -Membertype Properties)) {
        Write-Error "ServerHeader $ServerHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("DbInstanceHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $DbInstanceHeader  -Membertype Properties)) {
        Write-Error "DbInstanceHeader $DbInstanceHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("DbHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $DbHeader  -Membertype Properties)) {
        Write-Error "DbHeader $DbHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("TableHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $TableHeader  -Membertype Properties)) {
        Write-Error "TableHeader $TableHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("ColumnHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $ColumnHeader  -Membertype Properties)) {
        Write-Error "ColumnHeader $ColumnHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("DescriptionHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $DescriptionHeader  -Membertype Properties)) {
        Write-Error "DescriptionHeader $DescriptionHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("GlossaryHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $GlossaryHeader  -Membertype Properties)) {
        Write-Error "GlossaryHeader $GlossaryHeader not found in $Path"
        return
    }
}

if ($PSBoundParameters.ContainsKey("ClassificationHeader")) {
    if (-not (Get-Member -Inputobject $csvHeader -Name $ClassificationHeader  -Membertype Properties)) {
        Write-Error "ClassificationHeader $ClassificationHeader not found in $Path"
        return
    }
}

# get Azure crendentials
# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        return
    }

}
catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    return
}

$result = Get-AzAccessToken -ResourceUrl 'https://purview.azure.net'
if (-not $result) {
    Write-Error "Unable to get Purview access token. Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    throw
}
$global:headers = @{
    'Content-Type' = "application/json"
    'Authorization' = "Bearer $($result.Token)"
}


# get purview account details
$purview = Get-AzPurviewAccount -ResourceGroupName $ResourceGroupName -Name $PurviewAccountName
if (-not $purview) {
    Write-Error "Unable to get Purview account ($ResourceGroupName/$PurviewAccountName). Please check the -ResourceGroupName and -PurviewAccountName then try again."
    return
}

$global:catalogUrl = $purview.EndpointCatalog
$global:atlasUrl = "$global:catalogUrl/api/atlas/v2"

# read the CSV file & set default column values
$csvFile = Import-Csv $Path

$columns = @('*')
if ($DbServerName) {
    $DbServerHeader = 'Defalt-ServerName'
    $columns += @{Name=$DbServerHeader; Expression={$DbServerName}}
}

if ($DbInstanceName) {
    $DbInstanceHeader = 'Defalt-DbInstanceName'
    $columns += @{Name=$DbInstanceHeader; Expression={$DbInstanceName}}
}

if ($SchemaName) {
    $SchemaHeader = 'Defalt-SchemaName'
    $columns += @{Name=$SchemaHeader; Expression={$SchemaName}}
}

if ($TableName) {
    $TableHeader = 'Defalt-TableName'
    $columns += @{Name=$TableHeader; Expression={$TableName}}
}

if ($DbName) {
    $DbHeader = 'Defalt-DbName'
    $columns += @{Name=$DbHeader; Expression={$DbName}}
}

if ($columns.Count -gt 1) {
    $csvFile = $csvFile | Select-Object -Property $columns
}


$global:guid = -1000

# load glossary terms
if ($GlossaryHeader) {
    $glossary = GetGlossary -Name $GlossaryName
    if (-not $glossary) {
        Write-Error "Glossary '$GlossaryName' not found"
        return
    }
}

$dbGroups = $csvFile | Group-Object -Property @($dbserverheader,$dbinstanceheader,$schemaHeader,$dbheader)

foreach ($group in $dbGroups) {
    # create database entity
    $server, $instance, $schema, $db = $group.Name.Replace(' ','') -split ','

    $schemaGuid = CreateSchema -ServerName $server -DbInstanceName $instance -SchemaName $schema -DbName $db
    if (-not $schemaGuid) {
        return
    }

    $tablesComplete = 0
    $tables = $group.Group | Group-Object -Property @($TableHeader)
    foreach ($table in $tables) {
        $tableName = $table.Name
        if ($tableName.IndexOf(',') -ne -1) {
            Write-Error "$tableName invalid. Please fix and try again."
            continue
        }

        Write-Progress -Activity "Loading $server/$instance/$schema/$db" -Status "Working on $tableName" -PercentComplete ($tablesComplete / $tables.Count * 100)

        # initialize entities
        $entities = @()

        # build table entity
        $global:guid--
        $tableGuid = $global:guid.ToString()

        $tableEntity = [PSCustomObject] @{
            typeName = 'mssql_table'
            guid = $tableGuid
            attributes = [PSCustomObject] @{
                name = $tableName
                qualifiedName = "mssql://$server/$instance/$db/$schema/$tableName"
            }
            relationshipAttributes = [PSCustomObject] @{
                dbSchema = [PSCustomObject] @{
                    guid = $schemaGuid
                }
            }
        }

        $entities += $tableEntity

        # add columns
        foreach ($column in $table.Group) {
            $global:guid--
            $columnGuid = $global:guid.ToString()

            $qualifiedName = "mssql://$server/$instance/$db/$schema/$tableName/$($column.$ColumnHeader)"

            if ($DescriptionHeader) {
                $description = $column.$DescriptionHeader
            } else {
                $description = $null
            }

            $meanings = @()
            if ($GlossaryHeader -and $column.$GlossaryHeader) {
                $glossaryGuid = GetTermGuid -Glossary $glossary -Term $column.$GlossaryHeader
                if ($glossaryGuid) {
                    $meanings += [PSCustomObject] @{
                        guid = $glossaryGuid
                    }
                } else {
                    Write-Host "No glossary term found for '$($column.$GlossaryHeader)'"
                }
            }

            $classifications = @()
            if ($ClassificationHeader -and $column.$ClassificationHeader) {
                $classifications += [PSCustomObject] @{
                    typeName = $column.$ClassificationHeader
                    lastModifiedTS = '1'
                    entityGuid = $columnGuid
                    entityStatus = 'ACTIVE'
                }
            }


            $columnEntity = [PSCustomObject] @{
                typeName = 'mssql_column'
                guid = $columnGuid
                attributes = [PSCustomObject] @{
                    name = $column.$ColumnHeader
                    qualifiedName = $qualifiedName
                    data_type = $column.$DataTypeHeader
                    description = $description
                }
                relationshipAttributes = [PSCustomObject] @{
                    table = [PSCustomObject] @{
                        guid = $tableGuid
                    }
                    meanings = $meanings
                }
                classifications = $classifications
            }

            $entities += $columnEntity
        }

        # send table creation to purview
        $data = [PSCustomObject] @{
            entities = $entities
        }
        $body = $data | ConvertTo-Json -Depth 100

        $url = "$($global:atlasUrl)/entity/bulk?isOverwrite=true&honorClassificationsWhenUpdate=true"

        try {
            $response = Invoke-RestMethod -Method 'POST' -Uri $url -Body $body -Headers $global:headers
            if ($response | Get-Member -Name "mutatedEntities" -MemberType Properties) {
                Write-Host "$tableName...updated successfully"
            } else {
                Write-Host "$tableName...no changes needed"
            }
        } catch {
            $exception = $_.Exception
            Write-Host "$tableName...creation failed:" $exception.Response.StatusCode.value__ "-" $exception.Response.ReasonPhrase
            Write-Error $_.ErrorDetails.Message
        }

        $tablesComplete++

    }
}
