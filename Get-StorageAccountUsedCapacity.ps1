<#
.SYNOPSIS
Get the Used Capacity of a Storage Account.

.DESCRIPTION
This script will retrieve the UsedCapacity value from the Metrics for the storage account

.PARAMETER Id
Resource Id of the Storage Account

.PARAMETER ResourceGroupName
Resource Group Name of the Storage Account

.PARAMETER StorageAccountName
Storage Account Name for the Storage Account

.PARAMETER Hours
Number of hours in the past to retrieve metrics

.EXAMPLE
Get-StorageAccountUsedCapacity.ps1 -ResourceGroupName MyResourceGroup -StorageAccountName mystorageaccount

.EXAMPLE
Get-AzStorageAccount | Get-StorageAccountUsedCapacity.ps1
#>

[CmdletBinding(DefaultParameterSetName='Id')]

param (
    [Parameter(ParameterSetName='Id', ValueFromPipelineByPropertyName, Mandatory)]
    [string] $Id,

    [Parameter(ParameterSetName='StorageAccountName', ValueFromPipelineByPropertyName, Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(ParameterSetName='StorageAccountName', ValueFromPipelineByPropertyName, Mandatory)]
    [string] $StorageAccountName,

    [Parameter()]
    [Int] $Hours = 4
)

begin {
    try {
        $result = Get-AzContext -ErrorAction Stop
        if (-not $result.Environment) {
            throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
        }
    }
    catch {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Id') {
        $null = $Id -match '^.*/(.*)$'
        $storageAccountName = $matches[1]
    } else {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
        if (-not $storageAccount) {
            Write-Warning "$storageAccountName, storage account not found"
            return $null
        }
        $Id = $storageAccount.Id
    }

    $metric = Get-AzMetric -ResourceId $Id -MetricName 'UsedCapacity' -StartTime (((Get-Date).AddHours($Hours * -1)) -f 'yyyy-MM-dd') -ErrorAction SilentlyContinue
    if (-not $metric) {
        Write-Warning "$Id, metrics not found"
        return $null
    }

    return [PSCustomObject] @{
        StorageAccountName = $storageAccountName
        UsedCapacity = $metric.Data[0].Average
        Id = $Id
    }
}

end {
}