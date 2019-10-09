<#
.SYNOPSIS
Make a copy of resources or an entire resource group.

.DESCRIPTION
This Powershell command will make a copy specific resources or a entire resource group.

.PARAMETER Filename
Name of file containing Network Security Group configuration

.PARAMETER SourceResourceGroupname
Name of ResourceGroup to copy

.PARAMETER SourceResourceNames
Names of specific resources to copy. If none are provided the entire resource group will be copied.

.PARAMETER DestinationResourceGroupName
Name of resource group where resources will be copied to

.PARAMETER DestinationLocation
Location where resources will be copied to. If DestinationLocation is not provided the copy will be placed in the same location as the source.

.PARAMETER MappingFile
Filepath of comma separated file containing mapping of resources referenced by this resource group that differ from the source. The file should contain two columns: SourceResourceId, DestinationResourceId. Headers are required.

.PARAMETER CopyDiskContents
Set this parameter to TRUE to make a copy of the disks. Disk copies will only be made in the current location. Cross-region copies of disks is currently not supported.

.PARAMETER AdminPassword
Provide an Admin password that should be set for virtual machines that are created without copying the disks. A randomly generated password will be set if not provided.

.PARAMETER ExportTemplateOnly
Output the generated ARM template and stop. If this parameter is set to true, no resources will be copied.

.PARAMETER IncludeResourceTypes
Include only the Resource Types listed in this array. If you supply -SourceResourceNames this parameter will be ignored.

.PARAMETER ExcludeResourceTypes
Excludes any Resource Types listed in this array. If you supply -SourceResourceNames this parameter will be ignored.

.PARAMETER ExcludeResourceNames
Excludes any resources found in this array. This includes anything that might have been listed in teh -SourceResourceNames parameter.

.EXAMPLE
.\CopyResources.ps1 -SourceResourceGroupName sample-rg -DestinationResourceGroup copy-of-sample-rg
#>

[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $SourceResourceGroupName,

    [parameter(Mandatory=$False)]
    [array] $SourceResourceNames,

    [parameter(Mandatory=$True)]
    [string] $DestinationResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $DestinationLocation,

    [parameter(Mandatory=$False)]
    [string] $MappingFile,

    [parameter(Mandatory=$False)]
    [boolean] $CopyDiskContents,

    [parameter(Mandatory=$False)]
    [string] $AdminPassword,

    [parameter(Mandatory=$False)]
    [boolean] $ExportTemplateOnly,

    [parameter(Mandatory=$False)]
    [boolean] $KeepSourceIPAddresses,

    [parameter(Mandatory=$False)]
    [array] $IncludeResourceTypes,

    [parameter(Mandatory=$False)]
    [array] $ExcludeResourceTypes,

    [parameter(Mandatory=$False)]
    [array] $ExcludeResourceNames
)

#######################################m################################

function UpdateSubnet {
    Param (
        [parameter(Mandatory = $True)]
        $subnet,

        [parameter(Mandatory = $True)]
        [string] $SourceResourceGroupName,

        [parameter(Mandatory = $True)]
        [string] $DestinationResourceGroupName,

        [parameter(Mandatory = $False)]
        [string] $DestinationLocation,

        [parameter(Mandatory = $False)]
        [array] $includedNsgNames
    )

    # update endpoint locations
    if ($DestinationLocation) {
        foreach ($endpoint in $subnet.properties.serviceEndpoints) {
            $endpoint.Locations = @($DestinationLocation)
        }
    }

    # update network security groups
    if ($subnet.properties.networkSecurityGroup.id) {

        if ($subnet.properties.networkSecurityGroup.id -like "/subscriptions/*") {
            # any NSG w/full URI is not included in the template export & included NSG will use ARM reference
            $nsgIdParts = $subnet.properties.networkSecurityGroup.id -split '/'
            $nsgResourceGroupName = $nsgIdParts[4]
            $nsgResourceName = $nsgIdParts[8]

            if ($nsgResourceGroupName -ne $SourceResourceGroupName) {
                if ($DestinationLocation) {
                    Write-Warning "Network Security Group ($nsgResourceName) not in ResourceGroup ($SourceResourceGroupName). Must be created and associated manually. Reference to $nsgResourceName will be removed."
                    $subnet.properties.networkSecurityGroup = $null
                }
            }
            elseif ($includedNsgNames -notcontains $nsgResourceName) {
                Write-Warning "Network Security Group ($nsgResourceName) not in copy resource list. Make sure it already exists in '$DestinationResourceGroupName' resource group or add to -SourceResourceNames list."
                $nsgidParts[4] = $destinationResourceGroupName
                $subnet.properties.networkSecurityGroup.id = $nsgIdParts -join '/'
            }
            else {
                Write-Error "NSG - invalid scenario with $($subnet.properties.networkSecurityGroup.id)"
            }
        }
    }

    return $subnet
}

