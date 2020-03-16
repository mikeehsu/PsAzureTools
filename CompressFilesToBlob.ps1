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
Name of the storage account to upload the archive file to

.PARAMETER ContainerName
Name of the container to upload the archive file to

.PARAMETER ContainerURI
URI of container. When using ContainerURI, this should contain any SAS token necessary to upload the archive

.PARAMETER ArchiveFileName
Name of archive flie. This will default to the filename or directory name with a .7z extension when compressing the file(s).

.PARAMETER ArchiveTempDir
Directory to use for the .7z archive compression. If no directory is specific, the archive will be placed in the TEMP directory specified by the current environment variable.

.PARAMETER ArchiveCheck
Perform a validation check on the created archive file. If no value is specified, validation check will default to 'Simple'

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
    [Parameter(Mandatory=$true)]
    [string] $SourceFilePath,
    
    [Parameter(ParameterSetName="StorageAccount", Mandatory=$true)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName="StorageAccount", Mandatory=$true)]
    [string] $ContainerName,

    [Parameter(ParameterSetName="ContainerURI", Mandatory=$true)]
    [string] $ContainerURI,

    [Parameter(Mandatory=$false)]
    [string] $ArchiveFileName,

    [Parameter(Mandatory=$false)]
    [string] $ArchiveTempDir = $env:TEMP,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Simple','Full','None')]
    [string] $ArchiveCheck = "Simple",

    [Parameter(Mandatory=$false)]
    [string] $ZipCommandDir = "",

    [Parameter(Mandatory=$false)]
    [string] $AzCopyCommandDir = "",

    [Parameter(ParameterSetName="ManagedIdentity", Mandatory=$false)]
    [switch] $UseManagedIdentity,

    [Parameter(ParameterSetName="ManagedIdentity", Mandatory=$false)]
    [string] $Environment
)

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
} catch {
    Write-Error "Unable to find azcopy.exe command. Please make sure azcopy.exe is in your PATH or use -AzCopyCommandPath to specify azcopy.exe path" -ErrorAction Stop
}

# login if using managed identities
if ($UseManagedIdentity) {
    try {
        $params = @{}
        if ($Environment) {
            $params = @{'Environment' = $Environment}
        }
        Connect-AzAccount -Identity @params
    } catch {
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
$sourceFilename = Split-Path -Path $SourceFilePath -Leaf

# check for existing zip file
if ($ArchiveFileName) {
    $ArchiveFilePath = $ArchiveTempDir + $ArchiveFileName + '.7z'
} else {
    $ArchiveFilePath = $ArchiveTempDir + $sourceFilename + '.7z'
}

$updateZipFile = $true
if (Test-Path -Path $ArchiveFilePath) {
    $answer = Read-Host "$ArchiveFilePath already exists. (Replace/Update/Skip/Cancel)?"
    if ($answer -like 'C*') {
        return

    } elseif ($answer -like 'S*') {
        $updateZipFile = $false

    } elseif ($answer -like 'R*') {
        Remove-Item -Path $ArchiveFilePath -Force
    }

} 

# zip the source
if ($updateZipFile) {
    $startTime = Get-Date
    $params = @('u',$ArchiveFilePath, $SourceFilePath)
    Write-Verbose "Archiving $SourceFilePath to $ArchiveFilePath..."
    & $($zipExe) $params
    if (-not $?) {
        Write-Error "Error creating archive, executing: $zipExe $($params -join ' ')"
        throw
    }
    $elapsedTime = $(Get-Date) - $startTime
    $totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
    Write-Output "$ArchiveFilePath created. ($totalTime elapsed)"
}

# check archive
if ($ArchiveCheck -eq 'Simple') {
    $startTime = Get-Date
    Write-Verbose "Testing archive $ArchiveFilePath..."
    $params = @('t', $ArchiveFilePath)
    & $zipExe $params
    if (-not $?) {
        throw "Error testing archive - $ArchiveFilePath" 
    }   
    $elapsedTime = $(Get-Date) - $startTime
    $totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
    Write-Output "$ArchiveFilePath test complete successfully. ($totalTime elapsed)"
    
} elseif ($ArchiveCheck -eq 'Full') {
    # load CRC list from zip file
    $startTime = Get-Date
    $command = "$zipExe l -slt $ArchiveFilePath"
    $currentPath = $null
    $zipCRC = @{}
    Write-Verbose "Loading CRC from $ArchiveFilePath..."
    Invoke-Expression -Command $command | ForEach-Object {
        if ($_.StartsWith('Path')) {
            $currentPath = $_.Substring($_.IndexOf('=')+2)
        } elseif ($_.StartsWith('CRC')) {
            $zipCRC[$currentPath] = $_.Substring($_.IndexOf('=')+2)
        }
    }

    # get CRC from source filepath and compare against list from zip file
    # sample CRC: 852DD72D      57490143  temp\20191230_hibt_chicken.mp3_bf969ccfdacaede5b20f6473ef9da0c8_57490143.mp3
    $command = "$zipExe  h $SourceFilePath"
    $endReached = $false
    $errorCount = 0
    Write-Verbose "Checking CRC from $SourceFilePath..."
    Invoke-Expression -Command $command | Select-Object -Skip 8 | ForEach-Object {
        if (-not $endReached) {
            $crc = $_.Substring(0,8)
            $path = $_.Substring(24)
        } 

        if ($endReached) {
            # do nothing
        } elseif ($crc -eq '--------') {
            $endReached = $true
        } elseif ($zipCRC[$path] -eq $crc) {
            # CRC matches
            # do nothing
        } elseif ($crc -eq '        ') {
            # folder entry
            # supress error
        } elseif (-not $zipCRC[$path]) {
            Write-Warning "NOT FOUND -- $path"
            $errorCount++
        } else {
            Write-Warning "CRC MISMATCH -- ARCHIVE CRC: $crc - SOURCE: $($zipCRC[$path]) - $path"
            $errorCount++
        }
    }

    if ($errorCount -gt 0) {
        Write-Warning "$errorCount error(s) detected. Please check issues before continuing."
    } else {
        $elapsedTime = $(Get-Date) - $startTime
        $totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
        Write-Output "$ArchiveFilePath test complete successfully. ($totalTime elapsed)"
    }
}

# upload file
$uri = [uri] $ContainerURI
if ($uri.Query) {
    $destinationURI = 'https://' + $uri.Host + "$($uri.LocalPath)/$($ArchiveFileName)" + $uri.Query 
} else {
    $destinationURI = $ContainerURI
}

Write-Output "Upload started to $destinationURI ..."
# using & command syntax since Invoke-Expression doesn't throw an error
$params = @('copy', $ArchiveFilePath, $destinationURI)
& $azCopyExe $params
if (-not $?) {
    Write-Error "Error uploading file, executing: $azcopyExe $($params -join ' ')"
    throw
}

Write-Output 'Upload complete.'
