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
[string] $BlobPrefix = 'Provider-Operations-'

[string] $changesResourceGroupName = $env:APP_CHANGES_RESOURCEGROUPNAME
[string] $changesStorageAccountName = $env:APP_CHANGES_STORAGEACCOUNTNAME
[string] $changesContainerName = $env:APP_CHANGES_CONTAINERNAME
[string] $changesBlobPrefix = 'Provider-Operations-Changes-'

#################################################
#
function SaveProviderOperations {
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
        Get-AzProviderOperation | Sort-Object -Property Operation | ConvertTo-Json -Depth 10 | Out-File -Path $filePath
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
# MAIN

Set-StrictMode -Version 3

class OperationDifference {
    [string] $Operation
    [string] $Change
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

        SaveProviderOperations -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobName $currentFilename

        [array] $blobs = Get-AzStorageBlob -Container $ContainerName -Context $storageAccount.context | Where-Object { $_.Name -like "$($BlobPrefix)*" } | Sort-Object -Property Name -Descending
        if (-not $blobs -or $blobs.Count -eq 0) {
            Write-Erorr "No files starting with $($BlobPrefix) found in container" -ErrorAction Stop
            return

        } elseif ($blobs.Count -eq 1) {
            Write-Error "Only 1 file starting with $($BlobPrefix) found in container. Not enough to compare. (This is normal for the very first execution.)" -ErrorAction Stop
            return

        } elseif ($blobs[0].Name -ne $currentFilename) {
            Write-Error "Unable to find today's file $($currentFileName) in $($StorageAccountName/$ContainerName)" -ErrorAction Stop
            return
        }

        $currentFileName = $blobs[0].Name
        $previousFileName = $blobs[1].Name

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
$currentOperations = (Get-Content $currentFilepath -ErrorAction Stop | ConvertFrom-Json).Operation | Sort-Object
$previousOperations = (Get-Content $previousFilepath -ErrorAction Stop | ConvertFrom-Json).Operation | Sort-Object

# find all changed roles
$differences = Compare-Object -ReferenceObject $previousOperations -DifferenceObject $currentOperations -ErrorAction Stop

# save changes to blob
if ($differences.Count -gt 0) {
    $tmpFilePath = New-TemporaryFile
    $differences | ConvertTo-Json -Depth 10 | Out-File -FilePath $tmpFilePath
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

return $differences