#######################################m################################

# MAIN processing
$startTime = Get-Date

# validate parameters

$sourceResourceGroup = Get-AzResourceGroup -ResourceGroupName $SourceResourceGroupName -ErrorAction SilentlyContinue
if (-not $sourceResourceGroup) {
    Write-Error "Unable to read Resource Group ($sourceResourceGroupName). Please check and try again."
    return
}

if ($SkipVirtualMachines -or $SkipDisks) {
    # do nothing

} else {
    # make sure parameters set for copying VMs

    if ($CopyDiskContents) {
        if ($DestinationLocation -and ($sourceResourceGroup.Location -ne $DestinationLocation)) {
            Write-Error "INVALID OPTIONS: Cross-Region copy of disk content not yet supported. Use -CopyDiskContent set to FALSE."
            return
        }
    } else {
        if (-not $AdminPassword) {
            Write-Warning 'ADMIN PASSWORD randomly generated. Please reset password to access virtual machines.'
        }
    }

    if (-not $AdminPassword) {
        $AdminPassword = -join ((48..57) + (65..91) + (97..122) | Get-Random -Count 15 | ForEach-Object {[char]$_})
    }
}

# load list of resources to extract
$SourceTemplateFilepath = $env:TEMP + "\" + $SourceResourceGroupName + ".json"
$DestinationTemplateFilepath = $env:TEMP + "\" + $DestinationResourceGroupName + ".json"

Write-Verbose "Creating template of current resources to $SourceTemplateFilepath"
if ($SourceResourceNames) {
    if ($IncludeResourceTypes -or $ExcludeResourceTypes) {
        Write-Warning "-IncludeResourceTypes and -ExcludeResourceTypes parameters will be ignored when using -SourceResourceNames"
    }
    $resources = Get-AzResource -ResourceGroupName $SourceResourceGroupName | Where-Object { $SourceResourceNames -contains $_.Name }

} else {
    if ($IncludeResourceTypes) {
        $resources = Get-AzResource -ResourceGroupName $SourceResourceGroupName | Where-Object { $IncludeResourceTypes -contains  $_.ResourceType }

    } else {
        $resources = Get-AzResource -ResourceGroupName $SourceResourceGroupName
    }

    # filter out ExcludeResourceTypes
    $resources = $resources | Where-Object { $ExcludeResourceTypes -notcontains $_.ResourceType}
}

# filter out specific ResourceNames
$resources = $resources | Where-Object { $ExcludeResourceNames -notcontains $_.Name}

# filter out unsupported copy types
$SupportedResourceTypes = @(
    "Microsoft.Compute/availabilitySets",
    "Microsoft.Compute/disks",
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Logic/workflows",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Network/virtualNetworks/subnets",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/loadBalancers/inboundNatRules",
    "Microsoft.Network/networkInterfaces",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/networkSecurityGroups/securityRules"
)

$SupportedResources = @()
$disksToCopy = @()

foreach ($resource in $resources) {
    if ($SupportedResourceTypes -contains $resource.ResourceType) {
        if ($resource.Type -eq 'Microsoft.Compute/disks') {
            if ($CopyDiskContents) {
                $disksToCopy += Get-AzDisk -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name
            } else {
                Write-Verbose "DISK NOT COPIED: $($resource.ResourceType) ($($resource.name)) will not be copied. Use -CopyDiskContents to copy disks."
            }
        } else {
            $SupportedResources += $resource
        }
    } else {
        Write-Warning "COPY NOT SUPPORTED: $($resource.ResourceType) ($($resource.name)) not supported."
    }
}

# export resources into a template
$resourceIds = $SupportedResources.ResourceId
$null = Export-AzResourceGroup -Path $SourceTemplateFilepath -ResourceGroupName $SourceResourceGroupName -Resource $resourceIds -SkipAllParameterization -Force -ErrorAction Stop
$template = Get-Content $SourceTemplateFilepath | ConvertFrom-Json

