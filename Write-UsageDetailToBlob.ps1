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

.PARAMETER $Subscription
Name of a single or list of SubscriptionName, SubscriptionId to run the cost export for.

.PARAMETER $AllSubscriptions
Use this parameter to process all subscription in context. If neither, subscription or -AllSubscriptions only the current subscription will be exported

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
    [string] $ContainerName,

    [Parameter()]
    [string[]] $Subscription,

    [Parameter()]
    [switch] $AllSubscriptions
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
    Write-Error 'ResourceGroupName, StorageAccountName and ContainerName must be specified.'
    return
}

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
        return
    }
}
catch {
    Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Set-AzContext) context before proceeding.'
    return
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
if (-not $storageAccount) {
    Write-Error "StorageAccount ($StorageAccountName) not found."
    return
}

# validate subscriptions
if ($AllSubscriptions -and $Subscription) {
    Write-Error '-AllSubscriptions and -Subscription can not be used together'
    return
}

$savedContext = Get-AzContext
$validSubscriptions = Get-AzSubscription

if ($AllSubscriptions) {
    $subscriptions = $validSubscriptions

} elseif (-not $Subscription) {
    $subscriptions = $validSubscriptions | Where-Object {$_.SubscriptionId -eq $savedContext.Subscription}

} else {
    $subscriptions = @()
    foreach ($testSubscription in $Subscription) {
        if ([System.Guid]::TryParse($testSubscription, [System.Management.Automation.PSReference] [System.Guid]::empty)) {
            $found = $validSubscriptions | Where-Object {$_.Id -eq $testSubscription}
        } else {
            $found = $validSubscriptions | Where-Object {$_.Name -eq $testSubscription}
        }

        if (-not $found) {
            Write-Error "Unable to find subscription ($testSubscription)"
            return
        }
        $subscriptions += $found
    }
}

# work through each day at a time
$fileCount = 0
$workDate = Get-Date -Date $StartDate.ToString('yyyy-MM-dd')

while ($workDate -le $EndDate) {
    try {
        $filename = "UsageDetails-$($workDate.ToString('yyyy-MM-dd')).csv"
        $path = Join-Path -Path "$([System.IO.Path]::GetTempPath())" -ChildPath $filename
        $addingToFile = $false

        foreach ($currentSubscription in $subscriptions) {
            $results = $currentSubscription | Set-AzContext

            Write-Progress -Activity "Working on $filename" -Status "Getting usage for $($currentSubscription.Name)"
            $workEndTime = $workDate.AddHours(23).AddMinutes(59).AddSeconds(59)

            $usage = Get-AzConsumptionUsageDetail -StartDate $workDate -EndDate $workEndTime -IncludeMeterDetails -Expand 'AdditionalProperties' -ErrorAction Stop `
            | Select-Object -ExpandProperty MeterDetails -ExcludeProperty Name,MeterDetails, Tags `
            -Property *, `
            @{Name='Tags'; Expression = { $_.Tags ? (ConvertTo-Json $_.Tags -Compress) : '' } }, `
            @{Name='ResourceGroupName'; Expression = { $_.InstanceId.Split('/')[4] } }
            | ConvertTo-Csv -NoTypeInformation -NoHeader:$addingToFile
            | Out-File -FilePath $path -Append:$addingToFile

            $addingToFile = $true
        }
        # upload to storage container
        Write-Progress -Activity "Working on $filename" -Status "Uploading blob to $StorageAccountName/$ContainerName"
        $results = Set-AzStorageBlobContent -File $path -Container $ContainerName -Blob $filename -Context $storageAccount.Context -Force
        Write-Host "$filename uploaded to $StorageAccountName/$ContainerName"

        $fileCount++
    }
    catch {
        Write-Error "Unable to get data for $($currentSubscription.Name)"
        throw $_

    } finally {
        $result = $savedContext | Set-AzContext
    }

    # clean up
    Remove-Item -Path $path

    $workDate = $workDate.AddDays(1)
}

$result = $savedContext | Set-AzContext
Write-Host "$fileCount files uploaded"