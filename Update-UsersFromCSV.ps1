<#
.SYNOPSIS
    A script to update user information from a CSV file.

.DESCRIPTION
    This script, Update-UsersFromCSV.ps1, is used to update user information in an environment from a CSV file. The CSV file should contain columns that match the supported fields in the script.

.PARAMETER Path
    The path to the CSV file.

.PARAMETER SetProvidedDataOnly
    A switch parameter to indicate whether to update ONLY the fields provided with values in the CSV file. If this parameter is not provided, any columns with blank values will cause the user data to be set to NULL.

.PARAMETER Environment
    The environment in which to update the user information. The default value is 'Global'.

.EXAMPLE
    .\Update-UsersFromCSV.ps1 -Path <path_to_csv>

.NOTES
    The script supports the following fields: userPrincipalName, displayName, surname, mail, givenName, userType, jobTitle, department, accountEnabled, usageLocation, streetAddress, state, country, officeLocation, city, postalCode, businessPhones, mobilePhone, ageGroup, consentProvidedForMinor, legalAgeGroupClassification, companyName.

    The script also supports the following aliases: telephoneNumber (for businessPhones).

#>

[CmdletBinding()]
param (
    [Parameter()]
    [string] $Path,

    [Parameter()]
    [switch] $SetProvidedDataOnly = $false,

    [Parameter()]
    [string] $Environment = 'Global'
)

$supportedFields = @(
    'userPrincipalName'
    ,'displayName'
    ,'surname'
    ,'mail'
    ,'givenName'
    ,'userType'
    ,'jobTitle'
    ,'department'
    ,'accountEnabled'
    ,'usageLocation'
    ,'streetAddress'
    ,'state'
    ,'country'
    ,'officeLocation'
    ,'city'
    ,'postalCode'
    ,'businessPhones'
    ,'mobilePhone'
    ,'OtherMails'
    ,'ageGroup'
    ,'consentProvidedForMinor'
    ,'legalAgeGroupClassification'
    ,'companyName'
)

$aliases = @{}
$aliases['telephoneNumber'] = 'businessPhones'
$aliases['alternateEmailAddress'] = 'OtherMails'

##
## MAIN
##
#require -module Microsoft.Graph.Authentication
#require -module Microsoft.Graph.Users

Set-StrictMode -Version 2

if (-not $(Get-Module -Name Microsoft.Graph.Authentication)) {
    Import-Module -Name Microsoft.Graph.Authentication -ErrorAction Stop
}

if (-not $(Get-Module -Name Microsoft.Graph.Users)) {
    Import-Module -Name Microsoft.Graph.Users -ErrorAction Stop
}

# check graph environment & context
$endpoint = (Get-MgEnvironment -Name $Environment -ErrorAction Stop).GraphEndpoint

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context.TenantId) {
        Connect-MgGraph -Scope "User.ReadWrite.All"
    }
}
catch {
    Write-Error "Please login (Connect-MgGraph -Scope 'User.ReadWrite.All') and set the proper tenant (Set-MgContext) context before proceeding."
    retrun
}

# verify headers, isolating offical names in [brackets]
Write-Verbose "Loading column headers..."
$header = Get-Content -Path $Path -Head 2 -ErrorAction Stop | ConvertFrom-Csv
if (-not $header) {
    throw "No header found. Please check file and try again."
    return
}
$fileColumns = $header.PSobject.Properties.Name
for ($i=0; $i -lt $fileColumns.Count; $i++) {
    if ($fileColumns[$i] -match '\[(.*?)\]') {
        $fileColumns[$i] = $matches[1]
    }

    # replace with any aliases
    if ($aliases.ContainsKey($fileColumns[$i])) {
        $fileColumns[$i] = $aliases[$fileColumns[$i]]
    }
}

# check for duplicate column names
$duplicates = $fileColumns | Group-Object | Where-Object { $_.Count -gt 1 }
if ($duplicates) {
    throw "Duplicate column names found: $($duplicates.Name -join ', '). Please update file and try again."
    return
}

# filter fileColumns down to supportedFields
$validColumns = $fileColumns | Where-Object { $supportedFields -contains $_ }


# Import-Csv -Path $filePath -Delimiter $Delimiter | ForEach-Object {
$rows = Get-Content -Path $Path -ErrorAction Stop |
    Select-Object -Skip 1 |
    ConvertFrom-Csv -Header $fileColumns

$userProperties = @{}
$skippedUsers = @()
$failedUsers = @()

foreach ($row in $rows) {
    $upn = $row.UserPrincipalName
    $user = Get-MgUser -Filter "userPrincipalName eq '$upn'"
    if ($user) {
        if ($userProperties.Count -eq 0) {
            Write-Verbose "Loading user properties..."
            $user | Get-Member -MemberType Property | Foreach-Object { $userProperties[$_.Name] = $_.Definition }
        }

        try {
            Write-Host "$upn...working" -NoNewline

            $data = @{}
            foreach ($columnName in $validColumns) {
                $setValue = $row.$columnName
                if ('' -eq $setValue ) {
                    $setValue = $null
                }

                if (-not $setValue) {
                    if ($SetProvidedDataOnly) {
                        # skip blank Value
                        continue
                    }
                }

                if ($userProperties[$columnName].StartsWith('string ')) {
                    $data[$columnName] = $setValue

                } elseif ($userProperties[$columnName].StartsWith('string[] ')) {
                    if ($null -eq $setValue) {
                        $data[$columnName] = @()
                    } else {
                        $data[$columnName] = @($setValue)
                    }
                }
            }
            $json = $data | ConvertTo-Json -Depth 10
            Invoke-MgGraphRequest -method PATCH -Uri "$($endpoint)/v1.0/Users/$($user.id)" -Body $json
            Write-Host "`r$upn...UPDATED"
        }
        catch {
            $failedUsers += $upn
            Write-Host "`r$upn...FAILED"
            throw $_
        }
    }
    else {
        Write-Host "$upn...NOT FOUND"
        $skippedUsers += $upn
    }
}
