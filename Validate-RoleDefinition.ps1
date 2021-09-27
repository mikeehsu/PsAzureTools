<#
.SYNOPSIS
Validate Role Deinition permissions

.DESCRIPTION
Validate all the Service Provider Operations in a Role Definition and return only valid operations

.PARAMETER FilePath
Source file for the Role Definition

.PARAMETER Role
Role Definition to validate

.EXAMPLE
Validate-RoleDefinition -FilePath ".\RoleDefinition.json"

.EXAMPLE
$role = $rolw | Validate-RoleDefinition.ps1
#>

[CmdletBinding()]
param (
    [Parameter(ParameterSetName='FilePath', Mandatory)]
    [string] $FilePath,

    [Parameter(ParameterSetName='Role', Mandatory, ValueFromPipeline)]
    [psobject] $Role
)

begin {
    # check for Azure context
    if (-not $(Get-AzContext -ErrorAction Stop)) {
        Write-Error 'Please login using Connect-AzAccount and try again.' -ErrorAction Stop
    }

    if ($PSBoundParameters.ContainsKey('FilePath')) {
        $Role = Get-Content $FilePath | ConvertFrom-Json
    }
}

process {
    Write-Verbose "checking provider opertations in $($Role.Name)"

    $actions = [System.Collections.ArrayList]::new()
    foreach ($roleAction in $Role.Actions) {
        if (Get-AzProviderOperation -OperationSearchString $roleAction -ErrorAction Continue) {
            $actions = $actions + $roleAction
        } else {
            Write-Warning "Provider operation '$roleAction' not found."
        }
    }

    $notActions = [System.Collections.ArrayList]::new()
    foreach ($roleNotAction in $Role.NotActions) {
        if (Get-AzProviderOperation -OperationSearchString $roleNotAction -ErrorAction Continue) {
            $notActions = $notActions + $roleNotAction
        } else {
            Write-Warning "Provider operation '$roleNotAction' not found"
        }
    }

    $newRole = $Role.PSObject.Copy()
    $newRole.Actions = $actions
    $newRole.NotActions = $notActions
    return $newRole
}

end {
}

