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

.PARAMETER KeepPrimaryIPAddresses
Assign the IP addresses from the PrimaryVms to the Recovery VMs

.EXAMPLE
.\CreateSiteRecovery.ps1 -RecoveryVaultResourceGroupName 'asr-vault-rg' -RecoveryVaultName 'asr-vault' -PrimaryResourceGroupName 'myproject-rg' -PrimaryVnetResourceGroupName 'vnet-east-rg' -PrimaryVnetName 'vnet-east' -RecoveryResourceGroupName 'myproject-dr-rg' -RecoveryLocation 'westus' -RecoveryVnetResourceGroupName 'vnet-west-rg' -RecoveryVnetName 'vnet-east'
#>

[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $RecoveryVaultResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $RecoveryVaultName,

    [parameter(Mandatory=$True)]
    [string] $PrimaryResourceGroupName,

    [parameter(Mandatory=$False)]
    [string] $PrimaryVnetResourceGroupName,

    [parameter(Mandatory=$False)]
    [string] $PrimaryVnetName,

    [parameter(Mandatory=$False)]
    [array] $PrimaryVmNames,

    [parameter(Mandatory=$True)]
    [string] $RecoveryResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $RecoveryLocation,

    [parameter(Mandatory=$False)]
    [string] $RecoveryVnetResourceGroupName,

    [parameter(Mandatory=$False)]
    [string] $RecoveryVnetName,

    [parameter(Mandatory=$False)]
    [boolean] $KeepPrimaryIPAddress,

    [parameter(Mandatory=$False)]
    [string] $NetworkMappingFile
)

#######################################################################
function Get-AsrCacheStorageAccount {
    Param (
        [parameter(Mandatory = $True)]
        [string] $RecoveryVaultResourceGroupName,

        [parameter(Mandatory = $True)]
        [string] $RecoveryVaultName,

        [parameter(Mandatory = $True)]
        [string] $Location
    )

    $cacheName = (('asr' + $RecoveryVaultName) -replace '[^a-zA-Z0-9]', '').ToLower()[0..19] -join ''
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $RecoveryVaultResourceGroupName -ErrorAction SilentlyContinue | Where-Object {$_.StorageAccountName -like "$cacheName*"}
    if ($storageAccount) {
        Write-Verbose "CacheStorageAccount ($($storageAccount.StorageAccountName)) found"
        return $storageAccount
    }

    $storageAccountName = ($cacheName + $(New-Guid).Guid -replace '[^a-zA-Z0-9]').Substring(0,24).ToLower()
    try {
        Write-Progress -Activity "Creating Cache Storage Account ($storageAccountName)..."
        $storageAccount = New-AzStorageAccount -ResourceGroupName $RecoveryVaultResourceGroupName -Name $storageAccountName -Location $Location -SKU 'Standard_LRS' -ErrorAction 'Stop'
        Write-Verbose "CacheStorageAccount ($($storageAccount.StorageAccountName)) created"
    } catch {
        Write-Error "Error creating StorageAccount for local cache - $($_.Exception)" -ErrorAction Stop
        return $null
    }
    return $storageAccount
}

#######################################################################
function Wait-AsrJob {
    Param (
        [parameter(Mandatory=$True)]
        $AsrJob,

        [parameter(Mandatory=$False)]
        [string] $Message,

        [parameter(Mandatory=$False)]
        [int] $Seconds = 10
    )

    while (($AsrJob.State -eq "InProgress") -or ($AsrJob.State -eq "NotStarted")) {
        if ($Message) {
            Write-Progress -Activity "$Message" -Status "Processing...$($AsrJob.DisplayName)"
        }
        Start-Sleep -Seconds $Seconds
        $AsrJob = Get-ASRJob -Job $AsrJob
        Write-Verbose "Waiting on Job: $($AsrJob.TargetObjectName) - $($AsrJob.State)"
    }
}

#######################################################################
## MAIN

$startTime = Get-Date

##### validate parameters #####

