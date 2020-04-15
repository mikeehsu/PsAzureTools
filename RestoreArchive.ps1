<#
.SYNOPSIS
Restore an archive from blob. 

.DESCRIPTION
This script will restore a compressed zip file from blob to a VM file system. If the blob is in the archive tier, it will rehydrate it first, before copying and restoring it.

.PARAMETER StorageAccountName
Name of the storage account to upload the archive file to. Cannot be used with ContainerURI.

.PARAMETER ContainerName
Name of the container to upload the archive file to. Cannot be used with ArchiveURI.

.PARAMETER ArchiveFilePath
Name of the container to upload the archive file to. Cannot be used with ArchiveURI.

.PARAMETER ArchiveURI
URI of the compressed archive file. Using this parameter assumes that you can only access this file via SAS token. When using ArchiveURI, the file will NOT be rehydrated. For files in an achive tier, the storage account naming convention will need to be used. Cannot be used with -StorageAccountName, -ContainerName, -ManagedIdentity, or -Environment

.PARAMETER DestinationPath
Path where the archive should be expanded into. This script will create a folder underneath the -DestinationPath, but it will NOT create it. This directory must exists before the script will start.

.PARAMETER WaitForRehydration
Sleep and wait for the rehydration from archive tier to complete then restore the files. If this is not specified, the rehydration will be requested then the script will exit.

.PARAMETER KeepArchiveFile
Keeps the archive zip file in the -ArchiveTempDir location after restoring the files. If not specified the zip file will be deleted from the local machine once expanding has completed successfully.

.PARAMETER ArchiveTempDir
Directory to use for the .7z archive compression to reside. If no directory is specific, the archive will be placed in the TEMP directory specified by the current environment variable.

.PARAMETER ZipCommandDir
Specifies the directory where the 7z.exe command can be found. If not specified, it will look in the current PATH 

.PARAMETER AzCopyCommandDir
Specifies the directory where the azcpoy.exe command can be found. If not specified, it will look in the current PATH 

.PARAMETER UseManagedIdentity
Specifies the use of Managed Identity to authenticate into Azure Powershell APIs and azcopy.exe. If not specified, the AzureCloud is use by default. Cannot be used with 

.PARAMETER Environment
Specifies the Azure cloud environment to use for authentication. If not specified the AzureCloud is used by default

.EXAMPLE
RestoreArchive.ps1 -StorageAccountName 'myStorageAccount' -ContainerName 'archive-continer' -ArchiveFilePath 'archive.7z' -DestinationPath c:\restored-archives
#>

[CmdletBinding()]
param (
    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $ContainerName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $false)]
    [string] $ArchiveFilePath,

    [Parameter(ParameterSetName = "ArchiveURI", Mandatory = $true)]
    [string] $ArchiveURI,

    [Parameter(Mandatory = $true)]
    [string] $DestinationPath,
        
    [Parameter(Mandatory = $false)]
    [switch] $WaitForRehydration,

    [Parameter(Mandatory = $false)]
    [switch] $KeepArchiveFile,

    [Parameter(Mandatory = $false)]
    [switch] $RestoreEmptyDirectories,

    [Parameter(Mandatory = $false)]
    [string] $ArchiveTempDir = $env:TEMP,

    [Parameter(Mandatory = $false)]
    [string] $ZipCommandDir = "",

    [Parameter(Mandatory = $false)]
    [string] $AzCopyCommandDir = "",

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $false)]
    [switch] $UseManagedIdentity,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $false)]
    [string] $Environment

)

#####################################################################
function LogOutput
{
    [CmdletBinding()]
    param (
        [Parameter(Position=0)]
        [string] $message,

        [Parameter(Position=1)]
        [string] $blobName
    )

    $logFile = $script:DestinationPath + $blobName + '.log'

    $output = "$(Get-Date) $message"

    $output | Out-File -Path $logFile -Append
    Write-Output $output
}

#####################################################################
function RestoreBlobFromURI {
    param (
        [parameter(Mandatory = $true)]
        [string] $archiveURI
    )

    $uri = [uri] $archiveURI
    $fileName = $uri.Segments[$uri.Segments.Count - 1]

    $params = @('copy', $archiveURI, $script:ArchiveTempDir)
    LogOutput -BlobName $fileName -Message "$script:azcopyExe $($params -join ' ') started."
    & $script:azcopyExe $params
    if (-not $?) {
        throw "Error copying  - $archiveURI to $script:ArchiveTempDir" 
    }

    $params = @('x', $($script:ArchiveTempDir + $fileName), "-o$script:DestinationPath", '-aoa')
    LogOutput -BlobName $fileName -Message "$script:zipExe $($params -join ' ') started. "
    & $script:zipExe $params
    if (-not $?) {
        throw "Error restoring archive - $($script:ArchiveTempDir + $fileName) to -o$script:DestinationPath" 
    }

    if (-not $KeepArchiveFile) {
        Remove-Item "$($script:ArchiveTempDir + $fileName)" -Force
    }

    LogOutput -BlobName $fileName -Message "==================== Restore of $filename to $script:DestinationPath complete ===================="
}

