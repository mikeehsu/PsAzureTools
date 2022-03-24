<#
.SYNOPSIS
Validate Role Deinition permissions

.DESCRIPTION
Validate all the Provider Operations in a Role Definition and return a role with only the valid operations

.PARAMETER Role
Role Definition to validate

.EXAMPLE
Get-AzRoleDefinition -Role <role> | Validate-RoleDefinition.ps1

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, ValueFromPipeline)]
    [psobject] $Role
)

BEGIN {
    # check for Azure context
    if (-not $(Get-AzContext -ErrorAction Stop)) {
        Write-Error 'Please login using Connect-AzAccount and try again.' -ErrorAction Stop
    }

    # load all Provider Operations into memory
    Write-Progress 'Reading Provider Operations...'
    $script:ExistingOperations = [System.Collections.ArrayList]::new()
    Get-AzProviderOperation -ErrorAction Stop | ForEach-Object { $ExistingOperations += $_.Operation }
    Write-Progress -Activity 'Reading Provider Operations...' -Completed
}

PROCESS {

    function GetValidActions
    {
        [CmdletBinding()]
        param (
            [Parameter()]
            [array] $Actions
        )

        $validActions = [System.Collections.ArrayList]::new()

        foreach ($action in $Actions) {
            if (-not $action) {
                continue
            }

            $found = $false

            # search for wildcard matches
            foreach ($operation in $ExistingOperations) {
                if ($operation -like $action) {
                    $validActions += $action
                    $found = $true
                    break
                }
            }

            # double check any items with /*/ in the action
            # items like 'Microsoft.Storage/storageAccounts/*/delete' should match 'Microsoft.Storage/storageAccounts/delete'
            if (-not $found -and $action -match '/*/') {
                $actionMinusWildcard = $action.Replace('/*/', '/')
                foreach ($operation in $ExistingOperations) {
                    if ($operation -like $actionMinusWildcard) {
                        $validActions += $action
                        $found = $true
                        break
                    }
                }
            }

            if (-not $found) {
                Write-Warning "'$action' action  not found"
            }
        }

        return $validActions
    }

    # get validated operations
    Write-Verbose "checking role...$($Role.Name)"
    $actions = GetValidActions($Role.Actions)
    $notActions = GetValidActions($Role.NotActions)

    # check for differences from the original
    $actionDiff = $null
    if ($actions) {
        $actionDiff = Compare-Object $Role.Actions $actions
    }

    $notActionDiff = $null
    if ($notActions) {
        $notActionDiff = Compare-Object $Role.NotActions $notActions
    }

    if ($actionDiff -or $notActionDiff) {
        # differences found, output new role
        $newRole = $Role.PSObject.Copy()
        $newRole.Actions = $actions
        $newRole.NotActions = $notActions
        return $newRole
    }
}

END {
}
