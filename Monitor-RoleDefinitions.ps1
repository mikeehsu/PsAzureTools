<#
.SYNOPSIS
Monitor changes in Role Definitions over time

.DESCRIPTION
This script will report on changes to Role Definitions. It is designed to run as an Azure Function using a timer trigger.
Upon each execution, it will retrieve the current role definition and store it in the specified storage account/container.
If any changes are detected since the previous execution, it will write the changes to a specified storage account/container.

.PARAMETER Timer
The Azure Function timer parameter.
#>

# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format.
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host 'PowerShell timer is running late!'
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

[string] $ResourceGroupName = $env:APP_HISTORY_RESOURCEGROUPNAME
[string] $StorageAccountName = $env:APP_HISTORY_STORAGEACCOUNTNAME
[string] $ContainerName = $env:APP_HISTORY_CONTAINERNAME
[string] $BlobPrefix = 'Role-Definitions-'

[string] $changesResourceGroupName = $env:APP_CHANGES_RESOURCEGROUPNAME
[string] $changesStorageAccountName = $env:APP_CHANGES_STORAGEACCOUNTNAME
[string] $changesContainerName = $env:APP_CHANGES_CONTAINERNAME
[string] $changesBlobPrefix = 'Role-Definition-Changes-'

#################################################
#
function SaveRoleDefinitions {
    param (
        [Parameter(Mandatory)]
        [String] $ResourceGroupName,

        [Parameter(Mandatory)]
        [String] $StorageAccountName,

        [Parameter(Mandatory)]
        [String] $ContainerName,

        [Parameter(Mandatory)]
        [string] $BlobName

    )

    $blobName = "$($BlobPrefix)$($today).json"
    $filePath = Join-Path -Path $env:TEMP -ChildPath $blobName
    Write-Host "Creatingfile... $blobName"

    try {
        $roles = Get-AzRoleDefinition -ErrorAction Stop | Sort-Object -Property Name
        foreach ($role in $roles) {
            $role.Actions.Sort()
            $role.NotActions.Sort()
        }
        $roles | ConvertTo-Json -Depth 10 | Out-File $filePath

        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
        $null = Set-AzStorageBlobContent -File $filePath `
            -Context $storageAccount.Context `
            -Container $containerName `
            -Blob $BlobName `
            -Force `
            -ErrorAction Stop
        $null = Remove-Item $filePath -Force
        Write-Host "$($StorageAccountName)/$($ContainerName)/$($BlobName) saved."
    }
    catch {
        throw $_
    }
}

#################################################
#

function CheckDifference {
    param (
        [Array] $oldPermissions,
        [Array] $newPermissions
    )

    $differences = [System.Collections.ArrayList]::New()

    $changes = Compare-Object $oldPermissions $newPermissions
    if (-not $changes) {
        return
    }

    foreach ($change in $changes) {
        if ($change.SideIndicator -eq '=>') {
            $indicator = 'Added'

        }
        elseif ($change.SideIndicator -eq '<=') {
            $indicator = 'Removed'

        }
        else {
            $indicator = 'Undetermined'
        }

        $difference = [PermissionDifference]::New()
        $difference.Permission = $change.InputObject
        $difference.Change = $indicator

        $differences += $difference
    }

    return $differences
}

#################################################
# MAIN

Set-StrictMode -Version 3

class PermissionDifference {
    [string] $Permission
    [string] $Change
}

class RoleDifference {
    [string] $RoleName
    [PermissionDifference[]] $Actions = @()
}

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw"Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }

}
catch {
    throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
}

$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$changesBlobName = "$changesBlobPrefix$($today).json"

# download blob if saved roles in storage account
if ($StorageAccountName) {
    try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop

        # get the last modified version of the blob
        $currentFilename = "$($BlobPrefix)$($today).json"

        SaveRoleDefinitions -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $currentFilename

        # get blobs to compare
        [array] $blobs = Get-AzStorageBlob -Container $ContainerName -Context $storageAccount.context | Where-Object { $_.Name -like "$($BlobPrefix)*" } | Sort-Object -Property Name -Descending
        if (-not $blobs -or $blobs.Count -eq 0) {
            Write-Erorr "No files starting with $($BlobPrefix) found in container" -ErrorAction Stop
            return

        }
        elseif ($blobs.Count -eq 1) {
            Write-Host "Only 1 file starting with $($BlobPrefix) found in container. Not enough to compare. (This is normal for the very first execution.)"
            return

        }
        elseif ($blobs[0].Name -ne $currentFilename) {
            Write-Error "Unable to find today's file $($currentFileName) in $($StorageAccountName/$ContainerName)" -ErrorAction Stop
            return
        }

        $previousFileName = $blobs[1].Name

        # load current & previous files from storage
        $currentFilePath = New-TemporaryFile -ErrorAction Stop
        $null = Get-AzStorageBlobContent `
            -Context $storageAccount.Context `
            -Container $containerName `
            -Blob $currentFilename `
            -Destination $currentFilePath `
            -ErrorAction Stop `
            -Force
        Write-Host "Downloaded current roles: $($storageAccount.StorageAccountName)/$($ContainerName)/$($currentFilename))"

        $previousFilePath = New-TemporaryFile -ErrorAction Stop
        $null = Get-AzStorageBlobContent `
            -Context $storageAccount.Context `
            -Container $containerName `
            -Blob $previousFileName `
            -Destination $previousFilePath `
            -ErrorAction Stop `
            -Force
        Write-Host "Downloaded previous roles: $($storageAccount.StorageAccountName)/$($ContainerName)/$($previousFilename)"

    }
    catch {
        throw $_
        Write-Error 'Unable to download current or previous role definition files'
        exit 1
    }
}

# check for high-level file differences
$currentHash = Get-FileHash -Path $currentFilePath -ErrorAction Stop
$previousHash = Get-FileHash -Path $previousFilePath -ErrorAction Stop
if ($currentHash.Hash -eq $previousHash.Hash) {
    Write-Host 'Current and previous Service Tag files hash match. No changes found.'
    return
}

# load saved roles
$currentRoles = Get-Content $currentFilepath -ErrorAction Stop | ConvertFrom-Json | Sort-Object -Property Name
$previousRoles = Get-Content $previousFilepath -ErrorAction Stop | ConvertFrom-Json | Sort-Object -Property Name

# find all changed roles
$changedRoles = [System.Collections.ArrayList]::New()
foreach ($currentRole in $currentRoles) {

    $changedRole = [RoleDifference]::New()
    $changedRole.RoleName = $currentRole.Name

    $previousRole = $previousRoles | Where-Object { $_.Name -eq $currentRole.Name }

    # no previous role found
    if (-not $previousRole) {
        # new role definition
        Write-Host "$($currentRole.Name) - new role found."
        foreach ($action in $currentRole.Actions) {
            $permissionDifference = [PermissionDifference]::New()
            $permissionDifference.Permission = $action
            $permissionDifference.Change = 'Added'
            $changedRole.Actions += $permissionDifference
        }
        $changedRoles += $changedRole
        continue
    }

    # check for differences
    Write-Verbose "$($currentRole.Name) - checking Actions."
    $actionDiff = CheckDifference -oldPermission $previousRole.Actions -newPermission $currentRole.Actions
    if ($actionDiff) {
        $changedRole.Actions = $actionDiff
    }

    if ($changedRole.Actions) {
        $changedRoles += $changedRole
    }
}

# save changes to blob
if ($changedRoles.Count -gt 0) {
    $tmpFilePath = New-TemporaryFile
    $changedRoles | ConvertTo-Json -Depth 10 | Out-File -FilePath $tmpFilePath
    try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $changesResourceGroupName -Name $changesStorageAccountName -ErrorAction Stop
        $null = Set-AzStorageBlobContent -File $tmpFilePath `
            -Context $storageAccount.Context `
            -Container $changesContainerName `
            -Blob $changesBlobName `
            -Force `
            -ErrorAction Stop
        Remove-Item $tmpFilePath -Force
    }
    catch {
        throw $_
    }
}

return $changedRoles
