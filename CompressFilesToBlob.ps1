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
    [Parameter(Mandatory)]
    [string] $SourceFilePath,
    
    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $ContainerName,

    [Parameter(ParameterSetName = "ContainerURI", Mandatory = $true)]
    [string] $ContainerURI,

    [string] $BlobName,

    [ValidateSet('Date', 'Time')]
    [string] $AppendToBlobName,

    [ValidateSet(0,1,2,3,4,5,6,7,8,9)]
    [int] $CompressionLevel = 5,

    [string] $CompressTempDir = $env:TEMP,

    [switch] $SeparateEachDirectory,

    [ValidateSet('Simple', 'Full', 'None')]
    [string] $IntegrityCheck = "Simple",

    [ValidateSet('Hot', 'Cool', 'Archive')]
    [string] $BlobTier,

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

    Write-Verbose "Performing full integrity check of $filePath against $sourcePath..."

    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # load CRC list from zip file
    $currentPath = $null
    $zipCRC = @{ }
    Write-Debug "Loading CRC from $filePath..."
    $params = @('l', '-slt', $filePath)
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

    Write-Information "$filePath full integrity check completed successfully. $itemsChecked items checked. ($($stopwatch.Elapsed))"
    return $true
}

#####################################################################
function IntegrityCheckSimple {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $filePath
    )

    Write-Verbose "Performing simple integrity check of $filePath..."
    
    # start a timer
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $params = @('t', $filePath)
    & $script:zipExe $params
    if (-not $?) {
        return $false
    }   

    Write-Information "$filePath simple integrity check completed successfully. ($($stopwatch.elapsed))"
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
            Write-Output "User cancelled." 
            exit

        }
        elseif ($answer -like 'S*') {
            Write-Output "Write-Output $sourcePath skipped" 
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
    $params += "-mx=$($CompressionLevel)"
    $params += $archivePath
    $params += $sourcePath
    
    Write-Verbose "Archiving $sourcePath to $archivePath..."
    & $script:zipExe $params 
    if (-not $?) {
        Write-Error "Error creating archive: $archivePath from: $sourcePath"
        throw
    }
    Write-Information "$archivePath created. ($($stopwatch.Elapsed))"

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

    } else {
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
    $destinationURI = 'https://' + $uri.Host + "$($uri.LocalPath)/$($path.Name)" + $uri.Query 
    
    Write-Verbose "Copy $($path.Name) to $destinationURI started."

    # using & command syntax since Invoke-Expression doesn't throw an error
    $params = @('copy', $filePath, $destinationURI, "--check-length")
    if ($script:BlobTier) {
        $params += ("--block-blob-tier=$script:BlobTier")
    }

    & $script:azCopyExe $params
    if (-not $?) {
        Write-Error "ERROR Context "ContextName" {
            It "ItName" {
                Assertion
            }
        } uploading file: $filePath to $containerURI"
        $script:fileContinue = $false
    }

    Write-Information "$($uri.Host)$($uri.LocalPath)/$($path.Name) copy complete. ($($stopwatch.Elapsed))"
}

