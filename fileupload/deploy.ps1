<#
.SYNOPSIS
Configure new or existing storage account for file upload.

.PARAMETER ResourceGroupName
Specifies the Resource Group for the storage account.

.PARAMETER StorageAccountName
Specifies the name of the storage account.

.PARAMETER Location
Location for the storage account (if creating a new one).

.EXAMPLE
deploy.ps1 -ResourceGroupName MyResourceGroup -StorageAccountName MyStorageAccount -Location "Central US"

.NOTES
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $StorageAccountName,

    [Parameter()]
    [string] $Location
)

# check session to make sure if it connected
try {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Environment) {
        throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
    }

}
catch {
    throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
    return
}

# create storage account (if needed)
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
if (-not $storageAccount) {
    if (-not $Location) {
        Write-Error "Storage Account ($storageAccountName) not found. Please provide an existing storage account or provide -Location."
        return
    }

    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        $resourceGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop
    }

    $storageAccount = New-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -Location $Location -AccountType Standard_LRS -ErrorAction Stop
    Write-Host "$StorageAccountName created in $Location"
}

# configure storage account for uploads
Write-Verbose "Configuring $StorageAccountName for Static Website"
try {
    $result = Enable-AzStorageStaticWebsite -Context $storageAccount.Context -IndexDocument "index.html"

    $corsRules = Get-AzStorageCORSRule -Context $storageAccount.Context -ServiceType Blob
    if ($corsRules) {
        $corsRules[0].AllowedOrigins = @("*")
        $corsRules[0].AllowedMethods = @("POST", "PUT")
        $corsRules[0].AllowedHeaders = @("*")
        $corsRules[0].ExposedHeaders = @("*")
    } else {
        $CorsRules = (@{
            AllowedOrigins=@("*");
            AllowedMethods=@("POST","PUT")
            AllowedHeaders=@("*")
            ExposedHeaders=@("*")
        })
    }
    $result = Set-AzStorageCORSRule -Context $storageAccount.Context -ServiceType Blob -CorsRules $corsRules

    # download then upload index.html file -- can't copy directly from github as there is no way to set the content type
    $tmpFile = New-TemporaryFile
    $result = Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mikeehsu/PsAzureTools/master/fileupload/index.html" -OutFile $tmpFile
    $blobProperties = @{"ContentType" = "text/html"};
    $result = Set-AzStorageBlobContent -Context $storageAccount.Context -File $tmpFile -Container '$web' -Blob "index.html" -Properties $blobProperties -Force

    # copy javascript
    $result = Start-AzStorageBlobCopy -AbsoluteUri "https://raw.githubusercontent.com/mikeehsu/PsAzureTools/master/fileupload/main.js" -DestContainer '$web' -DestBlob "main.js" -DestContext $storageAccount.Context -Force

    $docsContainer = Get-AzStorageContainer -Context $storageAccount.Context -Name 'documents' -ErrorAction SilentlyContinue
    if (-not $docsContainer) {
        $docsContainer = New-AzStorageContainer -Context $storageAccount.Context -Name 'documents'
    }

    $sasToken = $docsContainer | New-AzStorageContainerSASToken -Permission cw -ExpiryTime (Get-Date).AddYears(1)
    if (-not $sasToken.StartsWith('?')) {
        # necessary for breaking change introduced with Az.Storage v6.0+
        $sasToken = "?" + $sasToken
    }

    Write-Host "$StorageAccountName configuration complete. To upload, use this URL: $($storageAccount.PrimaryEndpoints.Web)$sasToken"

} catch {
    Write-Error "Error configuring $StorageAccountName for uploading files"
    throw
}
