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
    $ExistingOperations = [System.Collections.ArrayList]::new()
    if (-not $ExistingOperations) {
        $ExistingOperations = (Get-AzProviderOperation -ErrorAction Stop).Operation  | Sort-Object
    }
    Write-Progress -Activity 'Reading Provider Operations...' -Completed
}

PROCESS {
    function BinarySearch
    {
        [CmdletBinding()]
        param (
            [Parameter()]
            [string] $SearchTerm
        )

        [int] $low = 0
        [int] $high = $ExistingOperations.Count - 1

        $altTerm = $searchTerm
        if ($SearchTerm.IndexOf('/*') -ne -1) {
            $isWildcard = $true
            $firstPart = $SearchTerm.Substring(0, $SearchTerm.IndexOf('/*'))
            $altTerm = $SearchTerm.Replace('/*/', '/')
        }

        while ($low -le $high) {
            [int] $mid = $low + (($high - $low) / 2)
            $checkValue = $ExistingOperations[$mid]

            if ($checkValue -like $SearchTerm) {
                return
            }

            if ($checkValue -lt $searchTerm) {
                $low = $mid + 1
            } else {
                $high = $mid - 1
            }
        }

        if ($isWildcard) {
            # check for wildcard match
            $high = $mid+1
            if ($high -ge $ExistingOperations.Count) {
                return -1
            }

            while ($ExistingOperations[$high].StartsWith($firstPart, 'CurrentCultureIgnoreCase')) {
                $checkValue = $ExistingOperations[$high]
                if ($checkValue -like $SearchTerm -or $checkValue -eq $altTerm) {
                    return $high
                }
                $high = $high + 1
            }
        }

        return -1
    }

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

            if ($action.StartsWith('*')) {
                $validActions += $action
                continue
            }

            $index = BinarySearch $action
            if ($index -ne -1) {
                $validActions += $action
            } else  {
                Write-Warning "'$action' action not found"
            }
       }

        return $validActions
    }


    # Write-Verbose "checking role...$($Role.Name)"
    $actions = GetValidActions -Actions $Role.Actions
    $notActions = GetValidActions -Actions $Role.NotActions

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
