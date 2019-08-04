<#
.SYNOPSIS

Make a copy of resources or an entire resource group.
.DESCRIPTION

This Powershell command will make a copy specific resources or a entire resource group.

.PARAMETER RecoveryVaultResourceGroupName

Name of file Resource Group of the Recovery Vault
.PARAMETER RecoveryVaultName

Name of the Recovery Vault
.PARAMETER PrimaryResourceGroupName

Name of the Primary Resource Group for VMs to be protected
.PARAMETER PrimaryVnetResourceGroupName

Resource Group Name of the Primary Virtual Network
.PARAMETER PrimaryVnetName

Name of the Primary Virtual Network
.PARAMETER RecoveryResourceGroupName

Name of resource group to put failover virtual machines and disks in
.PARAMETER RecoveryLocation

Location for site recovery
.PARAMETER RecoveryVnetResourceGroupName

Name of the Resource Group where the virtual network for failover is deployed in
.PARAMETER RecoveryVnetName

Virtual network to deploy failover virtual machines into
.EXAMPLE

.\CreateSiteRecovery.ps1
#>

[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $RecoveryVaultResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $RecoveryVaultName,

    [parameter(Mandatory=$True)]
    [string] $PrimaryResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $PrimaryVnetResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $PrimaryVnetName,

    [parameter(Mandatory=$False)]
    [array] $PrimaryVmNames,

    [parameter(Mandatory=$True)]
    [string] $RecoveryResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $RecoveryLocation,

    [parameter(Mandatory=$True)]
    [string] $RecoveryVnetResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $RecoveryVnetName
)


#######################################################################
function Get-AsrCacheStorageAccount {
    Param (
        [parameter(Mandatory = $True)]
        [string] $RecoveryVaultResourceGroupName,

        [parameter(Mandatory = $True)]
        [string] $ResourceGroupName,

        [parameter(Mandatory = $True)]
        [string] $Location
    )

    $find
    $cacheName = $($($ResourceGroupName + 'asrch') -replace '[^a-zA-Z0-9]', '').ToLower()
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $RecoveryVaultResourceGroupName -ErrorAction SilentlyContinue | Where-Object {$_.StorageAccountName -like "$cacheName*"}
    if ($storageAccount) {
        return $storageAccount
    }

    $storageAccountName = $($cacheName + $(New-Guid).Guid -replace '[^a-zA-Z0-9]').Substring(0,24).ToLower()
    try {
        Write-Progress -Activity "Creating Cache Storage Account ($storageAccountName)..."
        $storageAccount = New-AzStorageAccount -ResourceGroupName $RecoveryVaultResourceGroupName -Name $storageAccountName -Location $Location -SKU 'Standard_LRS' -ErrorAction 'Stop'
    } catch {
        Write-Error "Error creating StorageAccount for local cache - $($_.Exception)" -ErrorAction Stop
        return $null
    }
    return $storageAccount
}


#######################################################################
function Wait-AsrJob {
    Param (
        [parameter(Mandatory = $True)]
        $AsrJob,

        [parameter(Mandatory = $False)]
        [string] $Message
    )

    while (($AsrJob.State -eq "InProgress") -or ($AsrJob.State -eq "NotStarted")) {
        if ($Message) {
            Write-Progress -Activity $Message -CurrentOperation $AsrJob.DisplayName
        }
        Start-Sleep 10;
        $AsrJob = Get-ASRJob -Job $AsrJob
    }
}

#######################################################################
## START PROCESSING

$startTime = Get-Date

# initialize ASR names
$primaryFabricName = 'Az2AzFabric-' + $PrimaryResourceGroupName
$recoveryFabricName = 'Az2AzFabric-' + $recoveryResourceGroupName

$primaryProtectionContainerName = 'Az2AzContainer-' + $PrimaryResourceGroupName
$recoveryProtectionContainerName = 'Az2AzContainer-' + $recoveryResourceGroupName

$primaryProtectionContainerMappingName = 'Az2AzContMap-' + $PrimaryResourceGroupName
$recoveryProtectionContainerMappingName = 'Az2AzContMap-' + $recoveryResourceGroupName

$policyName = 'Az2AzPolicy-' + $PrimaryResourceGroupName

$primaryNetworkMappingName = 'Az2AzNetworkMapping-' + $PrimaryResourceGroupName
$recoveryNetworkMappingName = 'Az2AzNetworkMapping-' + $recoveryResourceGroupName


