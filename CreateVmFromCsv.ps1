<#
.SYNOPSIS

Create Virtual Machines from a CSV file
.DESCRIPTION

This Powershell command takes a CSV file with a list of Virtual Machine configurations and executes a ARM deployment to create them.

Existing Virtual Machines listed in the CSV file will NOT be updated.

Before executing this script, make sure you have logged into Azure (using Login-AzureRmAccount) and have the Subscription you wish to deploy to in context (using Select-AzureRmSubscription).
.PARAMETER Filename

Name of file containing Virtual Machine configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Virtual Machine in
.PARAMETER Location

Location for the ResourceGroup
.PARAMETER TemplateFile

Destination for the ARM Template file that is created. This is an optional parameter. Provide this parameter if you want the created template saved to a specific destination.
.PARAMETER Test

Provide this parameter if you only want to test the created template, without deploying it.
.EXAMPLE

.\CreateVmFromCsv.ps1 .\sample\SampleVm.csv -ResourceGroupName 'RG-Test' -Location 'EastUS'
#>
[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $Filename,

    [parameter(Mandatory=$True)]
    [string] $ResourceGroupName,

    [parameter(Mandatory=$True)]
    [string] $Location,

    [parameter(Mandatory=$False)]
    [string] $TemplateFile,

    [parameter(Mandatory=$False)]
    [switch] $Test
)

Import-Module -Force PsArmResources
Set-StrictMode -Version 2.0

# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (! $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login and set the proper subscription context before proceeding."
    exit;
}

try {
    $csvFile = Import-Csv $Filename
} catch {
    throw
    return
}

# set deployment info
$deploymentName = $resourceGroupName + $(get-date -f yyyyMMddHHmmss)
$deploymentFile = $env:TEMP + '\'+ $deploymentName + '.json'
if ($TemplateFile) {
    $deploymentFile = $TemplateFile
}


# start building the template resources
$template = New-PsArmTemplate

# loop through all availability sets
$distinctAVsets = $csvFile |
    Where-Object {$_.AvailabilitySetName -ne ''} |
    Select-Object -Property AvailabilitySetName -Unique |
    Sort-Object
foreach ($avSet in $distinctAVsets) {
    $resource = New-PsArmAvailabilitySet -Name $avSet.AvailabilitySetName -Location $Location

    $template.resources += $resource
}

# load existing VMs
$existingVms = Get-AzureRmVM

# loop through all VMs
foreach ($vmConfig in $csvFile) {

    if ($vmConfig.vmName -in $existingVms.Name) {
        Write-Verbose "$($vmConfig.vmName) already exists, skipped."
        continue
    }

    # set all columns not provided to $null
    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "StorageAccountResourceGroupName")) {
        $vmConfig | Add-Member @{StorageAccountResourceGroupName = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "StorageAccountName")) {
        $vmConfig | Add-Member @{StorageAccountName = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "VhdImageName")) {
        $vmConfig | Add-Member @{VhdImageName = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "osDiskName")) {
        $vmConfig | Add-Member @{osDiskName = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "OSDiskUri")) {
        $vmConfig | Add-Member @{OSDiskUri = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "DataDiskStorageAccountName")) {
        $vmConfig | Add-Member @{DataDiskStorageAccountName = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "DataDiskSize")) {
        $vmConfig | Add-Member @{DataDiskSize = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "DataDiskUri")) {
        $vmConfig | Add-Member @{DataDiskUri = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "StaticIPAddress")) {
        $vmConfig | Add-Member @{StaticIPAddress = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "CreatePublicIp")) {
        $vmConfig | Add-Member @{CreatePublicIp = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "Publisher")) {
        $vmConfig | Add-Member @{Publisher = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "Offer")) {
        $vmConfig | Add-Member @{Offer = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "Sku")) {
        $vmConfig | Add-Member @{Sku = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "AvailabilitySetName")) {
        $vmConfig | Add-Member @{AvailabilitySetName = $null}
    }

    if (-not [bool] ($vmConfig.PSobject.Properties.name -eq "NetworkSecurityGroupName")) {
        $vmConfig | Add-Member @{NetworkSecurityGroupName = $null}
    }


    # set default values for blank columns
    $createPublicIP = $False
    if ($vmConfig.CreatePublicIp -eq 'Y') {
        $createPublicIP = $True
    }

    if ([string]::IsNullOrEmpty($vmConfig.osDiskName)) { $vmConfig.osDiskname = $null }

    if ([string]::IsNullOrEmpty($vmConfig.DataDiskUri)) {
        $vmConfig.DataDiskUri = $null
    } else {
        $vmConfig.DataDiskUri= $vmConfig.DataDiskUri.split('|')
    }

    $vmResource = New-PsArmQuickVm -VmName $vmConfig.VmName `
            -VNetName $vmConfig.VnetName `
            -SubnetName $vmConfig.SubnetName `
            -osType $vmConfig.OSType `
            -vmSize  $vmConfig.VmSize `
            -StorageAccountResourceGroupName $vmConfig.StorageAccountResourceGroupName `
            -StorageAccountName $vmConfig.StorageAccountName `
            -osDiskName $vmConfig.OsDiskName `
            -OsDiskUri $vmConfig.OsDiskUri `
            -DataDiskStorageAccountName $vmConfig.DataDiskStorageAccountName `
            -DataDiskSize $vmConfig.DataDiskSize `
            -DataDiskUri $vmConfig.DataDiskUri `
            -StaticIPAddress $vmConfig.StaticIPAddress `
            -CreatePublicIp $createPublicIP `
            -Publisher $vmConfig.Publisher `
            -Offer $vmConfig.Offer `
            -Sku $vmConfig.Sku `
            -AvailabilitySetName $vmConfig.AvailabilitySetName `
            -NetworkSecurityGroupName $vmConfig.NetworkSecurityGroupName

     $template.resources += $vmResource
}

# save template locally
Save-PsArmTemplate -Template $template -TemplateFile $deploymentFile

# execute a test deployment
if ($Test) {
    try {
        Test-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $deploymentFile -Verbose
    } catch {
        throw
        return
    }

    Write-Output "Test completed successfully."
    return
}

# deploy the template
try {
    Write-Verbose "Deploying template $deploymentFile"
    New-AzureRmResourceGroup -Name $ResourceGroupName -Location $Location -Force
    New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $deploymentFile -Verbose
} catch {
    throw
    return
}

Write-Output "Network Security Groups created successfully."
return