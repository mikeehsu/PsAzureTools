[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter()]
    $Password = 'P@$$word1234',

    [Parameter()]
    [int] $CompressionLevel = 1,

    [Parameter()]
    [string] $SplitZipSize = '100M',

    [Parameter()]
    [int] $PartialZipUploadInterval = 60,

    [Parameter()]
    [string] $CompressTempDir = 'C:\temp\ziptest',

    [Parameter()]
    $ResourceGroupName = 'ice-dojtransfer',

    [Parameter()]
    $StorageAccountName = 'icedojtransfer',

    [Parameter()]
    $EmailTo = 'mihs@microsoft.com',

    [Parameter()]
    $ZipCommandDir = 'C:\Utils\7-Zip',

    [Parameter()]
    $AzCopyCommandDir = 'C:\Utils'
)

#####################################################################
function Remove-StringSpecialCharacter {
    <#
.SYNOPSIS
    This function will remove the special character from a string.

.DESCRIPTION
    This function will remove the special character from a string.
    I'm using Unicode Regular Expressions with the following categories
    \p{L} : any kind of letter from any language.
    \p{Nd} : a digit zero through nine in any script except ideographic

    http://www.regular-expressions.info/unicode.html
    http://unicode.org/reports/tr18/

.PARAMETER String
    Specifies the String on which the special character will be removed

.PARAMETER SpecialCharacterToKeep
    Specifies the special character to keep in the output

.EXAMPLE
    Remove-StringSpecialCharacter -String "^&*@wow*(&(*&@"
    wow

.EXAMPLE
    Remove-StringSpecialCharacter -String "wow#@!`~)(\|?/}{-_=+*"

    wow
.EXAMPLE
    Remove-StringSpecialCharacter -String "wow#@!`~)(\|?/}{-_=+*" -SpecialCharacterToKeep "*","_","-"
    wow-_*

.NOTES
    Francois-Xavier Cat
    @lazywinadmin
    lazywinadmin.com
    github.com/lazywinadmin
#>
    [CmdletBinding()]
    param
    (
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [Alias('Text')]
        [System.String[]]$String,

        [Alias("Keep")]
        #[ValidateNotNullOrEmpty()]
        [String[]]$SpecialCharacterToKeep
    )
    PROCESS {
        try {
            IF ($PSBoundParameters["SpecialCharacterToKeep"]) {
                $Regex = "[^\p{L}\p{Nd}"
                Foreach ($Character in $SpecialCharacterToKeep) {
                    IF ($Character -eq "-") {
                        $Regex += "-"
                    }
                    else {
                        $Regex += [Regex]::Escape($Character)
                    }
                    #$Regex += "/$character"
                }

                $Regex += "]+"
            } #IF($PSBoundParameters["SpecialCharacterToKeep"])
            ELSE { $Regex = "[^\p{L}\p{Nd}]+" }

            FOREACH ($Str in $string) {
                Write-Verbose -Message "Original String: $Str"
                $Str -replace $regex, ""
            }
        }
        catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    } #PROCESS
}

#####################################################################
# MAIN
if ($AzCopyCommandDir -and -not $AzCopyCommandDir.EndsWith('\')) {
    $AzCopyCommandDir += '\'
}
$azcopyExe = $AzCopyCommandDir + 'azcopy.exe'

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -AccountName $StorageAccountName
if (-not $storageAccount) {
    throw "Error getting StorageAccount info $StorageAccountName"
}
$storageContext = $storageAccount.context

$containerName = Remove-StringSpecialCharacter (Split-Path -Path $Path -LeafBase).ToLower() -SpecialCharacterToKeep '-'
$container = Get-AzStorageContainer -Context $storageContext -Name $containerName -ErrorAction SilentlyContinue
if (-not $container) {
    $container = New-AzStorageContainer -Context $storageContext -Name $containerName -ErrorAction Stop
    if (-not $container) {
        throw "Unable to create container $containerName"
    }
}
$sasToken = New-AzStorageContainerSASToken -Context $storageContext -Name $containerName -Permission rwdl -ExpiryTime (Get-Date).AddYears(1)
$sasUri = $container.CloudBlobContainer.Uri.Tostring() + $sasToken

Write-Host "SAS Token: $sasUri"
$queue = Get-AzStorageQueue -Context $storageContext -Name 'notification'
if (-not $queue) {
    $queue = New-AzStorageQueue -Context $storageContext -Name 'notification'
}

$archiveName = Split-path $Path -Leaf
$subject = "$archiveName - upload started"
$body = "Use the following key to download:<br/><br/>$sasUri"
$message = [PSCustomObject]@{
    EmailTo = $EmailTo
    Subject = $subject
    Body    = $body
}
$json = $message | ConvertTo-Json

$queueMessage = [Microsoft.Azure.Storage.Queue.CloudQueueMessage]::new($json)
$message = $queue.CloudQueue.AddMessageAsync($QueueMessage)
if (-not $message) {
    Write-Error "Unable to queue email to $EmailTo - Please emaild SAS Token manually. "
}

C:\PSAzureTools\CompressFilesToBlob.ps1 -SourceFilePath $Path -PartialZipUploadInterval $PartialZipUploadInterval `
    -StorageAccountName $StorageAccountName -ContainerName $containerName -CompressTempDir $CompressTempDir `
    -SplitZipSize $SplitZipSize -Password $Password -CompressionLevel $CompressionLevel -KeepLocalCompressFiles -IntegrityCheck 'None' `
    -ZipCommandDir $ZipCommandDir -AzCopyCommandDir $AzCopyCommandDir `

# create archive log
$manifestFiles = (Get-ChildItem "$CompressTempDir\$(Split-Path $Path -LeafBase)").Name

$logFile = "$env:TEMP\manifest.log"
"#$Path" | Out-File $logFile
"#$(Get-Date -Format u) Upload Complete" | Out-File $logFile -Append
$manifestFiles | Out-File $logFile -Append
$params = @('copy', $logFile , $sasUri)
try {
    $result = & $azCopyExe $params
}
catch {
    Write-Error "ERROR writing activity log to $sasUri"
}

# send email
$subject = "$archiveName - upload complete"
$body = "$archiveName upload complete at $(Get-Date -Format u)<br><br>"
$body += "Use the following key to download:<br/>$sasUri<br/><br/>"
$manifestFiles | Foreach-object {
    $body += $_ + '<br/>'
}
$message = [PSCustomObject]@{
    EmailTo = $EmailTo
    Subject = $subject
    Body    = $body
}
$json = $message | ConvertTo-Json
$queueMessage = [Microsoft.Azure.Storage.Queue.CloudQueueMessage]::new($json)
$message = $queue.CloudQueue.AddMessageAsync($QueueMessage)
if (-not $message) {
    Write-Error "Unable to queue email to $EmailTo - Please emaild SAS Token manually. "
}
