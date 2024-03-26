<#
.SYNOPSIS
Compress files in a directory and upload to storage container blob.

.DESCRIPTION
This script will compress a file or directory using 7-Zip and upload it to a storage container blob using AzCopy. The was meant for use with automation tools to archive large directory or flies to save on storage costs vs keeping the files on the local VM disks.

.PARAMETER SourceFilePath
Source path on the local machine to compress

.PARAMETER StorageAccountName
Name of the storage account to upload the compressed file to. Cannot be used with ContainerURI.

.PARAMETER ContainerName
Name of the container to upload the compressed file to. Cannot be used with ContainerURI

.PARAMETER ContainerURI
URI of container. When using ContainerURI, this should contain any SAS token necessary to upload the archive. Cannot be used with -StorageAccountName, -ContainerName, -ManagedIdentity, or -Environment

.PARAMETER BlobName
Name of archive flie. This will default to the filename or directory name with a .7z extension when compressing the file(s).

.PARAMETER SeparateEachDirectory
Separate out each directory in the -SourceFilePath into a separate zip file

.PARAMETER AppendToBlobName
Append the current date or datetime to the BlobName

.PARAMETER CompressTempDir
Directory to use for the .7z compression. If no directory is specific, the archive will be placed in the TEMP directory specified by the current environment variable.

.PARAMETER IntegrityCheck
Perform a validation check on the created compressed file. If no value is specified, validation check will default to 'Simple'

.PARAMETER BlobTier
Set the Blob to the specified storage blob tier

.PARAMETER SplitZipSize
Set the size to split the zip files into. The default is to NOT split the file.

.PARAMETER Password
Set a password for the archive zip file. If no password is provided, the zip file will not be encrypted.

.PARAMETER CleanUpDir
After upload move files to certain location. Valid values are Delete, RecycleBin or a directory path.

.PARAMETER ZipCommandDir
Specifies the directory where the 7z.exe command can be found. If not specified, it will look in the current PATH

.PARAMETER AzCopyCommandDir
Specifies the directory where the azcpoy.exe command can be found. If not specified, it will look in the current PATH

.PARAMETER UseManagedIdentity
Specifies the use of Managed Identity to authenticate into Azure Powershell APIs and azcopy.exe. If not specified, the AzureCloud is use by default.

.PARAMETER Environment
Specifies the Azure cloud environment to use for authentication. If not specified the AzureCloud is used by default

.EXAMPLE
CompressFilesToBlob.ps1 -SourceFilePath C:\TEMP\archivefiles -StorageAccountName 'myStorageAccount' -ContainerName 'archive'

.EXAMPLE
CompressFilesToBlob.ps1 -SourceFilePath C:\TEMP\archivefiles -ContainerURI 'https://test.blob.core.windows.net/archive/?st=2020-03-16T14%3A56%3A11Z&se=2020-03-17T14%3A56%3A11Z&sp=racwdl&sv=2018-03-28&sr=c&sig=uz9iBor1vhsUgrqjcU53fkGB6MQ8I%2BeI6got784E75I%3D'

#>

[CmdletBinding()]
param (
    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [Parameter(ParameterSetName = "ContainerURI", Mandatory = $true)]
    [string] $SourceFilePath,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $ContainerName,

    [Parameter(ParameterSetName = "ContainerURI", Mandatory = $true)]
    [Parameter(ParameterSetName = "PartialZip", Mandatory = $true)]
    [string] $ContainerURI,

    [string] $BlobName,

    [ValidateSet('Date', 'Time')]
    [string] $AppendToBlobName,

    [ValidateSet(0, 1, 2, 3, 4, 5, 6, 7, 8, 9)]
    [int] $CompressionLevel = 5,

    [string] $CompressTempDir = $env:TEMP,

    [switch] $SeparateEachDirectory,

    [ValidateSet('Simple', 'Full', 'None')]
    [string] $IntegrityCheck = "Simple",

    [ValidateSet('Hot', 'Cool', 'Archive')]
    [string] $BlobTier,

    [ValidatePattern('[0-9]*[m,M,g,G]?')]
    [string] $SplitZipSize,

    [int] $PartialZipUploadInterval = 0,

    [securestring] $Password,

    [switch] $KeepLocalCompressFiles,

    [Alias("CompletedDir")]
    [string] $CleanUpDir,

    [string] $ZipCommandDir = "",

    [string] $AzCopyCommandDir = "",

    [Parameter(ParameterSetName = "StorageAccount")]
    [switch] $UseManagedIdentity,

    [Parameter(ParameterSetName = "StorageAccount")]
    [string] $Environment

)

