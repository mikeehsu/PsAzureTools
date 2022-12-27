<#
.SYNOPSIS
Monitor changes in Service Tags over time

.DESCRIPTION
This script will report on changes to Service Tags. It is designed to run as an Azure Function using a timer trigger.
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


#################################################
#
function SaveServiceTags {
    param (
        [Parameter(Mandatory)]
        [String] $ResourceGroupName,

        [Parameter(Mandatory)]
        [String] $StorageAccountName,

        [Parameter(Mandatory)]
        [String] $ContainerName,

        [Parameter(Mandatory)]
        [string] $BlobName,

        [Parameter(Mandatory)]
        [string] $Location

    )

    $blobName = "$($BlobPrefix)$($today).json"
    $filePath = Join-Path -Path $env:TEMP -ChildPath $blobName
    Write-Host "Creating file... $blobName"

    try {
        Get-AzNetworkServiceTag -Location $Location | ConvertTo-Json -Depth 10 | Out-File $filePath

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
        [Array] $oldPrefixes,
        [Array] $newPrefixes
    )

    $differences = [System.Collections.ArrayList]::New()

    $oldPrefixes = $oldPrefixes | Sort-Object
    $newPrefixes = $newPrefixes | Sort-Object

    $changes = Compare-Object $oldPrefixes $newPrefixes
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

        $difference = [PrefixDifference]::New()
        $difference.Prefix = $change.InputObject
        $difference.Change = $indicator

        $differences += $difference
    }

    return $differences
}

#################################################
# MAIN

Set-StrictMode -Version 3

class PrefixDifference {
    [string] $Prefix
    [string] $Change
}

class TagDifference {
    [string] $Name
    [string] $Service
    [string] $Region
    [PrefixDifference[]] $Prefixes
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

# validate parameters
if (-not $env:APP_HISTORY_RESOURCEGROUPNAME -or -not $env:APP_HISTORY_STORAGEACCOUNTNAME -or -not $env:APP_HISTORY_CONTAINERNAME) {
    Write-Error 'APP_HISTORY_RESOURCEGROUPNAME, APP_HISTORY_STORAGEACCOUNTNAME and APP_HISTORY_CONTAINERNAME must be provided in environment variables'
    return
}
[string] $ResourceGroupName = $env:APP_HISTORY_RESOURCEGROUPNAME
[string] $StorageAccountName = $env:APP_HISTORY_STORAGEACCOUNTNAME
[string] $ContainerName = $env:APP_HISTORY_CONTAINERNAME
[string] $BlobPrefix = 'Service-Tags-'


if (-not $env:APP_CHANGES_RESOURCEGROUPNAME -or -not $env:APP_CHANGES_STORAGEACCOUNTNAME -or -not $env:APP_CHANGES_CONTAINERNAME) {
    Write-Error 'APP_CHANGES_RESOURCEGROUPNAME, APP_CHANGES_STORAGEACCOUNTNAME and APP_CHANGES_CONTAINERNAME must be provided as environment variables.'
    return
}
[string] $changesResourceGroupName = $env:APP_CHANGES_RESOURCEGROUPNAME
[string] $changesStorageAccountName = $env:APP_CHANGES_STORAGEACCOUNTNAME
[string] $changesContainerName = $env:APP_CHANGES_CONTAINERNAME
[string] $changesBlobPrefix = 'Service-Tag-Changes-'

if (-not $env:APP_SERVICETAGS_LOCATION) {
    Write-Error "APP_SERVICETAGS_LOCATION must be provided as environment variable"
    return
}
[string] $Location = $env:APP_SERVICETAGS_LOCATION

$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$changesBlobName = "$changesBlobPrefix$($today).json"

# download blob if saved roles in storage account
try {
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop

    # get the last modified version of the blob
    $currentFilename = "$($BlobPrefix)$($today).json"

    SaveServiceTags -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $currentFilename -Location $Location

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
    Write-Host "Downloaded current tags: $($storageAccount.StorageAccountName)/$($ContainerName)/$($currentFilename))"

    $previousFilePath = New-TemporaryFile -ErrorAction Stop
    $null = Get-AzStorageBlobContent `
        -Context $storageAccount.Context `
        -Container $containerName `
        -Blob $previousFileName `
        -Destination $previousFilePath `
        -ErrorAction Stop `
        -Force
    Write-Host "Downloaded previous tags: $($storageAccount.StorageAccountName)/$($ContainerName)/$($previousFilename)"

}
catch {
    throw $_
    Write-Error 'Unable to download current or previous role definition files'
    exit 1
}

# check for high-level file differences
$currentHash = Get-FileHash -Path $currentFilePath -ErrorAction Stop
$previousHash = Get-FileHash -Path $previousFilePath -ErrorAction Stop
if ($currentHash.Hash -eq $previousHash.Hash) {
    Write-Host 'Current and previous Service Tag files hash match. No changes found.'
    return
}

# load saved roles
$currentTags = (Get-Content $currentFilepath -ErrorAction Stop | ConvertFrom-Json).Values | Sort-Object -Property Name
$previousTags = (Get-Content $previousFilepath -ErrorAction Stop | ConvertFrom-Json).Values | Sort-Object -Property Name

# find all changed roles
$changedTags = [System.Collections.ArrayList]::New()
foreach ($currentTag in $currentTags) {

    $changedTag = [TagDifference]::New()
    $changedTag.Name = $currentTag.Name
    $changedTag.Service = $currentTag.Properties.SystemService
    $changedTag.Region = $currentTag.Properties.Region

    $previousTag = $previousTags | Where-Object { $_.Name -eq $currentTag.Name }

    # no previous role found
    if (-not $previousTag) {
        # new role definition
        Write-Host "$($currentTag.Name) - new tag found."
        foreach ($prefix in $currentTag.Properties.AddressPrefixes) {
            $prefixDiff= [PrefixDifference]::New()
            $prefixDiff.Prefix = $prefix
            $prefixDiff.Change = 'Added'

            $changedTag.Prefixes += $prefixDiff
        }
        $changedTags += $changedTag
        continue
    }

    # check for differences
    Write-Verbose "$($currentTag.Name) - checking Prefixes."
    $prefixDiff = CheckDifference -oldPrefixes $previousTag.Properties.AddressPrefixes -newPrefixes $currentTag.Properties.AddressPrefixes
    if ($prefixDiff) {
        $changedTag.Prefixes = $prefixDiff
    }

    if ($changedTag.Prefixes) {
        $changedTags += $changedTag
    }
}

# save changes to blob
if ($changedTags.Count -gt 0) {
    $tmpFilePath = New-TemporaryFile
    $changedTags | ConvertTo-Json -Depth 10 | Out-File -FilePath $tmpFilePath
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

return $changedTags