# initialize ASR names
$primaryFabricName = ('A2AP-' + $PrimaryResourceGroupName)[0..44] -join ''
$recoveryFabricName = ('A2AR-' + $recoveryResourceGroupName)[0..44] -join ''

$primaryProtectionContainerName = ('A2AP-' + $PrimaryResourceGroupName)[0..44] -join ''
$recoveryProtectionContainerName = ('A2AR-' + $recoveryResourceGroupName)[0..44] -join ''

$primaryProtectionContainerMappingName = ('A2AP-' + $PrimaryResourceGroupName)[0..44] -join ''
$recoveryProtectionContainerMappingName = ('A2AR-' + $recoveryResourceGroupName)[0..44] -join ''

$policyName = ('A2A-' + $PrimaryResourceGroupName)[0..44] -join ''

$primaryNetworkMappingName = ('A2AP-' + $PrimaryResourceGroupName)[0..44] -join ''
$recoveryNetworkMappingName = ('A2AR-' + $recoveryResourceGroupName)[0..44] -join ''

# make sure virtual networks exist
if ($NetworkMappingFile) {
    if ($PrimaryVnetResourceGroupName -or $PrimaryVnetName -or
        $RecoveryVnetResourceGroupName -or $RecoveryVnetName) {
        Write-Error "-NetworkMappingFile cannot be combined with -PrimaryVnetResourceGroupName, -PrimaryVnetName, -RecoveryVnetResourceGroupName or -RecoveryVnetName" -ErrorAction Stop
    }

    $networkMappingItems = Import-Csv $NetworkMappingFile

    $vnetMap = ($networkMappingItems | Where-Object { $_.SourceResourceId -match "/virtualNetworks/[a-zA-Z0-9_.-]+$" })[0]
    if ($vnetMap) {
        $PrimaryVnetResourceGroupName = ($vnetMap.SourceResourceId -split '/')[4]
        $PrimaryVnetName = ($vnetMap.SourceResourceId -split '/')[-1]
        $RecoveryVnetResourceGroupName = ($vnetMap.DestinationResourceId -split '/')[4]
        $RecoveryVnetName = ($vnetMap.DestinationResourceId -split '/')[-1]
    } else {
        Write-Warning "No virtual network map provided in $($NetworkMappingFile)" -ErrorAction SilentlyContinue
    }
}

if (-not $PrimaryVnetResourceGroupName) {
    Write-Error "-PrimaryVnetResourceGroupName or -NetworkMappingFile must be provided." -ErrorAction Stop
}

if (-not $PrimaryVnetName) {
    Write-Error "-PrimaryVnetName or -NetworkMappingFile must be provided." -ErrorAction Stop
}

if (-not $RecoveryVnetResourceGroupName) {
    Write-Error "-RecoveryVnetResourceGroupName or -NetworkMappingFile must be provided." -ErrorAction Stop
}

if (-not $RecoveryVnetName) {
    Write-Error "-RecoveryVnetName or -NetworkMappingFile must be provided." -ErrorAction Stop
}

# get networks
$primaryVnet = Get-AzVirtualNetwork -ResourceGroupName $PrimaryVnetResourceGroupName -Name $PrimaryVnetName -ErrorAction SilentlyContinue
if (-not $primaryVnet) {
    Write-Error "Error retrieving virtual network $PrimaryVnetResourceGroupName/$PrimaryVnetName - $($_.Exception)" -ErrorAction Stop
}

$recoveryVnet = Get-AzVirtualNetwork -ResourceGroupName $RecoveryVnetResourceGroupName -Name $RecoveryVnetName
if (-not $recoveryVnet) {
    Write-Error "Error retrieving virtual network $RecoveryVnetResourceGroupName/$RecoveryVnetName - $($_.Exception)" -ErrorAction Stop
}

# make sure Vault ResourceGroup exists
$vaultResourceGroup = Get-AzResourceGroup -Name $RecoveryVaultResourceGroupName -ErrorAction SilentlyContinue
if (-not $vaultResourceGroup) {
    $vaultResourceGroup = New-AzResourceGroup -Name $RecoveryVaultResourceGroupName -Location $RecoveryLocation -Force -ErrorAction Stop
}

