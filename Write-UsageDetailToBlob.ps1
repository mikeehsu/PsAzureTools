<#
.SYNOPSIS
Write-UsageDetailToBlob.ps1 - Writes Usage Detail CSV data to a Blob Storage

.DESCRIPTION
This script retrieves Usage Detail CSV data from the Azure billing API and writes it to a specified Blob Storage container.

.PARAMETER StartDate
Start date of the Usage Detail CSV data to retrieve. Format: YYYY-MM-DD. Defaults to 5 days prior.

.PARAMETER EndDate
End date of the Usage Detail CSV data to retrieve. Format: YYYY-MM-DD. Defaults to 1 day prior.

.PARAMETER ResourceGroupName
Name of the Resource Group to write the CSV data to.

.PARAMETER StorageAccountName
Name of the Storage Account to write the CSV data to.

.PARAMETER ContainerName
Name of the Container to write the CSV data to.

.EXAMPLE
.\Write-UsageDetailToBlob.ps1 -StartDate '2020-01-01' -EndDate '2020-01-31' -ResourceGroupName 'myResourceGroup' -StorageAccountName 'myStorageAccount' -ContainerName 'billing'

#>
[CmdletBinding()]
param (
    [Parameter()]
    [datetime] $StartDate,

    [Parameter()]
    [datetime] $EndDate,

    [Parameter()]
    [string] $ResourceGroupName,

    [Parameter()]
    [string] $StorageAccountName,

    [Parameter()]
    [string] $ContainerName
)

Set-StrictMode -Version 2

# get default dates, if not provided
if (-not $StartDate) {
    $StartDate = (Get-Date).AddDays(-5)

}

if (-not $EndDate) {
    $EndDate = (Get-Date).AddDays(-1)
}

# read defaults from environment variables, if not provided
if (-not $ResourceGroupName) {
    $ResourceGroupName = $env:ResourceGroupName
}

if (-not $StorageAccountName) {
    $StorageAccountName = $env:StorageAccountName
}

if (-not $ContainerName) {
    $ContainerName = $env:ContainerName
}

if (-not $ResourceGroupName -or -not $StorageAccountName -or -not $ContainerName) {
    Write-Error "ResourceGroupName, StorageAccountName and ContainerName must be specified."
    return
}

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
        return
    }
}
catch {
    Write-Error "Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding."
    return
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
if (-not $storageAccount) {
    Write-Error "StorageAccount ($StorageAccountName) not found."
    return
}

$fileCount = 0
$workDate = Get-Date -Date $StartDate.ToString('yyyy-MM-dd')

while ($workDate -le $EndDate) {

    try {
        $filename = "UsageDetails-$($workDate.ToString('yyyy-MM-dd')).csv"
        $path = Join-Path -Path "$([System.IO.Path]::GetTempPath())" -ChildPath $filename

        Write-Progress -Activity "Usage Details" -Status "Generating $filename"
        $workEndTime = $workDate.AddHours(23).AddMinutes(59).AddSeconds(59)

        Get-AzConsumptionUsageDetail -StartDate $workDate -EndDate $workEndTime -Expand 'MeterDetails' -ErrorAction Stop
            | Select-Object *,@{Name='Tags'; Expression={$_.Tags ? (ConvertTo-Json $_.Tags) : ''}} -ExpandProperty MeterDetails -ExcludeProperty MeterDetails, Tags
            | Export-Csv -Path $path

        # upload to storage container
        Write-Progress -Activity "Usage Details" -Status "Uploading blob $filename"
        $results = Set-AzStorageBlobContent -File $path -Container $ContainerName -Blob $filename -Context $storageAccount.Context -Force
        Write-Host "$filename uploaded to $StorageAccountName/$ContainerName"

        $fileCount++
    } catch {
        Write-Error "Unable to creating & upload $filename to $StorageAccountName/$ContainerName"
        throw $_.Exception
    }

    # clean up
    Remove-Item -Path $path

    $workDate = $workDate.AddDays(1)
}

Write-Host "$fileCount files uploaded"