#####################################################################

function IntegrityCheckFull {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $filePath,

        [Parameter(Mandatory = $true)]
        [string] $sourcePath
    )

    Write-Host "Performing full integrity check of $filePath against $sourcePath..."

    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # load CRC list from zip file
    $currentPath = $null
    $zipCRC = @{ }
    Write-Debug "Loading CRC from $filePath..."
    $params = @('l', '-slt')

    if ($script:SplitZipSize) {
        $params += $filePath + '.001'
    }
    else {
        $params += $filePath
    }

    if ($script:Password) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($script:Password)
        $result = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
        $params += "-p$result"
    }

    & $script:zipExe $params | ForEach-Object {
        if ($_.StartsWith('Path')) {
            $currentPath = $_.Substring($_.IndexOf('=') + 2)
        }
        elseif ($_.StartsWith('CRC')) {
            $zipCRC[$currentPath] = $_.Substring($_.IndexOf('=') + 2)
        }
    }

    # get CRC from source filepath and compare against list from zip file
    # sample CRC: 852DD72D      57490143  temp\20191230_hibt_chicken.mp3_bf969ccfdacaede5b20f6473ef9da0c8_57490143.mp3
    $endReached = $false
    $itemsChecked = 0
    $errorCount = 0
    Write-Debug "Checking CRC from $sourcePath..."
    $params = @('h', $sourcePath)
    & $script:zipExe $params | Select-Object -Skip 8 | ForEach-Object {
        if (-not $endReached) {
            $crc = $_.Substring(0, 8)
            $path = $_.Substring(24)
        }

        if ($endReached) {
            # do nothing
        }
        elseif ($crc -eq '--------') {
            $endReached = $true
        }
        elseif ($zipCRC[$path] -eq $crc) {
            # CRC matches
            # do nothing
        }
        elseif ($crc -eq '        ' -or $crc -eq '00000000') {
            # folder or 0 btye file
            # supress error
        }
        elseif (-not $zipCRC[$path]) {
            Write-Warning "NOT FOUND -- $path"
            $errorCount++
        }
        else {
            Write-Warning "CRC MISMATCH -- ARCHIVE CRC: $crc - SOURCE: $($zipCRC[$path]) - $path"
            $errorCount++
        }
        $itemsChecked++
    }

    if ($errorCount -gt 0) {
        Write-Warning "$errorCount error(s) detected. $itemsChecked items checked. Please check issues before continuing. ($($stopwatch.Elapsed))"
        return $false
    }

    Write-Host "$filePath full integrity check completed successfully. $itemsChecked items checked. ($($stopwatch.Elapsed))"
    return $true
}

#####################################################################
function IntegrityCheckSimple {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $filePath
    )

    Write-Host "Performing simple integrity check of $filePath..."

    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $params = @('t')

    if ($script:SplitZipSize) {
        $params += $filePath + '.001'
    }
    else {
        $params += $filePath
    }

    if ($script:Password) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($script:Password)
        $result = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
        $params += "-p$result"
    }

    & $script:zipExe $params
    if (-not $?) {
        return $false
    }

    Write-Host "$filePath simple integrity check completed successfully. ($($stopwatch.elapsed))"
    return $true
}

