<#
.SYNOPSIS

Create Vnets and Subnets from a CSV file
.DESCRIPTION

This Powershell command takes a CSV file with a list of Virtual Networks and Subnet configurations and executes a ARM deployment to create them.

Existing Virtual Networks listed in the CSV file will be altered to match the subnet settings in the CSV file.

Before executing this script, make sure you have logged into Azure (using Login-AzureRmAccount) and have the Subscription you wish to deploy to in context (using Select-AzureRmSubscription).
.PARAMETER Filename

Name of file containing Virtual Network configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Virtual Network in
.PARAMETER Location

Location for the ResourceGroup
.PARAMETER TemplateFile

Destination for the ARM Template file that is created. This is an optional parameter. Provide this parameter if you want the created template saved to a specific destination.
.PARAMETER Test

Provide this parameter if you only want to test the created template, without deploying it.
.EXAMPLE

.\CreateVnetFromCsv.ps1 .\sample\SampleVnet.csv -ResourceGroupName 'RG-Test' -Location 'EastUS'
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

Write-Verbose "Inspecting $Filename"

# make sure all VnetAddressPrefix & Location are consistent (or blank) across the entire VnetName
$distinctVnets = $csvFile |
    Where-Object {$_.Location -ne '' -or $_.VnetAddressPrefix -ne ''} |
    Select-Object -Property VnetName, Location, VnetAddressPrefix -Unique |
    Sort-Object
$vnetCount = $csvFile |
    Where-Object {$_.Location -ne '' -or $_.VnetAddressPrefix -ne ''} |
    Select-Object -Property VnetName -Unique |
    Measure-Object
if ($vnetCount.count -ne $($distinctVnets | Measure-Object).Count) {
    $distinctVnets | Format-Table
    throw "Vnet properties are inconsistent. Please check VnetName, Location and/or VnetAddressPrefix"
    return
}

Write-Verbose "Inspection passed"

# set deployment info
$deploymentName = $resourceGroupName + $(get-date -f yyyyMMddHHmmss)
$deploymentFile = $env:TEMP + '\'+ $deploymentName + '.json'
if ($TemplateFile) {
    $deploymentFile = $TemplateFile
}


# start building the template resources
$template = New-PsArmTemplate

# loop through all Vnets
foreach ($vnet in $distinctVnets) {

    $vnetResource = New-PsArmVnet -Name $vnet.VnetName -AddressPrefixes $vnet.VnetAddressPrefix -Location $vnet.Location

    # loop through all subnets
    $subnets = $csvFile | Where-Object {$_.VnetName -eq $vnet.VnetName} | Sort-Object
    foreach ($subnet in $subnets) {
        $vnetResource = $vnetResource |
             Add-PsArmVnetSubnet -Name $subnet.SubnetName -AddressPrefix $subnet.SubnetAddressPrefix
    }

    $template.resources += $vnetResource

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
    New-AzureRmResourceGroup -Name $ResourceGroupName -Location $Location -Force
    New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $deploymentFile -Verbose
} catch {
    throw
    return
}

Write-Output "Network Security Groups created successfully."
return