# make sure RecoveryResourceGroup exists
$primaryResourceGroup = Get-AzResourceGroup -Name $primaryResourceGroupName -ErrorAction Stop

$recoveryResourceGroup = Get-AzResourceGroup -Name $recoveryResourceGroupName -ErrorAction SilentlyContinue
if (-not $recoveryResourceGroup) {
    $recoveryResourceGroup = New-AzResourceGroup -Name $recoveryResourceGroupName -Location $RecoveryLocation -Force -ErrorAction Stop
}

##### START PROCESSING #####

#Create Cache storage account for replication logs in the primary region
$primaryCacheStorageAccount = Get-AsrCacheStorageAccount -RecoveryVaultResourceGroupName $RecoveryVaultResourceGroupName -RecoveryVaultName $RecoveryVaultName -Location $primaryResourceGroup.Location -ErrorAction 'Stop'
# $recoveryCacheStorageAccount = Get-AsrCacheStorageAccount -RecoveryVaultResourceGroupName $RecoveryVaultResourceGroupName -ResourceGroupName $PrimaryResourceGroupName -Location $primaryResourceGroup.Location -ErrorAction 'Stop'

# create vault and set context
try {
    $recoveryVault = Get-AzRecoveryServicesVault -ResourceGroupName $RecoveryVaultResourceGroupName -Name $RecoveryVaultName
    if (-not $recoveryVault) {
        Write-Progress -Activity "Creating Recovery Service Vault ($RecoveryVaultName)..."
        $recoveryVault = New-AzRecoveryServicesVault -ResourceGroupName $RecoveryVaultResourceGroupName -Name $RecoveryVaultName -Location $RecoveryLocation -ErrorAction Stop
        Write-Verbose "Recovery Service Vault ($RecoveryVaultName) created"
    }
    $null = Set-ASRVaultContext -Vault $recoveryVault
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $recoveryVault
} catch {
    Write-Error "Error creating Recovery Vault ($RecoveryVaultName) - $($_.Exception)" -ErrorAction Stop
}

# create ASR fabric
try {
    $primaryFabric = Get-AzRecoveryServicesAsrFabric -Name $primaryFabricName -ErrorAction SilentlyContinue
    if (-not $primaryFabric) {
        $asrJob = New-AzRecoveryServicesAsrFabric -Azure -Location $primaryResourceGroup.Location -Name $primaryFabricName -ErrorAction Stop
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Recovery Service Fabric ($primaryFabricName)..."
        $primaryFabric = Get-AzRecoveryServicesAsrFabric -Name $primaryFabricName -ErrorAction Stop
        Write-Verbose "Recovery Service Fabric ($primaryFabricName) created"
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
        Write-Verbose "Recovery Service Fabric ($recoveryFabricName) created"
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
        Write-Verbose "Protection Container ($primaryProtectionContainerName) created"
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
        Write-Verbose "Protection Container ($recoveryProtectionContainerName) created"
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
        Write-Verbose "Recovery Policy ($policyName) created"
    }
} catch {
    Write-Error "Error creating Policy - $($_.Exception)" -ErrorAction Stop
}

#Create Protection container mapping between the Primary and Recovery Protection Containers with the Replication policy
try {
    $primaryProtectionContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $primaryProtectionContainer | Where-Object {$_.Name -eq $primaryProtectionContainerMappingName}
    if (-not $primaryProtectionContainerMapping) {
        $asrJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name $primaryProtectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $primaryProtectionContainer -RecoveryProtectionContainer $recoveryProtectionContainer
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Protection Container Mapping ($primaryProtectionContainerMappingName)..."
        Write-Verbose "Protection Container Mapping ($primaryProtectionContainerMappingName) created"

        $primaryProtectionContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $primaryProtectionContainer
    }
} catch {
    Write-Error "Error creating Protection Container Mapping ($primaryProtectionContainerMappingName) - $($_.Exception)" -ErrorAction Stop
}

