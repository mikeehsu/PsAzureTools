[CmdletBinding()]
param (
    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $ContainerName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory = $true)]
    [string] $ArchiveFilePath,

    [Parameter(ParameterSetName = "ArchiveURI", Mandatory = $true)]
    [string] $ArchiveURI,

    [Parameter(Mandatory = $false)]
    [string] $ArchiveTempDir = $env:TEMP,

    [Parameter(Mandatory = $true)]
    [string] $DestinationPath,
        
    [Parameter(Mandatory = $false)]
    [switch] $WaitForRehydration,

    [Parameter(Mandatory = $false)]
    [switch] $UseManagedIdentity,

    [Parameter(Mandatory = $false)]
    [string] $ZipCommandPath = "",

    [Parameter(Mandatory = $false)]
    [string] $AzCopyCommandPath = ""

)

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

    $blob = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Blob $ArchiveFilePath
    if (-not $blob) {
        throw "Unable to find $ArchiveFilePath in $ContainerName"
    }

    # rehydrate blob if necessary
    if ($blob.ICloudBlob.Properties.StandardBlobTier -eq 'Archive') {
        if (-not $blob.ICloudBlob.Properties.RehydrationStatus) {
            $blob.ICloudBlob.SetStandardBlobTier("Hot", “Standard”)
            Write-Output "Rehydrate requested for: $($blob.Name)"
        }

        if (-not $WaitForRehydration) {
            Write-Output "File is rehydrating - current status: $($blob.ICloudBlob.Properties.RehydrationStatus)"
            Write-Output "Please check again later."
            return
        }

        do {
            Start-Sleep 600 # 10 mins
            $blob = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Blob $ArchiveFilePath
            Write-Output "$(Get-Date) - $($blob.Name) - $($blob.ICloudBlob.Properties.StandardBlobTier) - $($blob.ICloudBlob.Properties.RehydrationStatus)"
        } until ($blob.ICloudBlob.Properties.StandardBlobTier -ne 'Archive' -or $blob.ICloudBlob.Properties.RehydrationStatus -ne 'PendingToHot')
    }

    $ArchiveURI = $blob.ICloudBlob.Uri.Absoluteuri
}

# check -ArchiveTempFilePath
if ($ArchiveTempDir -and -not $ArchiveTempDir.EndsWith('\')) {
    $ArchiveTempDir += '\'
}
if (-not $(Test-Path -Path $ArchiveTempDir)) {
    throw "Unable to find $ArchiveTempDir. Please check the -ArchiveTempDir and try again."
} 

# check source filepath
if (-not $(Test-Path -Path $DestinationPath)) {
    throw "Unable to find $DestinationPath. Please check the -DestinationPath and try again."
} 

& $azcopyExe copy $ArchiveURI $ArchiveTempDir
if (-not $?) {
    throw "Error retrieving archive - $filePath" 
}

$uri = [uri] $archiveuri
$fileName = $uri.Segments[$uri.Segments.Count - 1]

& $zipExe x "$($ArchiveTempDir + $fileName)" -"o$DestinationPath -ao" 
if (-not $?) {
    throw "Error restoring archive - $filePath" 
}

Write-Output "==================== Restore of $filename to $DestinationPath complete ===================="