# validate read-only items exists
# make sure virtual networks exist
$primaryVnet = Get-AzVirtualNetwork -ResourceGroupName $PrimaryVnetResourceGroupName -Name $PrimaryVnetName -ErrorAction SilentlyContinue
if (-not $primaryVnet) {
    Write-Error "Error retrieving virtual network $PrimaryVnetResourceGroupName/$PrimaryVnetName - $($_.Exception)" -ErrorAction Stop
}

$recoveryVnet = Get-AzVirtualNetwork -ResourceGroupName $RecoveryVnetResourceGroupName -Name $RecoveryVnetName
if (-not $recoveryVnet) {
    Write-Error "Error retrieving virtual network $RecoveryVnetResourceGroupName/$RecoveryVnetName - $($_.Exception)" -ErrorAction Stop
}

# make sure Vault ResourceGroup exists
$null = New-AzResourceGroup -Name $RecoveryVaultResourceGroupName -Location $RecoveryLocation -Force -ErrorAction Stop

# make sure RecoveryResourceGroup exists
$primaryResourceGroup = Get-AzResourceGroup -Name $primaryResourceGroupName -ErrorAction Stop

$recoveryResourceGroup = Get-AzResourceGroup -Name $recoveryResourceGroupName -ErrorAction SilentlyContinue
if (-not $recoveryResourceGroup) {
    $recoveryResourceGroup = New-AzResourceGroup -Name $recoveryResourceGroupName -Location $RecoveryLocation -Force -ErrorAction Stop
}

#Create Cache storage account for replication logs in the primary region
$primaryCacheStorageAccount = Get-AsrCacheStorageAccount -RecoveryVaultResourceGroupName $RecoveryVaultResourceGroupName -ResourceGroupName $PrimaryResourceGroupName -Location $primaryResourceGroup.Location -ErrorAction 'Stop'
# $recoveryCacheStorageAccount = Get-AsrCacheStorageAccount -RecoveryVaultResourceGroupName $RecoveryVaultResourceGroupName -ResourceGroupName $PrimaryResourceGroupName -Location $primaryResourceGroup.Location -ErrorAction 'Stop'

# create vault and set context
try {
    $recoveryVault = Get-AzRecoveryServicesVault -ResourceGroupName $RecoveryVaultResourceGroupName -Name $RecoveryVaultName
    if (-not $recoveryVault) {
        Write-Progress -Activity "Creating Recovery Service Vault ($RecoveryVaultName)..."
        $recoveryVault = New-AzRecoveryServicesVault -ResourceGroupName $RecoveryVaultResourceGroupName -Name $RecoveryVaultName -Location $RecoveryLocation -ErrorAction Stop
    }
    $null = Set-ASRVaultContext -Vault $recoveryVault
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $recoveryVault
} catch {
    Write-Error "Error creating Recovery Vault ($RecoveryVaultName) -  $($_.Exception)" -ErrorAction Stop
}

# create ASR fabric
try {
    $primaryFabric = Get-AzRecoveryServicesAsrFabric -Name $primaryFabricName -ErrorAction SilentlyContinue
    if (-not $primaryFabric) {
        $asrJob = New-AzRecoveryServicesAsrFabric -Azure -Location $primaryResourceGroup.Location -Name $primaryFabricName -ErrorAction Stop
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Recovery Service Fabric ($primaryFabricName)..."
        $primaryFabric = Get-AzRecoveryServicesAsrFabric -Name $primaryFabricName -ErrorAction Stop
    }
} catch {
    Write-Error "Error creating Fabric ($primaryFabricName) - $($_.Exception)" -ErrorAction Stop
}

try {
    $recoveryFabric = Get-AzRecoveryServicesAsrFabric -Name $recoveryFabricName -ErrorAction SilentlyContinue
    if (-not $recoveryFabric) {
        $asrJob = New-AzRecoveryServicesAsrFabric -Azure -Location $RecoveryLocation -Name $recoveryFabricName
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Recovery Service Fabric ($recoveryFabricName)..."
        $recoveryFabric = Get-AzRecoveryServicesAsrFabric -Name $recoveryFabricName -ErrorAction Stop
    }
} catch {
    Write-Error "Error creating Fabric ($recoveryFabricName) - $($_.Exception)" -ErrorAction Stop
}


#Create a Protection container in the source Azure region (within the Primary fabric)
try {
    $primaryProtectionContainer = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $primaryFabric -Name $primaryProtectionContainerName -ErrorAction SilentlyContinue
    if (-not $primaryProtectionContainer) {
        $asrJob = New-AzRecoveryServicesAsrProtectionContainer -InputObject $primaryFabric -Name $primaryProtectionContainerName -ErrorAction Stop
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Protection Container ($primaryProtectionContainerName)..."
        $primaryProtectionContainer = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $primaryFabric -Name $primaryProtectionContainerName -ErrorAction SilentlyContinue
    }
} catch {
    Write-Error "Error creating Protection Container ($primaryProtectionContainerName) - $($_.Exception)" -ErrorAction Stop
}

