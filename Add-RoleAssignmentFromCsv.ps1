[CmdletBinding()]
param (
    [Parameter()]
    [string] $FileName,

    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $TenantName
)

Set-StrictMode -version 2

$newUsers = Import-Csv $FileName
# sample row
# EmailAddress, FirstName, LastName, UserName, GroupName, Role, ResourceGroup


# verify resource groups exist
# set default resource group if not specified
foreach ($newUser in $newUsers) {
    if (-not $newUser.ResourceGroup -and -not $ResourceGroupName) {
        Write-Error "You must specify the -ResourceGroupName parameter if ResourceGroup is not specified in the CSV file"
        exit 1
    }

    if (-not $newUser.ResourceGroup) {
        $newUser.ResourceGroup = $ResourceGroupName
    }
}

$resourceGroupErrors = $false
$rgNames = $newUsers.ResourceGroup | Sort-Object -Unique
foreach ($rgName in $rgNames) {
    $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        Write-Error "$resourceGroupName resource group does not exist"
        $resourceGroupErrors = $true
    }
}

if ($resourceGroupErrors) {
    Write-Error "Please correct resource group errors and try again"
    exit 1
}


# verify roles
$roleErrors = $false
$roleNames = $newUsers.Role | Sort-Object -Unique
foreach ($roleName in $roleNames) {
    $role = Get-AzRoleDefinition -Name $roleName
    if (-not $role) {
        Write-Error "Role $roleName does not exist"
        $roleErrors = $true
    }
}

if ($roleErrors) {
    Write-Error "Please correct role errors and try again"
    exit 1
}


# verify users
$emailErrors = $false
foreach ($newUser in $newUsers) {
    if (-not $newUser.UserName -and $TenantName) {
        $mailName = ($newUser.EmailAddress -split '@')[0]
        if (-not $mailName) {
            Write-Error "$($newUser.EmailAddress) valid email address is required"
            $emailErrors = $true
        }
        $newUser.UserName = $mailName + '@' + $TenantName
    }
}

if ($emailErrors) {
    Write-Error "Please correct email errors and try again"
    exit 1
}

exit 1

# create users
$userError = $false
$users = @{}
$userEntries = $newUsers | Where-Object {$_.UserName} | Sort-Object -Property UserName -Unique
foreach ($userEntry in $userEntries) {
    $user = Get-AzADUser -UserPrincipalName $userEntry.UserName
    if (-not $user) {
        # create user
        $secureString = ConvertTo-SecureString -String $userEntry.Password -AsPlainText -Force
        $displayName = "$($userEntry.FirstName) $($userEntry.LastName)"
        $mailNickName = "$($userEntry.FirstName)$($userEntry.LastName)"
        $user = New-AzADUser -DisplayName $displayName -MailNickName $mailNickName -UserPrincipalName $userEntry.UserName -Password $secureString
        if ($user) {
            Write-Host "$($userEntry.UserName) user created."
        } else  {
            Write-Error "Unable to create user $($userEntry.UserName)."
            $userError = $true
        }
    }

    $users[$userEntry.UserName] = $user
}

if ($userError) {
    Write-Error "Please correct user errors and try again."
    exit 1
}

# assign roles to individual users
$entries = $newUsers | Where-Object {-not $_.GroupName} | Sort-Object -Property UserName, Role, ResourceGroup -Unique
foreach ($entry in $entries) {
    if (-not $users[$entry.UserName]) {
        Write-Error "$($entry.UserName) does not exist. Skipping assignment of $($entry.Role) role."
        continue
    }

    $assignment = Get-AzRoleAssignment -ObjectId $users[$entry.UserName].Id -RoleDefinitionName $entry.Role -ResourceGroupName $entry.ResourceGroup
    if (-not $assignment) {
        $assignment = New-AzRoleAssignment -ObjectId $users[$entry.UserName].Id -RoleDefinitionName $entry.Role -ResourceGroupName $entry.ResourceGroup
        if ($assignment) {
            Write-Host "$($entry.UserName) assigned $($entry.Role) role."
        } else  {
            Write-Error "Unable to assign $($entry.Role) role to $($entry.UserName)."
            $userError = $true
        }
    }
}

if ($userError) {
    Write-Error "Please correct user errors and try again."
    exit 1
}

# verify groups
$groupError = $false
$groups = @{}
$groupNames = $newUsers.GroupName | Where-Object {$_} | Sort-Object -Unique
foreach ($groupName in $groupNames) {
    if (-not $groupName) {
        continue
    }

    $group = Get-AzADGroup -DisplayName $groupName
    if (-not $group) {
        # create group
        $mailNickName = $groupName.Replace(' ', '').Replace('.','')
        $group = New-AzADGroup -DisplayName $GroupName -MailNickname $mailNickName
        if ($group) {
            Write-Host "$groupName group created"
        } else {
            Write-Error "Unable to create group $($groupName)."
            $groupError = $true
        }
    }

    $groups[$groupName] = $group
}

if ($groupError) {
    Write-Error "Please correct group errors and try again."
    exit 1
}

# assign roles to groups

$entries = $newUsers | Where-Object {$_.GroupName} | Sort-Object -Property GroupName, Role, ResourceGroup -Unique
foreach ($entry in $entries) {
    $assignment = Get-AzRoleAssignment -ObjectId $groups[$entry.GroupName].Id -RoleDefinitionName $entry.Role -ResourceGroupName $entry.ResourceGroup
    if ($assignment) {
        continue
    }

    $assignment = New-AzRoleAssignment -ObjectId $groups[$entry.GroupName].Id -RoleDefinitionName $entry.Role -ResourceGroupName $entry.ResourceGroup
    if ($assignment) {
        Write-Host "$($entry.GroupName) assigned $($entry.Role) role in $($entry.ResourceGroup) resource group"
    } else {
        Write-Error "Unable to assign $($entry.Role) role to $($entry.GroupName) in $($entry.ResourceGroup) resource group"
        $groupError = $true
    }
}

# assign users to groups

foreach ($groupName in $groupNames) {
    $memberIds = @()
    $members = Get-AzADGroupMember -GroupObjectId $groups[$groupName].Id
    if ($members) {
        $memberIds = $members.Id
    }

    $entries = $newUsers | Where-Object {$_.GroupName -eq $groupName} | Sort-Object -Property UserName -Unique
    foreach ($entry in $entries) {
        if (-not $users[$entry.UserName]) {
            Write-Error "$($entry.UserName) does not exist. Skipping assignment to $($entry.GroupName) group."
            continue
        }

        if ($memberIds.Contains($users[$entry.UserName].Id)) {
            continue
        }

        $assignment = Add-AzADGroupMember -TargetGroupObjectId $groups[$entry.GroupName].Id -MemberObjectId $users[$entry.userName].Id
        # no assignment data returned on success
        # if ($assignment) {
            Write-Host "$($entry.UserName) added to $($entry.GroupName) group"
        # } else {
        #     Write-Error "Unable to add $($entry.UserName) to $($entry.GroupName) group"
        #     $groupError = $true
        # }
    }
}

if ($groupError) {
    Write-Error "Please correct group errors and try again."
    exit 1
}
