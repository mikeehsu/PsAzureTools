<#
.SYNOPSIS
Compress files in a directory and upload to storage container blob. 

.DESCRIPTION
This script will compress a file or directory using 7-Zip and upload it to a storage container blob using AzCopy.
The was meant for use with automation tools to archive large directory or flies to save on storage costs vs keeping
the files on the local VM disks.

.PARAMETER SourceFilePath
Source path on the local machine to archive

.PARAMETER StorageAccountName
Name of the storage account to upload the archive file to. Cannot be used with ContainerURI.

.PARAMETER ContainerName
Name of the container to upload the archive file to. Cannot be used with ContainerURI

.PARAMETER ContainerURI
URI of container. When using ContainerURI, this should contain any SAS token necessary to upload the archive. Cannot be used with -StorageAccountName, -ContainerName, -ManagedIdentity, or -Environment

.PARAMETER ArchiveFileName
Name of archive flie. This will default to the filename or directory name with a .7z extension when compressing the file(s).

.PARAMETER AppendDateToFileName
Add the current date to the ArchiveFileName

.PARAMETER ArchiveTempDir
Directory to use for the .7z archive compression. If no directory is specific, the archive will be placed in the TEMP directory specified by the current environment variable.

.PARAMETER ArchiveCheck
Perform a validation check on the created archive file. If no value is specified, validation check will default to 'Simple'

.PARAMETER BlobTier
Set the Blob to the specified storage blob tier

.PARAMETER ZipCommandDir
Specifies the directory where the 7z.exe command can be found. If not specified, it will look in the current PATH 

.PARAMETER AzCopyCommandDir
Specifies the directory where the azcpoy.exe command can be found. If not specified, it will look in the current PATH 

.PARAMETER UseManagedIdentity
Specifies the use of Managed Identity to authenticate into Azure Powershell APIs and azcopy.exe. If not specified, the AzureCloud is use by default. Cannot be used with 

.PARAMETER Environment
Specifies the Azure cloud environment to use for authentication. If not specified the AzureCloud is used by default

.EXAMPLE
CompressFilesToBlob.ps1 -SourceFilePath C:\TEMP\archivefiles -StorageAccountName 'myStorageAccount' -ContainerName 'archive'

.EXAMPLE
CompressFilesToBlob.ps1 -SourceFilePath C:\TEMP\archivefiles -ContainerURI 'https://test.blob.core.windows.net/archive/?st=2020-03-16T14%3A56%3A11Z&se=2020-03-17T14%3A56%3A11Z&sp=racwdl&sv=2018-03-28&sr=c&sig=uz9iBor1vhsUgrqjcU53fkGB6MQ8I%2BeI6got784E75I%3D'

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $SourceFilePath,
    
    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $ContainerName,

    [Parameter(ParameterSetName = "ContainerURI", Mandatory = $true)]
    [string] $ContainerURI,

    [Parameter(Mandatory = $false)]
    [switch] $AppendDateToFileName,

    [Parameter(Mandatory = $false)]
    [string] $ArchiveTempDir = $env:TEMP,

    [Parameter(Mandatory = $false)]
    [string] $ArchiveFileName,

    [Parameter(Mandatory = $false)]
    [switch] $SeparateEachDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Simple', 'Full', 'None')]
    [string] $ArchiveCheck = "Simple",

    [Parameter(Mandatory = $false)]
    [ValidateSet('Hot', 'Cool', 'Archive')]
    [string] $BlobTier,

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

function ArchiveCheckFull {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $filePath,

        [Parameter(Mandatory = $true)]
        [string] $sourcePath
    )

    # load CRC list from zip file
    $startTime = Get-Date
    $currentPath = $null
    $zipCRC = @{ }
    Write-Debug "Loading CRC from $filePath..."
    $params = @('l', '-slt', $filePath)
    & $zipExe $params | ForEach-Object {
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
    $errorCount = 0
    Write-Debug "Checking CRC from $sourcePath..."
    $params = @('h', $sourcePath)
    & $zipExe $params | Select-Object -Skip 8 | ForEach-Object {
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
    }

    if ($errorCount -gt 0) {
        Write-Warning "$errorCount error(s) detected. Please check issues before continuing."
    }
    else {
        $elapsedTime = $(Get-Date) - $startTime
        $totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
        Write-Output "$filePath test complete successfully. ($totalTime elapsed)"
    }
}

#####################################################################
function ArchiveCheckSimple {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $filePath
    )

    $startTime = Get-Date
    Write-Debug "Testing archive $filePath..."
    $params = @('t', $filePath)
    & $zipExe $params
    if (-not $?) {
        throw "Error testing archive - $filePath" 
    }   
    $elapsedTime = $(Get-Date) - $startTime
    $totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
    Write-Output "$filePath test complete successfully. ($totalTime elapsed)"
}