#Create Protection container mapping (for failback) between the Recovery and Primary Protection Containers with the Replication policy
try {
    $recoveryProtectionContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $recoveryProtectionContainer | Where-Object {$_.Name -eq $recoveryProtectionContainerMappingName}
    if (-not $recoveryProtectionContainerMapping) {
        $asrJob = New-AzRecoveryServicesAsrProtectionContainerMapping -Name $recoveryProtectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $recoveryProtectionContainer -RecoveryProtectionContainer $primaryProtectionContainer
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Protection Container Mapping ($recoveryProtectionContainerMappingName)..."
        Write-Verbose "Protection Container Mapping ($recoveryProtectionContainerMappingName) created"

        $recoveryProtectionContainerMapping = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $recoveryProtectionContainer
    }
} catch {
    Write-Error "Error creating Protection Container Mapping ($recoveryContainerMappingName) - $($_.Exception)" -ErrorAction Stop
}

# Create an ASR network mapping between the primary Azure virtual network and the recovery Azure virtual network
try {
    $networkMapping = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $primaryFabric
    if ($networkMapping) {
        Write-Output "Primary Network Mapping ($primaryNetworkMappingName) already exists. Please delete to rebuild network mapping."
    } else {
        $asrJob = New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
            -Name $primaryNetworkMappingName `
            -PrimaryFabric $primaryFabric   -PrimaryAzureNetworkId $primaryVnet.Id `
            -RecoveryFabric $recoveryFabric -RecoveryAzureNetworkId $recoveryVnet.Id
        Wait-AsrJob -AsrJob $asrJob -Message "Creating Network Mapping ($primaryNetworkMappingName)..."
        Write-Verbose "Network Mapping ($primaryNetworkMappingName) created"
    }
} catch {
    Write-Error "Error creating Network Mapping ($primaryNetworkMappingName) - $($_.Exception)" -ErrorAction Stop
}

# Create an ASR network mapping for failback between the recovery Azure virtual network and the primary Azure virtual network
try {
    $networkMapping = Get-AzRecoveryServicesAsrNetworkMapping -PrimaryFabric $recoveryFabric
    if ($networkMapping) {
        Write-Output "Recovery Network Mapping ($recoveryNetworkMappingName) already exists. Please delete to rebuild network mapping."
    } else {
        $asrJob = New-AzRecoveryServicesAsrNetworkMapping -AzureToAzure `
            -Name $recoveryNetworkMappingName `
            -PrimaryFabric $recoveryFabric -PrimaryAzureNetworkId $recoveryVnet.Id `
            -RecoveryFabric $primaryFabric -RecoveryAzureNetworkId $primaryVnet.Id
            Wait-AsrJob -AsrJob $asrJob -Message "Creating Network Mapping ($recoveryNetworkMappingName)..."
            Write-Verbose "Network Mapping ($recoveryNetworkMappingName) created"
    }
} catch {
    Write-Error "Error creating Network Mapping - $($_.Exception)" -ErrorAction Stop
}

# protect VMs
if ($recoveryVms) {
    $vms = Get-AzVm -ResourceGroupName $PrimaryResourceGroupName -Status | Where-Object ($PrimaryVmNames -contains $_.Name)
} else {
    $vms = Get-AzVm -ResourceGroupName $PrimaryResourceGroupName -Status
}

# get current protection status
$protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $primaryProtectionContainer

$protectedVmNames = @()
$protectionJobs = @()
foreach ($vm in $vms) {
    if ($vm.PowerState -ne 'VM running') {
        Write-Warning "$($vm.Name) is not running. Please start the VM and try again. VM is not protected."
        continue
    }

    $protectedItem = $protectedItems | Where-Object {$_.RecoveryAzureVMName -eq $vm.Name}
    if ($protectedItem) {
        if ($protectedItem.ProtectionState -eq "Protected" -or $protectedItem.ProtectionState -eq "UnprotectedStatesBegin") {
            Write-Output "$($vm.Name) already being protected. Please delete protected item if you need to restablish protection."
            $protectedVmNames += $vm.Name
            continue
        }
    }

    $avSetId = $null
    if ($vm.AvailabilitySetReference.id) {
        $avSetIdParts = $vm.AvailabilitySetReference.id -split '/'

        try {
            $sourceAvSet = Get-AzAvailabilitySet -ResourceGroupName $avSetIdParts[4] -Name $avSetIdParts[-1] -ErrorAction Stop
            $destAvSet = Get-AzAvailabilitySet -ResourceGroupName $RecoveryResourceGroupName -Name $avSetIdParts[-1] -ErrorAction SilentlyContinue
            if (-not $destAvSet) {
                $null = New-AzAvailabilitySet -ResourceGroupName $RecoveryResourceGroupName -Name $avSetIdParts[-1] -Location $RecoveryLocation `
                    -Sku $sourceAvSet.Sku `
                    -PlatformFaultDomainCount $sourceAvSet.PlatformFaultDomainCount `
                    -PlatformUpdateDomainCount $sourceAvSet.PlatformUpdateDomainCount
            }
        } catch {
            Write-Error "Error creating AvailabilitySet - $($_.Exception)" -ErrorAction Stop
            continue
        }
    }

    Write-Progress -Activity "Protecting Virtual Machine $($vm.Name)..."
    $diskConfigs = @()

    # configure protection for OS disk
    $diskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
    $resourceIdParts = $diskId -split '/'
    $disk = Get-AzDisk -ResourceGroupName $resourceIdParts[4] -DiskName $resourceIdParts[8]
    $diskAccountType = $disk.Sku.Tier + '_LRS'

