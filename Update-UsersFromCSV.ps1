
[CmdletBinding()]
param (
    [Parameter()]
    [string] $Path,

    [Parameter()]
    [string] $Environment = 'Global'
)

$supportedFields = @(
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
#   ,'telephoneNumber'
    ,'mobilePhone'
#   ,'alternateEmailAddress'
    ,'ageGroup'
    ,'consentProvidedForMinor'
    ,'legalAgeGroupClassification'
    ,'companyName'
)

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

# Connect-MgGraph -TenantId  1abe43f1-aa90-4b69-8ea0-56d263646592 -Scope "User.ReadWrite.All"

$rows = Import-Csv -Path $Path

$skippedUsers = @()
$failedUsers = @()

foreach ($row in $rows) {
    $upn = $row.UserPrincipalName
    $user = Get-MgUser -Filter "userPrincipalName eq '$upn'"
    if ($user) {
        try {
            Write-Host "$upn...working" -NoNewline
            $updates = $row | Select-Object -Property $supportedFields

            $data = @{}
            foreach ($field in $supportedFields) {
                if ($updates.$field) {
                    $data[$field] = $updates.$field
                } else {
                    $data[$field] = $null
                }
            }
            $json = $data | ConvertTo-Json -Depth 10
            Invoke-MgGraphRequest -method PATCH -Uri "$($endpoint)/v1.0/Users/$($user.id)" -Body $json
            Write-Host "`r$upn...updated"
        }
        catch {
            $failedUsers += $upn
            Write-Host "`r$upn...FAILED"
            throw $_
        }
    }
    else {
        Write-Host "$upn not...FAILED, not found"
        $skippedUsers += $upn
    }
}