#####################################################################
Function Test-IsFileLocked {

    # copied from https://mcpmag.com/articles/2018/07/10/check-for-locked-file-using-powershell.aspx

    [cmdletbinding()]
    Param (
        [parameter(Mandatory=$True,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True)]
        [Alias('FullName','PSPath')]
        [string[]] $Path
    )

    Process {
        ForEach ($Item in $Path) {
            #Ensure this is a full path
            $Item = Convert-Path $Item
            #Verify that this is a file and not a directory
            If ([System.IO.File]::Exists($Item)) {
                Try {
                    $FileStream = [System.IO.File]::Open($Item,'Open','Write')
                    $FileStream.Close()
                    $FileStream.Dispose()
                    $IsLocked = $False
                } Catch [System.UnauthorizedAccessException] {
                    $IsLocked = 'AccessDenied'
                } Catch {
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
Function CleanUpSource {

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

    } elseif ($CleanUpDir) {
        Move-Item -Path $sourcePath -Destination $CleanUpDir
        Write-Information "$sourcePath moved to $CleanupDir ($($stopwatch.Elapsed))"
    }

}
#####################################################################
# MAIN

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

    $ContainerURI = $storageAccount.PrimaryEndpoints.Blob + $ContainerName + $(New-AzStorageAccountSASToken -Context $storageAccount.context -Service Blob -ResourceType Service,Container,Object -Permission racwdlup -ExpiryTime $(Get-Date).AddDays(5))
}

# check -CleanUpDir parameter
if (-not $CleanUpDir) {
    # do nothing
}
elseif ($CleanUpDir -eq 'Delete' -or $CleanUpDir -eq 'RecycleBin') {
        # do nothing

} else {
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
    Write-Error "Unable to find $SourceFilePath. Please check the -SourcePath and try again." -ErrorAction Stop
} 

# invalid combination -SeparateEachDirectory will force the use of directory name
if ($BlobName -and $SeparateEachDirectory) {
    throw "-BlobName and -SeparateEachDirectory can not be used together."
}

Write-Progress -Activity "Checking environment..." -Status "reading source directory"
if ($SeparateEachDirectory) {
    # loop through each directory and upload a separate zip
    $sourcePaths = $(Get-ChildItem $SourceFilePath | Where-Object { $_.PSIsContainer }).FullName

} else {
    $sourcePaths = $SourceFilePath
}

# remove the progress bar
Write-Progress  -Activity "Checking environment..." -Completed

$archiveSuccesses = @()
$archiveFailures = @()
foreach ($sourcePath in $sourcePaths) {
    $fileContinue = $true

    if ($BlobName) {
        # only one large blob being created
        $archivePath = $CompressTempDir + $BlobName
    } else {
        $archivePath = $CompressTempDir + $(Split-Path $sourcePath -Leaf) + '.7z'
    }
 
    # check to see if another archive is in progress
    $existingFiles = Get-Item "$($(Split-Path -Path $archivePath -Parent) + '\' + $(Split-Path -Path $archivePath -LeafBase) + '*')"
    if ($existingFiles) {
        $lockedFiles = Test-IsFileLocked -Path $existingFiles.FullName | Where-Object {$_.IsLocked}
        if ($lockedFiles) {
            Write-Output "$sourcePath skipped. Existing $($lockedFiles.FullName) is locked."
            continue
        } else {
            Write-Output "Cleaning up leftover files $($existingFiles.FullName)"
            $existingFiles | Remove-Item
       }
    }

    # add date/datetime to filename
    if ($AppendToBlobName) {
        $path = [System.IO.FileInfo] $archivePath
        if ($AppendToBlobName -eq 'Time') {
            $dateStr = "{0:yyyyMMddHHmmss}" -f $(Get-Date)
        } else {
            $dateStr = "{0:yyyyMMdd}" -f $(Get-Date)
        }
        $archivePath = $path.DirectoryName + '\' + $path.BaseName + '_' + $dateStr + $path.Extension
    }

    Write-Output ''
    Write-Output "==================== $(Split-Path $archivePath -Leaf) started. $(Get-Date) ===================="
    Write-Output ''

    CompressPathToBlob -SourcePath $sourcePath -archivePath $archivePath
    if (-not $fileContinue) {
        $archiveFailures += $sourcePath
        Write-Warning "ERROR -- $sourcePath failed compression to $archivePath. Please check errors and try again."
        continue        
    }

    CopyFileToContainer -filePath $archivePath -ContainerURI $ContainerURI
    if (-not $fileContinue) {
        $archiveFailures += $sourcePath
        Write-Warning "ERROR -- $archivePath failed copy to $ContainerURI. Please check errors and try again."
        continue
    }
    
    # clean up zip file
    Remove-Item -Path $archivePath -Force

    # clean up source files
    if ($CleanUpDir) {
        CleanUpSource -sourcePath $sourcePath -cleanUpDir $CleanUpDir
    }

    Write-Output ''
    Write-Output "==================== $(Split-Path $archivePath -Leaf) complete. $(Get-Date) ===================="
    Write-Output ''
    
    $archiveSuccesses += $sourcePath
}

if ($archiveSuccesses) {
    Write-Output ''
    Write-Output '===== SUCCESSFULLY PROCESSED ====='
    Write-Output $archiveSuccesses
}

if ($archiveFailures) {
    Write-Output ""
    Write-Output "===== FAILED ====="
    Write-Output $archiveFailures
}

Write-Output ""
Write-Output "===== FINAL STATS ====="
Write-Output "$($archiveSuccesses.Count) succeeded"
Write-Output "$($achiveFailures.count) failed"
Write-Output ""
Write-Output "Script Complete. $(Get-Date)"