#            -RecoveryAzureStorageAccountId $recoveryCacheStorageAccount.Id `

    $diskConfigs += New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
        -LogStorageAccountId $primaryCacheStorageAccount.Id `
        -DiskId $diskId `
        -RecoveryResourceGroupId  $recoveryResourceGroup.ResourceId `
        -RecoveryReplicaDiskAccountType  $diskAccountType `
        -RecoveryTargetDiskAccountType $diskAccountType `
        -ErrorAction Stop

    # configure protection for DATA disks
    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
        $diskId = $dataDisk.ManagedDisk.Id
        $resourceIdParts = $diskId -split '/'
        $disk = Get-AzDisk -ResourceGroupName $resourceIdParts[4] -DiskName $resourceIdParts[8]
        $diskAccountType = $disk.Sku.Tier + '_LRS'

        $diskConfigs += New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
            -LogStorageAccountId $primaryCacheStorageAccount.Id `
            -DiskId $diskId `
            -RecoveryResourceGroupId $recoveryResourceGroup.ResourceId `
            -RecoveryReplicaDiskAccountType  $diskAccountType `
            -RecoveryTargetDiskAccountType $diskAccountType `
            -ErrorAction Stop
    }

    if ($avSetId) {
        $asrJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
            -RecoveryResourceGroupId $recoveryResourceGroup.ResourceId `
            -AzureVmId $vm.Id `
            -Name $vm.Name `
            -ProtectionContainerMapping $primaryProtectionContainerMapping `
            -AzureToAzureDiskReplicationConfiguration $diskconfigs `
            -RecoveryAvailabilitySetId $avSetId `
            -ErrorAction Stop
    } else {
        $asrJob = New-AzRecoveryServicesAsrReplicationProtectedItem -AzureToAzure `
            -RecoveryResourceGroupId $recoveryResourceGroup.ResourceId `
            -AzureVmId $vm.Id `
            -Name $vm.Name `
            -ProtectionContainerMapping $primaryProtectionContainerMapping `
            -AzureToAzureDiskReplicationConfiguration $diskconfigs `
            -ErrorAction Stop
    }

    $protectionJobs += $asrJob
    $protectedVmNames += $vm.Name
    Write-Output "$($vm.Name) protection started"
}

