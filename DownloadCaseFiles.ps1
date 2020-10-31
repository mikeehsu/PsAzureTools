[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $SasUri,

    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter()]
    [string] $CompressTempDir,

    [Parameter()]
    [int] $containerCheckInterval = 60,

    [Parameter()]
    [switch] $KeepArchiveFile,

    [Parameter()]
    $Password = 'P@$$word1234',

    [Parameter()]
    $ZipCommandDir = 'C:\Utils\7-Zip',

    [Parameter()]
    $AzCopyCommandDir = 'C:\Utils'


)

#####################################################################
function WriteTransferLog
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $Message
    )

    $uri = [uri] $script:SasUri

    $transferUri = "https://$($uri.Host)$($uri.LocalPath)/$($script:transferLogFileName)$($uri.Query)"
    $localTransferLogPath = "$CompressTempDir\$transferLogFileName"

    $params = @('copy', $transferUri, $localTransferLogPath)
    $null = & $azcopyExe $params
    if (-not $?) {
        Write-Verbose "Unable to download $transferLogFileName"
    }

    "$(Get-Date -Format u) $Message<br/>" | Out-File -Path $localTransferLogPath -Append

    $params = @('copy', $localTransferLogPath, $transferUri)
    $null = & $azcopyExe $params
    if (-not $?) {
        Write-Warning "Unable to save updates to $transferLogFileName"
    }
}

#####################################################################

$manifestFileName = 'manifest.log'
$transferLogFileName = 'transfer.log'

if (-not $CompressTempDir) {
    $CompressTempDir = $Path
}

if ($ZipCommandDir -and -not $ZipCommandDir.EndsWith('\')) {
    $ZipCommandDir += '\'
}
$zipExe = $ZipCommandDir + '7z.exe'
$null = $(& $zipExe)
if (-not $?) {
    throw "Unable to find 7z.exe command. Please make sure 7z.exe is in your PATH or use -ZipCommandDir to specify 7z.exe path"
}

# create archive log
if ($AzCopyCommandDir -and -not $AzCopyCommandDir.EndsWith('\')) {
    $AzCopyCommandDir += '\'
}
$azcopyExe = $AzCopyCommandDir + 'azcopy.exe'

$manifestPath = "$CompressTempDir\$manifestFileName"

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# download zip files
# for azcopy command
WriteTransferLog -Message "Download started"

$params = @('sync', $sasUri, $CompressTempDir)

$moreFilesToTransfer = $true
$lastSync = $null
$manifest = $null

Write-Host "========== $(Get-Date -Format u) - DOWNLOAD STARTED. Saving files to $CompressTempDir =========="
while ($moreFilesToTransfer) {
    # check for a manifest file
    if (-not $manifest -and (Test-Path $manifestPath)) {
        $manifest = Get-Content $manifestPath | Where-Object { $_ -notlike '#*' }
    }

    # if manifest loaded
    if ($manifest) {
        $fileNames = (Get-ChildItem $CompressTempDir -File).Name
        $missingFiles = Compare-Object -ReferenceObject $maniFest -DifferenceObject $fileNames | Where-Object { $_.SideIndicator -eq '<=' }
        if (-not $missingFiles) {
            Write-Host "$($manifest.Count) files in manifest, all accounted for"
            $moreFilesToTransfer = $false
            break
        }
    }

    # sync directory & container
    if ($null -ne $lastSync) {
        $nextSync = $lastSync.AddSeconds($containerCheckInterval)
        $sleepSeconds = ($nextSync - (Get-Date)).Seconds
        if ($sleepSeconds -gt 0) {
            $text = ''
            if ($missingFiles) {
                $text = "($($missingFiles[0].InputObject))"
            }
            Write-Host "$(Get-Date -Format u) Waiting for more files $text...check again in $sleepSeconds secs. ($($stopwatch.Elapsed))"
            Start-Sleep -Seconds $sleepSeconds
        }
    }

    $lastSync = Get-Date
    & $azcopyExe $params
    if (-not $?) {
        throw
    }
}

Write-Host "==========  $(Get-Date -Format u) - DOWNLOAD COMPLETE. $($manifest.Count) files downloaded. ($($stopwatch.Elapsed)) =========="
WriteTransferLog -Message "Download complete"

Write-Host "==========  $(Get-Date -Format u) - UNZIP STARTED. saving files to $Path  =========="
$zipFileName = $CompressTempDir + '\' + ($manifest | Where-Object { $_ -like '*.001' })
$params = @('x', $zipFileName, "-o$Path", '-aoa')
if ($Password) {
    $params += "-p$Password"
}
& $zipExe $params
if (-not $?) {
    Write-Error "ERROR: unable to uncompress file $params"
    throw
}

Write-Host "==========  $(Get-Date -Format u) - UNZIP COMPLETE. $Path ($($stopwatch.Elapsed)) =========="
WriteTransferLog -Message "Unzip complete"

if (-not $KeepArchiveFile) {
    $manifest | Foreach-Object { Remove-Item "$CompressTempDir\$_" -Force }
    Remove-Item "$CompressTempDir\$manifestFileName" -Force
    Remove-Item "$CompressTempDir\$transferLogFileName" -Force
}