#####################################################################
function CompressPathToBlob {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $sourcePath,

        [Parameter(Mandatory)]
        [string] $archivePath
    )

    # check for existing zip file
    if (Test-Path -Path $archivePath) {
        $answer = Read-Host "$archivePath already exists. (Replace/Update/Skip/Cancel)?"
        if ($answer -like 'C*') {
            Write-Host "User cancelled."
            exit

        }
        elseif ($answer -like 'S*') {
            Write-Host "Write-Output $sourcePath skipped"
            return
        }
        elseif ($answer -like 'R*') {
            Remove-Item -Path $archivePath -Force
        }
    }

    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # zip the source
    $params = @('u')
    $params += '-m0=lzma2'
    $params += "-mx=$($CompressionLevel)"

    if ($SplitZipSize) {
        $params += "-v$SplitZipSize"
    }

    if ($script:Password) {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($script:Password)
        $result = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
        $params += "-p$result"
    }

    $params += $archivePath
    $params += $sourcePath

    Write-Verbose "Archiving $sourcePath to $archivePath..."
    & $script:zipExe $params
    if (-not $?) {
        Write-Error "ERROR creating archive: $archivePath from: $sourcePath"
        Get-Job | Stop-Job
        Get-Job | Remove-Job
        throw
    }
    # clean up upload jobs
    Get-Job | Stop-Job
    Get-Job | Remove-Job

    Write-Host "$archivePath created. ($($stopwatch.Elapsed))"

    # check compressed file
    $result = $true
    if ($script:IntegrityCheck -eq 'None') {
        # skip the integrity check
    }
    elseif ($script:IntegrityCheck -eq 'Simple') {
        $result = IntegrityCheckSimple -filePath $archivePath
    }
    elseif ($script:IntegrityCheck -eq 'Full') {
        $result = IntegrityCheckFull -filePath $archivePath -sourcePath $sourcePath

    }
    else {
        $result = $false
        Write-Error "-IntegrityCheck $IntegrityCheck invaild. No integrity check performed."
    }

    if (-not $result) {
        Write-Warning "ERROR -- found when comparing $archivePath to $sourcePath"
    }

    $script:fileContinue = $result
}

#####################################################################
function CopyFileToContainer {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $filePath,

        [Parameter(Mandatory)]
        [string] $containerURI
    )

    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # upload file
    $uri = [uri] $ContainerURI
    $path = [System.IO.FileInfo] $filePath

    if ($SplitZipSize) {
        $filePath = $filePath + '.*'
        $destinationUri = 'https://' + $uri.Host + "$($uri.LocalPath)" + $uri.Query
    }
    else {
        $destinationUri = 'https://' + $uri.Host + "$($uri.LocalPath)/$($path.Name)" + $uri.Query
    }

    Write-Host "Copy $filePath to $destinationURI started."

    # using & command syntax since Invoke-Expression doesn't throw an error
    $params = @('copy', "$filePath" , $destinationURI, "--check-length")
    if ($script:BlobTier) {
        $params += ("--block-blob-tier=$script:BlobTier")
    }

    try {
        & $script:azCopyExe $params
    }
    catch {
        Write-Error "ERROR uploading file: $filePath to $containerURI"
        $script:fileContinue = $false
        return
    }
    Write-Host "$($uri.Host)$($uri.LocalPath)/$($path.Name) copy complete. ($($stopwatch.Elapsed))"
}

#####################################################################
function Test-IsFileLocked {

    # copied from https://mcpmag.com/articles/2018/07/10/check-for-locked-file-using-powershell.aspx

    [cmdletbinding()]
    Param (
        [parameter(Mandatory = $True, ValueFromPipeline = $True, ValueFromPipelineByPropertyName = $True)]
        [Alias('FullName', 'PSPath')]
        [string[]] $Path
    )

    Process {
        ForEach ($Item in $Path) {
            #Ensure this is a full path
            $Item = Convert-Path $Item
            #Verify that this is a file and not a directory
            If ([System.IO.File]::Exists($Item)) {
                Try {
                    $FileStream = [System.IO.File]::Open($Item, 'Open', 'Write')
                    $FileStream.Close()
                    $FileStream.Dispose()
                    $IsLocked = $False
                }
                Catch [System.UnauthorizedAccessException] {
                    $IsLocked = 'AccessDenied'
                }
                Catch {
                    $IsLocked = $True
                }
                [pscustomobject] @{
                    FullName = $Item
                    IsLocked = $IsLocked
                }
            }
        }
    }
}