# process all resources
$finalResources = @()
Write-Verbose "Processing resources and updating for new resource group & location"
foreach ($resource in $template.resources) {

    Write-Verbose "Processing $($resource.Name)"

    # update top level resource with locaion
    if ($resource.Location -and $DestinationLocation) {
        $resource.Location = $DestinationLocation
    }

    # required update differ by resource type
    if ($resource.Type -eq "Microsoft.Compute/availabilitySets") {
        $resource.dependsOn = $null
        $resource.properties.virtualMachines = $null

    } elseif ($resource.Type -eq "Microsoft.Compute/disks") {
        Write-Error "INVALID SCENARIO: $($resource.Type) needs to be handled in pre-processing"

    } elseif ($resource.Type -eq "Microsoft.Compute/virtualMachines") {
        if ($resource.identity) {
            $resource.identity = $null
        }

        if ($CopyDiskContents) {
            $resource.properties.storageProfile.imageReference = $null
            $resource.properties.osProfile = $null

            $resource.properties.storageProfile.osDisk.createOption = 'Attach'
            $resource.properties.storageProfile.osDisk.managedDisk.id = $resource.properties.storageProfile.osDisk.managedDisk.id `
                -Replace $('/resourceGroups/' + $SourceResourceGroupName + '/'), $('/resourceGroups/' + $DestinationResourceGroupName + '/')

            foreach ($dataDisk in $resource.properties.storageProfile.dataDisks) {
                $dataDisk.managedDisk.id =  $dataDisk.managedDisk.id `
                    -Replace $('/resourceGroups/' + $SourceResourceGroupName + '/'), $('/resourceGroups/' + $DestinationResourceGroupName + '/')
            }

        } else {
            $resource.properties.osProfile | Add-Member -NotePropertyName adminPassword -NotePropertyValue $adminPassword
            $resource.properties.storageProfile.osDisk.managedDisk.id = $null
            foreach ($dataDisk in $resource.properties.storageProfile.dataDisks) {
                $dataDisk.createOption = 'Empty'
                $dataDisk.managedDisk.id = $null
            }
        }

    } elseif ($resource.Type -eq "Microsoft.Compute/virtualMachines/extensions") {
        # not not add to final template
        Write-Warning "COPY NOT SUPPORTED: $($resource.ResourceType) ($($resource.name)) not supported."
        continue

    } elseif ($resource.Type -eq "Microsoft.Network/applicationGateways") {
        # remove NIC dependencies as NIC contains the applicationGateway. the NIC ID's on the LB are reference only
        if ($resource.dependsOn) {
            [array] $resource.dependsOn = $resource.dependsOn | Where-Object {$_ -notlike "*Microsoft.Network/networkInterfaces*"}
        }

        if ($KeepSourceIPAddresses) {
            foreach ($ipconfig in $resource.Properties.frontendIPConfigurations) {
                if ($ipConfig.properties.privateIPAddress -and $ipconfig.properties.subnet) {
                    $ipConfig.properties.privateIPAllocationMethod = 'Static'
                }
            }
        }

    } elseif ($resource.Type -eq "Microsoft.Logic/workflows") {
        # no changes required

    } elseif ($resource.Type -eq "Microsoft.Network/loadBalancers") {
        # remove NIC dependencies as NIC contains the loadBalancer. the NIC ID's on the LB are reference only
        if ($resource.dependsOn) {
            [array] $resource.dependsOn = $resource.dependsOn | Where-Object {$_ -notlike "*Microsoft.Network/networkInterfaces*"}
        }

        if ($KeepSourceIPAddresses) {
            foreach ($ipconfig in $resource.Properties.frontendIPConfigurations) {
                if ($ipConfig.properties.privateIPAddress -and $ipconfig.properties.subnet) {
                    $ipConfig.properties.privateIPAllocationMethod = 'Static'
                }
            }
        }

    } elseif ($resource.Type -eq "Microsoft.Network/loadBalancers/inboundNatRules") {
        # no changes required

    } elseif ($resource.Type -eq "Microsoft.Network/networkInterfaces") {
        if ($KeepSourceIPAddresses) {
            foreach ($ipConfig in $resource.Properties.ipConfigurations) {
                $ipConfig.properties.privateIPAllocationMethod = 'Static'
            }
        }
    } elseif ($resource.Type -eq "Microsoft.Network/networkSecurityGroups") {
        # no changes required

    } elseif ($resource.Type -eq "Microsoft.Network/networkSecurityGroups/securityRules") {
        # no changes required
    } elseif ($resource.Type -eq "Microsoft.Network/publicIPAddresses") {
        # $resource.properties.publicIpAllocationMethod = 'Dynamic'
        if ($resource.properties.ipAddress) {
            $resource.properties.ipAddress = $null
        }

        if ($resource.properties.dnsSettings) {
            $resource.properties.dnsSettings = $null
            Write-Warning "PUBLIC IP MODIFIED: $($resource.Type) ($($resource.name)) DNS settings ignored. Update settings as needed after deployment."
        }

    } elseif ($resource.Type -eq "Microsoft.Network/virtualNetworks") {
        $nsgNames = $($resources | Where-Object { $_.Type -eq 'Microsoft.Network/networkSecurityGroups' }).Name

        # vnet top level
        if ($DestinationLocation) {
            $resource.Location = $DestinationLocation
        }

        # subnet
        foreach ($subnet in $resource.properties.subnets) {
            $subnet = UpdateSubnet -subnet $subnet `
                -SourceResourceGroupName $SourceResourceGroupName `
                -DestinationResourceGroupName $DestinationResourceGroupName `
                -DestinationLocation $DestinationLocation `
                -includedNsgNames $nsgNames
        }

    } elseif ($resource.Type -eq "Microsoft.Network/virtualNetworks/subnets") {
        $resource = UpdateSubnet -subnet $resource `
            -SourceResourceGroupName $SourceResourceGroupName `
            -DestinationResourceGroupName $DestinationResourceGroupName `
            -DestinationLocation $DestinationLocation `
            -includedNsgNames $nsgNames

    } else {
        Write-Warning "NOT SUPPORTED: $($resource.Type) will not be copied."
    }

    $finalResources += $resource
}

