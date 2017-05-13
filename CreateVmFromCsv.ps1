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

try {
    $csvFile = Import-Csv $Filename
}
catch {
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

# loop through all Vnets
$existingVms = Get-AzureRmVM

foreach ($vmConfig in $csvFile) {
    if ($vmConfig.vmName -in $existingVms.Name) {
        Write-Verbose "$($vmConfig.vmName) already exists, skipped."
        continue
    }

    $createPublicIP = $False
    if ($vmConfig.CreatePublicIp -eq 'Y') {
        $createPublicIP = $True
    }

    if ($vmConfig.osDiskName -eq '') { $vmConfig.osDiskname = $null }


    $vmResource = New-PsArmQuickVm -VmName $vmConfig.VmName `
            -VNetName $vmConfig.VnetName `
            -SubnetName $vmConfig.SubnetName `
            -osType $vmConfig.OSType `
            -vmSize  $vmConfig.VmSize `
            -StorageAccountResourceGroupName $vmConfig.StorageAccountResourceGroupName `
            -StorageAccountName $vmConfig.StorageAccountName `
            -osDiskName $vmConfig.osDiskName `
            -DataDiskStorageAccountName $vmConfig.DataDiskStorageAccountName `
            -DataDiskSize $vmConfig.DataDiskSize `
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