#####################################################################
function CleanUpSource {

    [cmdletbinding()]
    Param (
        [Parameter(Mandatory)]
        [string] $sourcePath,

        [Parameter(Mandatory)]
        [string] $cleanUpDir
    )

    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # clean up source files
    if ($CleanUpDir -eq 'Delete') {
        Remove-Item -Path $sourcePath -Recurse -Force
        Write-Information "$sourcePath deleted ($($stopwatch.Elapsed))"

    }
    elseif ($CleanUpDir) {
        Move-Item -Path $sourcePath -Destination $CleanUpDir
        Write-Information "$sourcePath moved to $CleanupDir ($($stopwatch.Elapsed))"
    }

}

#####################################################################
function UploadPartialZip {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string] $ContainerUri,

        [Parameter()]
        [int] $PartialZipUploadInterval = 60,

        [Parameter()]
        [string] $BlobTier,

        [Parameter()]
        [string] $AzCopyExe,

        [Parameter()]
        [string] $OutputLog = "$env:TEMP\PartialZipUpload-$(Get-Date -Format 'yyyyMMdd').log"
    )

    # start processing
    $path = ([System.IO.FileInfo] $FilePath).DirectoryName
    $uri = [uri] $ContainerUri

    $filesUploaded = @()

    "$(Get-Date -Format u) Job started"  | Out-File -FilePath $OutputLog -Append

    while ($true) {
        $files = Get-ChildItem $path | Where-Object { $_.LastWriteTime.AddMinutes(1) -lt $(Get-Date) -and $filesUploaded -notcontains $_.Name }
        foreach ($file in $files) {

            # if file locked, copy to temp dir
            $sourcePath = $file.FullName
            $fileCopied = $false

            # check for file lock
            Try {
                $FileStream = [System.IO.File]::Open($file, 'Open', 'Write')
                $FileStream.Close()
                $FileStream.Dispose()
                $IsLocked = $False
            }
            Catch [System.UnauthorizedAccessException] {
                $IsLocked = 'AccessDenied'
            }
            Catch {
                $IsLocked = $True
            }

            # copy locked file to temp dir
            if ($isLocked) {
                $fileCopied = $true
                $sourcePath = "$env:TEMP\$($file.Name)"

                Copy-Item $file.FullName $sourcePath 2>&1 >> $OutputLog
                if (-not $?) {
                    continue
                }
            }

            $destinationURI = 'https://' + $uri.Host + "$($uri.LocalPath)/$($file.Name)" + $uri.Query
            "$(Get-Date -Format u) copying...$sourcePath to $destinationUri" | Out-File -FilePath $OutputLog -Append
            $params = @('copy', $sourcePath , $destinationUri)
            if ($BlobTier) {
                $params += ("--block-blob-tier=$BlobTier")
            }

            & $AzCopyExe $params 2>&1 >> $OutputLog
            if (-not $?) {
                Write-Error "ERROR: unable to copy $sourcePath to $destinationUri" 2>&1 >> $OutputLog
                continue
            }

            # clean up copied file
            if ($fileCopied) {
                Remove-Item $sourcePath -Force
            }

            $filesUploaded += $file.Name
            "$(Get-Date -Format u) $($Uploaded.Count) copied" | Out-File -FilePath $transferLog -Append
        }

        "$(Get-Date -Format u) $($filesUploaded.Count) copied. Waiting for new files...($PartialZipUploadInterval secs)" | Out-File -FilePath $OutputLog -Append
        Start-Sleep -Seconds $PartialZipUploadInterval
    }
}

#####################################################################
function SyncPartialZip {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string] $ContainerUri
    )

    $path = ([System.IO.FileInfo] $filePath).DirectoryName

    $params = @('sync', $path , $ContainerUri)
    if ($script:BlobTier) {
        $params += ("--block-blob-tier=$script:BlobTier")
    }

    try {
        & $script:azCopyExe $params
    }
    catch {
        throw "ERROR syncing file: $path to $containerURI"
    }
}

#####################################################################
# MAIN