#####################################################################

function RestoreBlob {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $blob
    )

    while ($blob.ICloudBlob.Properties.StandardBlobTier -eq 'Archive' -or $blob.ICloudBlob.Properties.RehydrationStatus -eq 'PendingToHot') {
        $blobName = $blob.Name
        $containerName = $blob.ICloudBlob.container.Name

        LogOutput "$blobName - waiting for rehydration (update in 10 mins)... "
        Start-Sleep 600 # 10 mins
        $blob = Get-AzStorageBlob -Context $blob.Context -Container $containerName -Blob $blobName
        if (-not $blob) {
            LogOutput -BlobName $blobName -Message "Unable to find $blobName in $containerName"
            throw "Unable to find $blobName in $containerName"
        }
    }

    RestoreBlobFromURI -archiveURI $blob.ICloudBlob.Uri.Absoluteuri
}

#####################################################################
# MAIN

# check 7z command path
if ($ZipCommandDir -and -not $ZipCommandDir.EndsWith('\')) {
    $ZipCommandDir += '\'
}
$zipExe = $ZipCommandDir + '7z.exe'
$null = $(& $zipExe)
if (-not $?) {
    throw "Unable to find 7z.exe command. Please make sure 7z.exe is in your PATH or use -ZipCommandDir to specify 7z.exe path"
}

# check azcopy path
if ($AzCopyCommandDir -and -not $AzCopyCommandDir.EndsWith('\')) {
    $AzCopyCommandDir += '\'
}
$azcopyExe = $AzCopyCommandDir + 'azcopy.exe'

try {
    $null = Invoke-Expression -Command $azcopyExe -ErrorAction SilentlyContinue
}
catch {
    throw "Unable to find azcopy.exe command. Please make sure azcopy.exe is in your PATH or use -AzCopyCommandDir to specify azcopy.exe path"
}

if ($RestoreEmptyDirectories -and $ArchiveFilePath) {
    throw  "Incompatible parameters -RestoreEmptyDirectories can not be used with -ArchiveFilePath"
}

if (-not ($RestoreEmptyDirectories -or $ArchiveFilePath)) {
    throw  "-ArchiveFilePath or -RestoreEmptyDirectories must be provided"
}

if ($ArchiveTempDir -and -not $ArchiveTempDir.EndsWith('\')) {
    $ArchiveTempDir += '\'
}
if (-not $(Test-Path -Path $ArchiveTempDir)) {
    throw "Unable to find $ArchiveTempDir. Please check the -ArchiveTempDir and try again."
} 

# check destination filepath
if ($DestinationPath -and -not $DestinationPath.EndsWith('\')) {
    $DestinationPath += '\'
}
if (-not $(Test-Path -Path $DestinationPath)) {
    throw "Unable to find $DestinationPath. Please check the -DestinationPath and try again."
}

# login if using managed identities
if ($UseManagedIdentity) {
    try {
        $params = @{ }
        if ($Environment) {
            $params = @{'Environment' = $Environment }
        }
        Connect-AzAccount -Identity @params
    }
    catch {
        throw "Unable to login using managed identity."
    }

    # get context & environment
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context.Environment) {
            throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
        }
    }
    catch {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }    
    $environment = Get-AzEnvironment -Name $context.Environment

    # login to azcopy
    $params = @('login', '--identity', "--aad-endpoint", $environment.ActiveDirectoryAuthority)
    & $azcopyExe $params
    if (-not $?) {
        throw "Unable to login to azcopy using: $azcopyExe - $($params -join ' ')"
    }
}

if ($ArchiveURI) {
    RestoreFile -archiveURI $ArchiveURI
    return
}

# remain code relates to $PSCmdlet.ParameterSetName of 'StorageAccount')
# login to powershell az sdk
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw "Use of -StorageAccount parameter set requires logging in your current sessions first. Please use Connect-AzAccount to login and Select-AzSubscriptoin to set the proper subscription context before proceeding."
    }
}
catch {
    throw "Use of -StorageAccount parameter set requires logging in your current sessions first. Please use Connect-AzAccount to login and Select-AzSubscriptoin to set the proper subscription context before proceeding."
}