$template.resources = $finalResources
$templateJson = $template | ConvertTo-Json -Depth 10

# replace all mappings
if ($MappingFile) {
    $mappings = Import-Csv $MappingFile
    foreach ($mapping in $mappings) {
        $templateJson = $templateJson.Replace('"' + $mapping.SourceResourceId + '"', '"' + $mapping.DestinationResourceId + '"')
    }
}
$templateJson | Set-Content -Path $DestinationTemplateFilepath

# Only export the template and stop
if ($ExportTemplateOnly) {
    Get-Content -Path $DestinationTemplateFilepath
    exit
}

# start copy processing
Write-Progress -Activity "Copy started..."

# make sure ResourceGroup exists
try {
    $location = $DestinationLocation
    if (-not $location) {
        $location = $sourceResourceGroup.Location
    }
    $null = New-AzResourceGroup -Name $DestinationResourceGroupName -Location $location -Force -ErrorAction Stop

} catch {
    Write-Error "Error accessing Resource Group $DestinationResourceGroupName - $($_.Exception)"
    exit
}

# copy any disks needed
if ($disksToCopy) {
    foreach ($disk in $disksToCopy) {
        Write-Progress -Activity "Copying disk(s)" -Status "Working on $($disk.Name) contents..."
        $diskConfig = New-AzDiskConfig -SourceResourceId $disk.Id -Location $disk.Location -Sku $disk.sku.Name -CreateOption Copy
        $null = New-AzDisk -Disk $diskConfig -DiskName $disk.Name -ResourceGroupName $DestinationResourceGroupName
    }
}

# deploy template
try {
    $deploymentName = $DestinationResourceGroupName + '_' + $(Get-Date -Format 'yyyyMMddhhmmss')
    $job = New-AzResourceGroupDeployment -Name $deploymentName -TemplateFile $DestinationTemplateFilepath -ResourceGroupName $DestinationResourceGroupName -AsJob -ErrorAction Stop
} catch {
    Write-Error "Error starting deployment - $result - $($_.Exception)" -ErrorAction Stop
}

Write-Progress -Activity "Deploying Resources ($deploymentName)..."
Start-Sleep 10
$job = Get-Job -Id $job.Id
while ($job.state -eq 'Running') {
    Start-Sleep 10
    $operation = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $DestinationResourceGroupName -DeploymentName $deploymentName -ErrorAction 'Stop'
    $working = $operation.Properties | Where-Object {$_.provisioningState -ne 'Succeeded'}

    Write-Progress -Activity "Deploying Resources ($deploymentName)..." -Status "Working on $($working.targetResource.resourceName -join ', ')"

    $job = Get-Job -Id $job.Id
}

if ($job.state -eq 'Failed') {
    $job.error.exception | Write-Error
    Write-Output "Failed creating deployment job ($deploymentName) Failed"
    return
}

# get deployment status & any failures
$deployment = Get-AzResourceGroupDeployment -ResourceGroupName $DestinationResourceGroupName -DeploymentName $deploymentName

$failedOperations = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $DestinationResourceGroupName -DeploymentName $deploymentName  | Where-Object { $_.Properties.ProvisioningState -ne 'Succeeded' }
if ($failedOperations) {
    $errorMsg = $null
    foreach ($failedOperation in $failedOperations) {
        $targetResourceName = $($failedOperation.properties.targetResource.Id -split '/')[-1]
        $errorMsg += "$($targetResourceName) - $($failedOperation.properties.statusMessage.error.message)`n"
    }
    Write-Error $errorMsg
}

$elapsedTime = $(Get-Date) - $startTime
$totalTime = "{0:HH:mm:ss}" -f ([datetime] $elapsedTime.Ticks)
Write-Output "Deployment ($deploymentName) $($deployment.ProvisioningState). ($totalTime elapsed)"