# wait for protection jobs
$message = $protectedVmNames -join ', '
foreach ($protectionJob in $protectionJobs) {
    Wait-AsrJob -AsrJob $protectionJob -Message "Preparing VMs for replication ($message)..." -Seconds 30
}

# waiting for synchronization
[System.Collections.ArrayList] $vmsToUpdate = $($vms.Name)
do {
    $statusMsg = @()

    $protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $primaryProtectionContainer
    foreach ($vm in $vms) {
        if ($protectedVmNames -notcontains $vm.Name) {
            $vmsToUpdate.Remove($vm.Name)
            continue
        }

        $protectedItem = $protectedItems | Where-Object {$_.RecoveryAzureVMName -eq $vm.Name}

        if (-not $protectedItem -or $protectedItem.ProtectionState -like "*Failed*") {
            $statusMsg += "$($vm.Name) (Failed)"
            Write-Warning "$($vm.Name) VM replication failed."
            $vmsToUpdate.Remove($vm.Name)

        } elseif ($protectedItem.ProtectionState -eq "Protected") {
            # update settings on the VM after synch is complete

            if ($vmsToUpdate -contains $vm.Name) {
                Write-Output "$($vm.Name) synchronized"
                $nic = $protectedItem.NicDetailsList[0]

                if ($networkMappingItems) {
                    $subnetMap = $networkMappingItems | Where-Object {$_.SourceResourceId -like "*/virtualNetworks/$($nic.VMNetworkName)/subnets/$($nic.VMSubnetName)"}
                    $vnetId = ($subnetMap.DestinationResourceId -split '/')[0..8] -join '/'
                    $subnetName = ($subnetMap.DestinationResourceId -split '/')[-1]

                    if (-not $subnetMap) {
                        $vnetId = $recoveryVnet.Id
                    }
                }

                $params = @{
                    PrimaryNic = $nic.NicId
                    RecoveryNetworkId = $vnetId
                }

                if ($subnetName) {
                    $params += @{ RecoveryNicSubnetName = $subnetName }
                }

                # update static IP
                if ($KeepPrimaryIPAddress) {
                    $params += @{ RecoveryNicStaticIPAddress = $nic.PrimaryNicStaticIPAddress }
                }

                # update available set
                if ($vm.AvailabilitySetReference.Id) {
                    $avSetIdParts = $vm.AvailabilitySetReference.Id -split '/'
                    $avSetIdParts[4] = $RecoveryResourceGroupName
                    $avSetId = $avSetIdParts -join '/'

                    $params += @{RecoveryAvailabilitySet = $avSetId}
                }

                $asrJob = $protectedItem | Set-AzRecoveryServicesAsrReplicationProtectedItem @params
                Wait-AsrJob -AsrJob $asrJob -Message "Updating protected item $($protectedItem.FriendlyName)..."

                Write-Verbose "$($vm.Name) updated: $($params.values -join ',')"
                $vmsToUpdate.Remove($vm.Name)
            }

        } elseif ($protectedItem.ProtectionState -eq "UnprotectedStatesBegin") {
            $statusMsg += "$($protectedItem.RecoveryAzureVMName)($($protectedItem.ProviderSpecificDetails.MonitoringPercentageCompletion)%)"

        } elseif ($protectedItem.ProtectionState -eq "UnplannedFailoverCommitPendingStatesBegin") {
            Write-Warning "$($vm.Name) undergoing failover, skipped."
            $vmsToUpdate.Remove($vm.Name)

        } else {
            Write-Warning "$($vm.Name) ($($protectedItem.ProtectionState)), skipping"
            $vmsToUpdate.Remove($vm.Name)
        }
    }

    if ($vmsToUpdate) {
        Write-Progress -Activity "Replicating Virtual Machines..." -Status "Synchronizing... $($statusMsg -join ', ')"
        Write-Verbose "Waiting on $($vmsToUpdate -join ',')..."
        Start-Sleep 60
    }

} while ($vmsToUpdate)

$elapsedTime = $(Get-Date) - $startTime
$totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
Write-Output "Protection jobs complete. ($totalTime elapsed)"