$resource = Get-AzResource -ResourceType 'Microsoft.Storage/storageAccounts' -Name $StorageAccountName
if (-not $resource) {
    throw "StorageAccount ($StorageAccountName) not found."
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $resource.ResourceGroupName -AccountName $StorageAccountName
if (-not $storageAccount) {
    throw "Error getting StorageAccount info $StorageAccountName"
}

$container = Get-AzStorageContainer -Name $ContainerName -Context $storageAccount.context
if (-not $container) {
    throw "Error getting container info for $ContainerName - "
}

# restore a single archive file
if ($ArchiveFilePath) {
    $blob = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Blob $ArchiveFilePath
    RestoreBlob -blob $blob
    return
}

if (-not $RestoreEmptyDirectories) {
    return
}

# restore any empty directories
$archiveBlobNames = @()
$dirs = Get-ChildItem $DestinationPath | Where-Object { $_.PSIsContainer }
foreach ($dir in $dirs) {
    if ($(Get-ChildItem $dir).Count -eq 0) {
        $archiveBlobNames += $dir.Name + '.7z'
    }
}

if (-not $archiveBlobNames) {
    Write-Output "No empty directories found. Nothing to do."
    return
}

$jobs = @()
foreach ($archiveBlobName in $archiveBlobNames) {
    $blob = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Blob $archiveBlobName
    if (-not $blob) {
        throw "Unable to find $archiveBlobName in $ContainerName"
    }

    # rehydrate blob if necessary
    if ($blob.ICloudBlob.Properties.StandardBlobTier -eq 'Archive') {
        if (-not $blob.ICloudBlob.Properties.RehydrationStatus) {
            $blob.ICloudBlob.SetStandardBlobTier("Hot", “Standard”)
            LogOutput -BlobName $archiveBlobName -Message "Rehydrate requested for: $($blob.Name)"
        }

        if (-not $WaitForRehydration) {
            LogOutput -BlobName $archiveBlobName -Message "File is rehydrating - current status: $($blob.ICloudBlob.Properties.RehydrationStatus)"
        }
    }

    # skip existing jobs
    $job = Get-Job -Name $archiveBlobName -ErrorAction SilentlyContinue
    if ($job -and $job.State -eq 'Running') {
        LogOutput -BlobName $archiveBlobName "$archiveBlobName (Job:$($job.Id)) already running, staus will be displayed"
        $jobs += $job
        continue 
    }

    # create new job
    $params = @{
        Name         = $archiveBlobName
        ScriptBlock  = { Param ($p1, $p2, $p3, $p4, $p5, $p6, $p7) .\Restore-ArchiveBlob.ps1 -StorageAccountName $p1 -ContainerName $p2 -ArchiveFilePath $p3 -DestinationPath $p4 -AzCopyCommandDir $p5 -ZipCommandDir $p6 -ArchiveTempDir $p7 }
        ArgumentList = $StorageAccountName, $ContainerName, $archiveBlobName, $($DestinationPath + $(Split-Path $archiveBlobName -LeafBase) + '\'), $AzCopyCommandDir, $ZipCommandDir, $ArchiveTempDir
    }
    $jobs += Start-Job @params
    LogOutput -BlobName $archiveBlobName -Message "$archiveBlobName job started"
}

$waitInterval = 5
$jobIds = [System.Collections.ArrayList] @($jobs.Id)
do {
    Write-Output "$(Get-Date) Waiting for jobs $($jobIds -join ', ')..."
    Start-Sleep -Seconds $waitInterval

    $CompleteJobIds = @()
    foreach ($jobId in $jobIds) {
        $job = Get-Job -Id $jobId
        if ($job.State -eq 'Running') {
            if ($job.HasMoreData) {
                $job | Receive-Job | ForEach-Object {
                    LogOutput -BlobName $job.name -Message "$($job.Name)> $_"
                }
            } else {
                $waitInterval++
                if ($waitInterval -gt 60) {
                    $waitInterval = 60
                }
            }
        }
        else {
            $job | Receive-Job | ForEach-Object {
                LogOutput -BlobName $job.name -Message "$($job.Name)> $_"
            }
            LogOutput -BlobName $job.name "$($job.Name)> $($job.ChildJobs[0].Error)"
            LogOutput -BlobName $job.name "$($job.Name)> ==================== $($job.Name) $($job.State) $($job.StatusMessage) ===================="
            Remove-Job $job
            $CompleteJobIds += $jobId
        }    
    }

    # remove any completed job from array
    foreach ($jobId in $CompleteJobIds) {
        $jobIds.Remove($jobId)
    } 
} until (-not $jobIds)

Write-Output "Script complete."
