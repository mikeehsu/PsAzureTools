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
    [string] $StorageSubscription,

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
if (-not $StorageSubscription) {
    $StorageSubscription = $env:StorageSubscription
}

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

# save current context (used to restore on exit)
$savedContext = Get-AzContext

# validate subscriptions
if ($AllSubscriptions -and $Subscription) {
    Write-Error '-AllSubscriptions and -Subscription can not be used together'
    return
}

$validSubscriptions = Get-AzSubscription
if ($AllSubscriptions) {
    $subscriptions = $validSubscriptions

}
elseif (-not $Subscription) {
    $subscriptions = $validSubscriptions | Where-Object { $_.SubscriptionId -eq $savedContext.Subscription }

}
else {
    $subscriptions = @()
    foreach ($testSubscription in $Subscription) {
        if ([System.Guid]::TryParse($testSubscription, [System.Management.Automation.PSReference] [System.Guid]::empty)) {
            $found = $validSubscriptions | Where-Object { $_.Id -eq $testSubscription }
        }
        else {
            $found = $validSubscriptions | Where-Object { $_.Name -eq $testSubscription }
        }

        if (-not $found) {
            Write-Error "Unable to find subscription ($testSubscription)"
            return
        }
        $subscriptions += $found
    }
}
$subscriptions = $subscriptions | Sort-Object -Property Name


# verify storage account
if ($StorageSubscription) {
    Set-AzContext $StorageSubscription
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
if (-not $storageAccount) {
    Write-Error "StorageAccount ($StorageAccountName) not found."
    return
}

# get list of blobs created today
$prefix = "UsageDetails-"
$suffix = ".csv"

$container = $storageAccount | Get-AzStorageContainer -Name $ContainerName
$blobs = $container | Get-AzStorageBlob | Where-Object { $_.blobProperties.LastModified -ge (Get-Date).Date }
if ($blobs) {
    $blobNames = $blobs.Name
} else {
    $blobNames = @()
}

# work through each day at a time
$fileCount = 0
$workDate = Get-Date -Date $StartDate.ToString('yyyy-MM-dd')

while ($workDate -le $EndDate) {
    $filename = $prefix + $($workDate.ToString('yyyy-MM-dd')) + $suffix
    $path = Join-Path -Path "$([System.IO.Path]::GetTempPath())" -ChildPath $filename
    $workEndTime = $workDate.AddHours(23).AddMinutes(59).AddSeconds(59)
    $addingToFile = 0

    # due to severe rate limiting and amoutn of time required to execute the
    # extract, some subscriptions and/or dates may not complete before time
    # limits, like those imposed by Azure Functions expire.
    #
    # to make for a graceful restart, the script will skip over any files
    # exported after midnight today and only export old or missing files
    if ($blobNames -contains $filename) {
        Write-Host "$filename was updated today, skipping"
        $workDate = $workDate.AddDays(1)
        continue
    }

    foreach ($currentSubscription in $subscriptions) {
        $results = $currentSubscription | Set-AzContext

        # export consumption details to file
        # using second select-object -skip to support lack of -NoHeader in Azure Functions
        $success = $false
        do {
            try {
                Write-Progress -Activity "Working on $filename" -Status "Getting usage for $($currentSubscription.Name)"

                Get-AzConsumptionUsageDetail -StartDate $workDate -EndDate $workEndTime -IncludeMeterDetails -Expand 'AdditionalProperties' -ErrorAction Stop `
                | Select-Object -ExpandProperty MeterDetails -ExcludeProperty Name, MeterDetails, Tags `
                    -Property *, `
                @{Name = 'Tags'; Expression = { $_.Tags ? (ConvertTo-Json $_.Tags -Compress) : '' } }, `
                @{Name = 'ResourceGroupName'; Expression = { $_.InstanceId.Split('/')[4] } } `
                | ConvertTo-Csv -NoTypeInformation `
                | Select-Object -Skip $addingToFile `
                | Out-File -FilePath $path -Append:$addingToFile

                $success = $true
            }
            catch {
                if ($_.Exception.Message -like '*too many attempts*') {
                    Write-Error $_.Exception
                    Write-Host "Retrying in 5 seconds..."
                    # throttle retries
                    Start-Sleep 5
                }
                else {
                    Write-Error "Unable to get data for $($currentSubscription.Name)"
                    throw $_
                }
                finally {
                    $result = $savedContext | Set-AzContext
                }
            }
        } while (-not $success)

        $addingToFile = 1
    }

    # upload to storage container
    Write-Progress -Activity "Working on $filename" -Status "Uploading blob to $StorageAccountName/$ContainerName"
    $results = Set-AzStorageBlobContent -File $path -Container $ContainerName -Blob $filename -Context $storageAccount.Context -Force
    Write-Host "$filename uploaded to $StorageAccountName/$ContainerName"
    $fileCount++

    # clean up
    Remove-Item -Path $path

    # move to next day
    $workDate = $workDate.AddDays(1)
}

$result = $savedContext | Set-AzContext
Write-Host "$fileCount files uploaded"