try {
    $recoveryProtectionContainer =  Get-AzRecoveryServicesAsrProtectionContainer -Fabric $recoveryFabric -Name $recoveryProtectionContainerName -ErrorAction SilentlyContinue
    if (-not $recoveryProtectionContainer) {
        $asrJob = New-AzRecoveryServicesAsrProtectionContainer -InputObject $recoveryFabric -Name $recoveryProtectionContainerName -ErrorAction SilentlyContinue
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Protection Container ($recoveryProtectionContainerName)..."
        $recoveryProtectionContainer = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $recoveryFabric -Name $recoveryProtectionContainerName -ErrorAction Stop
    }
} catch {
    Write-Error "Error creating Protection Container ($recoveryProtectionContainerName) - $($_.Exception)" -ErrorAction Stop
}

#Create replication policy
try {
    $policy =  Get-AzRecoveryServicesAsrPolicy -Name $policyName -ErrorAction SilentlyContinue
    if (-not $policy) {
        $asrJob = New-AzRecoveryServicesAsrPolicy -AzureToAzure -Name $policyName -RecoveryPointRetentionInHours 24 -ApplicationConsistentSnapshotFrequencyInHours 4 -ErrorAction Stop
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Recovery Policy ($policyName)..."
        $policy = Get-AzRecoveryServicesAsrPolicy -Name $policyName -ErrorAction Stop
    }
} catch {
    Write-Error "Error creating Policy - $($_.Exception)" -ErrorAction Stop
}

#Create Protection container mapping between the Primary and Recovery Protection Containers with the Replication policy
try {
    $asrJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name $primaryProtectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $primaryProtectionContainer -RecoveryProtectionContainer $recoveryProtectionContainer
    Wait-AsrJob -AsrJob $asrJob -Message "Creating Protection Container Mapping ($primaryProtectionContainerMappingName)..."
    $primaryProtectionContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $primaryProtectionContainer
} catch {
    Write-Error "Error creating Protection Container Mapping (primary) - $($_.Exception)" -ErrorAction Stop
}

#Create Protection container mapping (for failback) between the Recovery and Primary Protection Containers with the Replication policy
try {
    $asrJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name $recoveryProtectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $recoveryProtectionContainer -RecoveryProtectionContainer $primaryProtectionContainer
    Wait-AsrJob -AsrJob $asrJob -Message "Creating Protection Container Mapping ($recoveryProtectionContainerMappingName)..."
} catch {
    Write-Error "Error creating Protection Container Mapping ($recoveryContainerMappingName) - $($_.Exception)" -ErrorAction Stop
}


#Create an ASR network mapping between the primary Azure virtual network and the recovery Azure virtual network
try {
    $networkMapping = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryFabric
    if ($networkMapping) {
        $asrJob = Remove-AzRecoveryServicesAsrNetworkMapping -InputObject $networkMapping
        Wait-AsrJob -AsrJob $asrJob -Message "Removing old Network Mapping ($primaryNetworkMappingName)..."
    }
    $asrJob = New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
        -Name $primaryNetworkMappingName `
        -PrimaryFabric $primaryFabric   -PrimaryAzureNetworkId $primaryVnet.Id `
        -RecoveryFabric $recoveryFabric -RecoveryAzureNetworkId $recoveryVnet.Id
    Wait-AsrJob -AsrJob $asrJob -Message "Creating Network Mapping ($primaryNetworkMappingName)..."
} catch {
    Write-Error "Error creating Network Mapping ($primaryNetworkMappingName) - $($_.Exception)" -ErrorAction Stop
}

#Create an ASR network mapping for failback between the recovery Azure virtual network and the primary Azure virtual network
try {
    $networkMapping = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $recoveryFabric
    if ($networkMapping) {
        $asrJob = Remove-AzRecoveryServicesAsrNetworkMapping -InputObject $networkMapping
        Wait-AsrJob -AsrJob $asrJob -Message "Removing old Network Mapping ($recoveryNetworkMappingName)..."
    }
    $asrJob = New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
        -Name $recoveryNetworkMappingName `
        -PrimaryFabric $recoveryFabric -PrimaryAzureNetworkId $recoveryVnet.Id `
        -RecoveryFabric $primaryFabric -RecoveryAzureNetworkId $primaryVnet.Id
    Wait-AsrJob -AsrJob $asrJob -Message "Creating Network Mapping ($recoveryNetworkMappingName)... "
} catch {
    Write-Error "Error creating Network Mapping - $($_.Exception)" -ErrorAction Stop
}