#####################################################################
function CompressPathToFile {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $sourcePath,

        [Parameter(Mandatory = $true)]
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

    # zip the source
    $startTime = Get-Date
    $params = @('u', $archivePath, $sourcePath)
    Write-Debug "Archiving $sourcePath to $archivePath..."
    & $zipExe $params
    if (-not $?) {
        Write-Error "Error creating archive, executing: $zipExe $($params -join ' ')"
        throw
    }
    $elapsedTime = $(Get-Date) - $startTime
    $totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
    Write-Output "$archivePath created. ($totalTime elapsed)"

    # check archive
    if ($ArchiveCheck -eq 'Simple') {
        ArchiveCheckSimple -filePath $archivePath
    }
    elseif ($ArchiveCheck -eq 'Full') {
        ArchiveCheckFull -filePath $archivePath -sourcePath $sourcePath
    }
}

#####################################################################
function CopyFileToContainer {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $filePath,

        [Parameter(Mandatory = $true)]
        [string] $containerURI
    )
    

    # upload file
    $uri = [uri] $ContainerURI
    $path = [System.IO.FileInfo] $filePath
    $destinationURI = 'https://' + $uri.Host + "$($uri.LocalPath)/$($path.Name)" + $uri.Query 
    
    Write-Output "Upload $($path.Name) started to $destinationURI ..."
    # using & command syntax since Invoke-Expression doesn't throw an error
    $params = @('copy', $filePath, $destinationURI)
    & $azCopyExe $params
    if (-not $?) {
        Write-Error "Error uploading file, executing: $azcopyExe $($params -join ' ')"
        throw
    }
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
    throw "Unable to find 7z.exe command. Please make sure 7z.exe is in your PATH or use -ZipCommandPath to specify 7z.exe path"
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
    Write-Error "Unable to find azcopy.exe command. Please make sure azcopy.exe is in your PATH or use -AzCopyCommandPath to specify azcopy.exe path" -ErrorAction Stop
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

if ($PSCmdlet.ParameterSetName -eq 'StorageAccount') {
    # login to powershell az commands
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

    $ContainerURI = $storageAccount.PrimaryEndpoints.Blob + $ContainerName
}

# check -ArchiveTempFilePath
if ($ArchiveTempDir -and -not $ArchiveTempDir.EndsWith('\')) {
    $ArchiveTempDir += '\'
}
if (-not $(Test-Path -Path $ArchiveTempDir)) {
    throw "Unable to find $ArchiveTempDir. Please check the -ArchiveTempDir and try again."
} 

# check source filepath
if (-not $(Test-Path -Path $SourceFilePath)) {
    Write-Error "Unable to find $SourceFilePath. Please check the -SourcePath and try again." -ErrorAction Stop
} 

# invalid combination -SeparateEachDirectory will force the use of directory name
if ($ArchiveFileName -and $SeparateEachDirectory) {
    throw "-ArchiveFilename and -SeparateEachDirectory can not be used together."
}

if ($SeparateEachDirectory) {
    # loop through each directory and upload a separate zip
    $sourcePaths = $(Get-ChildItem $SourceFilePath | Where-Object { $_.PSIsContainer }).FullName

} else {
    $sourcePaths = $SourceFilePath
}

foreach ($sourcePath in $sourcePaths) {
    $archivePath = $ArchiveTempDir + $(Split-Path $sourcePath -Leaf) + '.7z'

    if ($AppendDateToFileName) {
        $path = [System.IO.FileInfo] $archivePath
        $yyyymmdd = "{0:yyyyMMdd}" -f $(Get-Date)
        $archivePath = $path.DirectoryName + '\' + $path.BaseName + '_' + $yyyymmdd + $path.Extension
    }

    CompressPathToFile -SourcePath $sourcePath -archivePath $archivePath
    CopyFileToContainer -filePath $archivePath -ContainerURI $ContainerURI

    if ($PSCmdlet.ParameterSetName -eq 'StorageAccount') { 
        # verify the file & blob size created
        $archiveFile = Get-ChildItem $archivePath
        $blob = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Blob $archiveFile.Name
        if ($archiveFile.Length -ne $blob.Length) {
            throw "$($archiveFile.Name) size ($($archiveFile.Length)) does not match $($blob.Name) Blob size ($($blob.Length))"
            return $false
        }

        if ($BlobTier) {
            $blob.ICloudBlob.SetStandardBlobTier($BlobTier)
            Write-Output "$containerURI/$($blob.Name) tier set to $BlobTier"
        }
    }

    # clean up
    Remove-Item -Path $archivePath -Force

    Write-Output ''
    Write-Output "==================== $(Split-Path $archivePath -Leaf) complete. $(Get-Date) ===================="
    Write-Output ''
}

Write-Output "Script Complete. $(Get-Date)"