# check azcopy path
Write-Progress -Activity "Checking environment..." -Status "validating AzCopy"
if ($AzCopyCommandDir -and -not $AzCopyCommandDir.EndsWith('\')) {
    $AzCopyCommandDir += '\'
}
$azcopyExe = $AzCopyCommandDir + 'azcopy.exe'
try {
    $null = Invoke-Expression -Command $azcopyExe -ErrorAction SilentlyContinue
}
catch {
    Write-Error "Unable to find azcopy.exe command. Please make sure azcopy.exe is in your PATH or use -AzCopyCommandPath to specify azcopy.exe path" -ErrorAction Stop
}

# check 7z command path
Write-Progress -Activity "Checking environment..." -Status "validating 7z"
if ($ZipCommandDir -and -not $ZipCommandDir.EndsWith('\')) {
    $ZipCommandDir += '\'
}
$zipExe = $ZipCommandDir + '7z.exe'
$null = $(& $zipExe)
if (-not $?) {
    throw "Unable to find 7z.exe command. Please make sure 7z.exe is in your PATH or use -ZipCommandPath to specify 7z.exe path"
}

# login if using managed identities
Write-Progress -Activity "Checking environment..." -Status "validating Azure identity/environment"
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
}

if ($PSCmdlet.ParameterSetName -eq 'StorageAccount') {
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

    $sasToken = New-AzStorageAccountSASToken -Context $storageAccount.context -Service Blob -ResourceType Service, Container, Object -Permission racwdlup -ExpiryTime $(Get-Date).AddDays(5)
    if (-not $sasToken.StartsWith('?')) {
        # necessary for breaking change introduced with Az.Storage v6.0+
        $sasToken = '?' + $sasToken
    }
    $ContainerURI = $storageAccount.PrimaryEndpoints.Blob + $ContainerName + $sasToken
}

# check -CleanUpDir parameter
if (-not $CleanUpDir) {
    # do nothing
}
elseif ($CleanUpDir -eq 'Delete' -or $CleanUpDir -eq 'RecycleBin') {
    # do nothing

}
else {
    if (-not (Test-Path $CleanUpDir -PathType Container)) {
        throw "-CleanupDir $CleanUpDir is not valid. Must be either Delete, RecycleBin or a valid directory."
    }
}

# check -ArchiveTempFilePath
if ($CompressTempDir -and -not $CompressTempDir.EndsWith('\')) {
    $CompressTempDir += '\'
}

if (-not $(Test-Path -Path $CompressTempDir)) {
    throw "Unable to find $CompressTempDir. Please check the -CompressTempDir and try again."
}

# check source filepath
if (-not $(Test-Path -Path $SourceFilePath)) {
    Write-Error "Unable to find $SourceFilePath. Please check the -SourceFilePath and try again." -ErrorAction Stop
}

# invalid combination -SeparateEachDirectory will force the use of directory name
if ($BlobName -and $SeparateEachDirectory) {
    throw "-BlobName and -SeparateEachDirectory can not be used together."
}

Write-Progress -Activity "Checking environment..." -Status "reading source directory"
if ($SeparateEachDirectory) {
    # loop through each directory and upload a separate zip
    $sourcePaths = $(Get-ChildItem $SourceFilePath | Where-Object { $_.PSIsContainer }).FullName

}
else {
    $sourcePaths = $SourceFilePath
}

# remove the progress bar
Write-Progress  -Activity "Checking environment..." -Completed

# start processing
$stopWatchStart = [System.Diagnostics.Stopwatch]::StartNew()

$archiveSuccesses = @()
$archiveFailures = @()
foreach ($sourcePath in $sourcePaths) {
    $fileContinue = $true

    if ($BlobName) {
        # only one large blob being created
        $archivePath = $CompressTempDir + $BlobName
    }
    else {
        if ($SplitZipSize) {
            $archivePath = $CompressTempDir + $(Split-Path $sourcePath -Leaf)
            if (-not (Test-Path $archivePath)) {
                New-Item -Path $archivePath -ItemType Directory
            }
            $archivePath = $archivePath + '\' + $(Split-Path $sourcePath -Leaf) + '.7z'
        }
        else {
            $archivePath = $CompressTempDir + $(Split-Path $sourcePath -Leaf) + '.7z'
        }
    }

    # check to see if another archive is in progress
    $existingFiles = Get-Item "$($(Split-Path -Path $archivePath -Parent) + '\' + $(Split-Path -Path $archivePath -LeafBase) + '*')"
    if ($existingFiles) {
        $lockedFiles = Test-IsFileLocked -Path $existingFiles.FullName | Where-Object { $_.IsLocked }
        if ($lockedFiles) {
            Write-Host "$sourcePath skipped. Existing $($lockedFiles.FullName) is locked."
            continue
        }
        else {
            Write-Information "Cleaning up leftover files $($existingFiles.FullName)"
            $existingFiles | Remove-Item
        }
    }

    # add date/datetime to filename
    if ($AppendToBlobName) {
        $path = [System.IO.FileInfo] $archivePath
        if ($AppendToBlobName -eq 'Time') {
            $dateStr = "{0:yyyyMMddHHmmss}" -f $(Get-Date)
        }
        else {
            $dateStr = "{0:yyyyMMdd}" -f $(Get-Date)
        }
        $archivePath = $path.DirectoryName + '\' + $path.BaseName + '_' + $dateStr + $path.Extension
    }

    Write-Host ''
    Write-Host "==================== $(Split-Path $archivePath -Leaf) started. $(Get-Date) ===================="
    Write-Host ''

    if ($PartialZipUploadInterval) {
        $uploadLogPath = "$env:TEMP\PartialZipUpload-$(Get-Date -Format 'yyyyMMdd').log"

        # extract & build UploadPartialZip function from current context to pass into job
        $initScript = [ScriptBlock]::Create((Get-Command UploadPartialZip).ScriptBlock.StartPosition.Content)

        $job = Start-Job -InitializationScript $initScript `
            -ScriptBlock { UploadPartialZip -FilePath $using:archivePath -ContainerUri $using:ContainerUri -PartialZipUploadInterval $using:PartialZipUploadInterval -BlobTier $using:BlobTier -AzCopyExe $using:azcopyExe -OutputLog $using:uploadLogPath }

        Write-Information "Upload Job $($job.Id) started. Check logs at: $uploadLogPath"
    }

    CompressPathToBlob -SourcePath $sourcePath -archivePath $archivePath
    if (-not $fileContinue) {
        $archiveFailures += $sourcePath
        Write-Warning "ERROR -- $sourcePath failed compression to $archivePath. Please check errors and try again."
        continue
    }

    # upload files to storage account
    if ($PartialZipUploadInterval) {
        # copy any final files
        SyncPartialZip -filePath $archivePath -ContainerURI $ContainerURI
    }
    else {
        # copy all files
        CopyFileToContainer -filePath $archivePath -ContainerURI $ContainerURI
    }

    if (-not $fileContinue) {
        $archiveFailures += $sourcePath
        Write-Warning "ERROR -- $archivePath failed copy to $ContainerURI. Please check errors and try again."
        continue
    }

    # clean up zip file
    if (-not $KeepLocalCompressFiles) {
        Remove-Item -Path "$archivePath*" -Force
    }

    # clean up source files
    if ($CleanUpDir) {
        CleanUpSource -sourcePath $sourcePath -cleanUpDir $CleanUpDir
    }

    Write-Host ''
    Write-Host "==================== $(Split-Path $archivePath -Leaf) complete. $(Get-Date) ===================="
    Write-Host ''

    $archiveSuccesses += $sourcePath
}

if ($archiveSuccesses) {
    Write-Information ''
    Write-Information '===== SUCCESSFULLY PROCESSED ====='
    $archiveSuccesses | ForEach-Object {
        Write-Information $_
    }
}

if ($archiveFailures) {
    Write-Information ""
    Write-Information "===== FAILED ====="
    $archiveFailures | ForEach-Object {
        Write-Information $_
    }
}

Write-Host ""
Write-Host "===== FINAL STATS ====="
Write-Host "$($archiveSuccesses.Count) succeeded"
Write-Host "$($achiveFailures.count) failed"
Write-Host ""
Write-Host "Script Complete. $(Get-Date) - Total Elapsed: $($stopWatchStart.Elapsed.ToString())"
