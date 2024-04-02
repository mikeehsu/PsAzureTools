<#
.SYNOPSIS
This script exports the schema of a SQL Server database to individual SQL files.

.DESCRIPTION
The script uses the Microsoft.SqlServer.SMO library to connect to a SQL Server database and export the schema of the specified database to individual SQL files. The script exports tables, views, stored procedures, and user-defined functions by default.

This script requires the Microsoft.SqlServer.SqlManagementObjects package and SqlServer modules. To install these modules, run the following command:

- Register-PackageSource -Name "NuGet" -Location "https://api.nuget.org/v3/index.json" -ProviderName NuGet
- Install-Package Microsoft.SqlServer.SqlManagementObjects
- Install-Module SqlServer

.PARAMETER Path
The path where the SQL files will be exported.

.PARAMETER DBServerName
The name of the SQL Server instance.

.PARAMETER DBName
The name of the database.

.PARAMETER UserId
The username to connect to the database.

.PARAMETER Password
The password to connect to the database. If not provided, the user will be prompted to enter the password.

.PARAMETER All
If specified, all objects (tables, views, stored procedures, user-defined functions) will be exported.

.PARAMETER View
If specified, views will be exported.

.PARAMETER Table
If specified, tables will be exported.

.PARAMETER StoredProcedure
If specified, stored procedures will be exported.

.PARAMETER UserDefinedFunction
If specified, user-defined functions will be exported.

.PARAMETER Overwrite
If specified, existing SQL files in the specified path will be overwritten.

.PARAMETER SeparateFiles
If specified, each object type will be exported in its own directory. Otherwise, a single file for each object type will be created.

.EXAMPLE
Export-SqlSchema.ps1 -Path C:\SQLSchema -DBServerName MyServer -DBName MyDB -UserId MyUser -Overwrite
#>

param (
    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter(Mandatory)]
    [string] $DBServerName,

    [Parameter(Mandatory)]
    [string] $DBName,

    [Parameter(Mandatory)]
    [string] $UserId,

    [Parameter()]
    [securestring] $Password,

    [Parameter()]
    [switch] $All,

    [Parameter()]
    [switch] $View,

    [Parameter()]
    [switch] $Table,

    [Parameter()]
    [switch] $StoredProcedure,

    [Parameter()]
    [switch] $UserDefinedFunction,

    [Parameter()]
    [switch] $Overwrite,

    [Parameter()]
    [switch] $SeparateFiles
)
$ErrorActionPreference = 'Stop'

#Require SqlServer
if (-not (Get-Module -Name SqlServer)) {
    Import-Module -Name SqlServer
}


# if missing get password
if (-not $Password) {
    $Password = Read-Host -Prompt 'Password' -AsSecureString
}

# verify path
if (-not (Test-Path $Path)) {
    Write-Warning "Path $Path does not exist. Creating it."
    New-Item -Path $Path -ItemType Directory -ErrorAction Stop
}

$fileExists = $false
if (((Test-Path "$Path/Table") -and (Get-Item "$Path/Table")) -or
    ((Test-Path "$Path/View") -and (Get-Item "$Path/View")) -or
    ((Test-Path "$Path/StoredProcedure") -and (Get-Item "$Path/StoredProcedure")) -or
    ((Test-Path "$Path/UserDefinedFunction") -and (Get-Item "$Path/UserDefinedFunction"))) {
    $fileExists = $true
}
$Path = (Get-Item $Path).FullName
Write-Host "Outputting shema to: $Path"

if ($fileExists) {
    if ($Overwrite) {
        # clean up old files
        if (Test-Path "$Path/Table") { Remove-Item "$Path/Table" -Recurse -Force }
        if (Test-Path "$Path/View") { Remove-Item "$Path/View" -Recurse -Force }
        if (Test-Path "$Path/StoredProcedure") { Remove-Item "$Path/StoredProcedure" -Recurse -Force }
        if (Test-Path "$Path/UserDefinedFunction") { Remove-Item "$Path/UserDefinedFunction" -Recurse -Force }

        if (Test-Path "$Path/Table.sql") { Remove-Item "$Path/Table.sql" -Recurse -Force }
        if (Test-Path "$Path/View.sql") { Remove-Item "$Path/View.sql" -Recurse -Force }
        if (Test-Path "$Path/StoredProcedure.sql") { Remove-Item "$Path/StoredProcedure.sql" -Recurse -Force }
        if (Test-Path "$Path/UserDefinedFunction.sql") { Remove-Item "$Path/UserDefinedFunction.sql" -Recurse -Force }
    }
    else {
        Write-Warning "Sql files in $Path already exist. Use -Overwrite to overwrite them."
        return
    }
}