# replicate a VM
if ($recoveryVms) {
    $vms = Get-AzVm -ResourceGroupName $PrimaryResourceGroupName -Status | Where-Object ($PrimaryVmNames -contains $_.Name)
} else {
    $vms = Get-AzVm -ResourceGroupName $PrimaryResourceGroupName -Status
}

$vmCount = 0
foreach ($vm in $vms) {
    if ($vm.PowerState -ne 'VM running') {
        Write-Warning "$($vm.Name) is not running. Please start the VM and try again. VM is not protected."
        continue
    }

    $avSetId = $null
    if ($vm.AvailabilitySetReference.id) {
        $avSetIdParts = $vm.AvailabilitySetReference.id -split '/'
        $avSetIdParts[4] = 'asr-test-az'
        $avSetId = $avSetIdParts -join '/'
    }

    Write-Progress -Activity "Protecting Virtual Machine $($vm.Name)..."
    $diskConfigs = @()

    $diskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
    $resourceIdParts = $diskId -split '/'
    $disk = Get-AzDisk -ResourceGroupName $resourceIdParts[4] -DiskName $resourceIdParts[8]
    $diskAccountType = $disk.Sku.Tier + '_LRS'

    $diskConfigs += New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk -LogStorageAccountId $primaryCacheStorageAccount.Id `
        -DiskId $diskId -RecoveryResourceGroupId  $recoveryResourceGroup.ResourceId `
        -RecoveryReplicaDiskAccountType  $diskAccountType `
        -RecoveryTargetDiskAccountType $diskAccountType `
        -ErrorAction Stop

    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $diskId = $dataDisk.ManagedDisk.Id
        $resourceIdParts = $diskId -split '/'
        $disk = Get-AzDisk -ResourceGroupName $resourceIdParts[4] -DiskName $resourceIdParts[8]
        $diskAccountType = $disk.Sku.Tier + '_LRS'

        $diskConfigs += New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
            -LogStorageAccountId $primaryCacheStorageAccount.Id `
            -DiskId $diskId
            -RecoveryResourceGroupId $recoveryResourceGroup.ResourceId `
            -RecoveryReplicaDiskAccountType  $diskAccountType `
            -RecoveryTargetDiskAccountType $diskAccountType `
            -ErrorAction Stop
    }

    if ($avSetId) {
        $asrJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
            -RecoveryResourceGroupId $recoveryResourceGroup.ResourceId `
            -AzureVmId $vm.Id `
            -Name (New-Guid).Guid `
            -ProtectionContainerMapping $primaryProtectionContainerMapping `
            -AzureToAzureDiskReplicationConfiguration $diskconfigs `
            -RecoveryAvailabilitySetId $avSetId
    } else {
        $asrJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
            -RecoveryResourceGroupId $recoveryResourceGroup.ResourceId `
            -AzureVmId $vm.Id `
            -Name (New-Guid).Guid `
            -ProtectionContainerMapping $primaryProtectionContainerMapping `
            -AzureToAzureDiskReplicationConfiguration $diskconfigs
    }

    Write-Output "$($vm.Name) protection started"
    $vmCount += 1
}

$elapsedTime = $(Get-Date) - $startTime
$totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
Write-Output "$vmCount protection jobs started. ($totalTime elapsed) Check replication jobs for progress."


# Set-AzRecoveryServicesAsrReplicationProtectedItem
#    -InputObject <ASRReplicationProtectedItem>
#    [-Name <String>]
#    [-Size <String>]
#    [-PrimaryNic <String>]
#    [-RecoveryNetworkId <String>]
#    [-RecoveryCloudServiceId <String>]
#    [-RecoveryNicSubnetName <String>]
#    [-RecoveryNicStaticIPAddress <String>]
#    [-NicSelectionType <String>]
#    [-recoveryVaultResourceGroupId <String>]
#    [-LicenseType <String>]
#    [-RecoveryAvailabilitySet <String>]
#    [-RecoveryBootDiagStorageAccountId <String>]
#    [-AzureToAzureUpdateReplicationConfiguration <ASRAzuretoAzureDiskReplicationConfig[]>]
#    [-UseManagedDisk <String>]
#    [-DefaultProfile <IAzureContextContainer>]
#    [-WhatIf]
#    [-Confirm]
#    [<CommonParameters>]