# verify export items switches
if (-not $Table -and -not $View -and -not $StoredProcedure -and -not $UserDefinedFunction) {
    Write-Verbose 'Defaulting to export all objects.'
    $All = $true
}

if ($All) {
    $Table = $true
    $View = $true
    $StoredProcedure = $true
    $UserDefinedFunction = $true
}

try {
    # initialize sql server connection
    $smo = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO')

    # Create the SMO Server object
    $server = New-Object Microsoft.SqlServer.Management.Smo.Server($DBServerName)

    # Set the credentials for the server
    $server.ConnectionContext.LoginSecure = $false
    $server.ConnectionContext.Login = $UserId
    $server.ConnectionContext.SecurePassword = $Password

    $db = $server.databases[$DBName]
    if (-not $db) {
        throw "Error connecting to $DBServerName/$DBName. Please check server/database name, credentials and network."
    }

}
catch {
    throw $_
}

$scripter = New-Object ('Microsoft.SqlServer.Management.Smo.Scripter') ($server)
$scripter.Options.AnsiFile = $true
$scripter.Options.IncludeHeaders = $false
$scripter.Options.ScriptOwner = $false
$scripter.Options.AppendToFile = $false
$scripter.Options.AllowSystemobjects = $false
$scripter.Options.ScriptDrops = $false
$scripter.Options.WithDependencies = $false
$scripter.Options.SchemaQualify = $false
$scripter.Options.SchemaQualifyForeignKeysReferences = $false
$scripter.Options.ScriptBatchTerminator = $false

$scripter.Options.Indexes = $true
$scripter.Options.ClusteredIndexes = $true
$scripter.Options.NonClusteredIndexes = $true
$scripter.Options.NoCollation = $true

$scripter.Options.DriAll = $true
$scripter.Options.DriIncludeSystemNames = $false

$scripter.Options.ToFileOnly = $true
$scripter.Options.AppendToFile = $true
$scripter.Options.Permissions = $true

# configure objects to export
$objects = @()

if ($Table) {
    $objects += $db.Tables
}

if ($View) {
    $objects += $db.Views
}

if ($StoredProcedure) {
    $objects += $db.StoredProcedures
}

if ($UserDefinedFunction) {
    $objects += $db.UserDefinedFunctions
}

# export the
try {
    $count = 0
    $skipped = 0
    $exported = 0

    foreach ($object in $objects) {
        $count++

        if ($object.IsSystemObject -or @('jobs', 'jobs_internal' -contains $object.Schema)) {
            Write-Progress -Activity "Exporting $($object.GetType().Name)" -Status "skipping...$($object.Name)" -PercentComplete ($count / $objects.Count * 100)
            $skipped++
            continue
        }
        Write-Progress -Activity "Exporting $($object.GetType().Name)" -Status "writing...$($object.Name)" -PercentComplete ($count / $objects.Count * 100)

        $typeFolder = $object.GetType().Name

        if ($SeparateFiles) {
            # separate directories for object type & one files per object
            if (-not (Test-Path -Path "$Path\$typeFolder")) {
                New-Item -Type Directory -Name $typeFolder -Path $Path | Out-Null
            }
            $file = $object.Name -replace '\[|\]'
            $file = $file.Replace('dbo.', '')
            $filename = "$Path\$typeFolder\$file.sql"

        }
        else {
            # one file per object type
            $filename = "$Path\$($typeFolder).sql"
        }

        "---------- BEGIN OF $($object.Name) ----------" | Out-File -FilePath $filename -Append
        $scripter.Options.FileName = $filename
        $scripter.Script($object)
        "---------- END OF $($object.Name) ----------" | Out-File -FilePath $filename -Append
        '' | Out-File -FilePath $filename -Append

        $exported++
        Write-Host "$($object.GetType().Name) $($object.Schema).$($object.Name) exported"
    }
}
catch {
    throw $_
}
