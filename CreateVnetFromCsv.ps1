<#
.SYNOPSIS

Create or update a RouteTable with IP addressed necessary to reach services on the public internet
.DESCRIPTION

This Powershell command takes an XML file with a list of IP addresses to be whitelisted and creates a RouteTable for a specified region. Additionally, it can associate the RouteTable with the necessary subnets.

The list of Azure IP addresses can be found at: https://www.microsoft.com/en-us/download/details.aspx?id=41653

.PARAMETER Filename

Name of file containing Virtual Network configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Virtual Network in
.PARAMETER Location

Location for the ResourceGroup
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
    [switch] $TemplateOnly
)

try {
    $csvFile = Import-Csv $Filename
}
catch {
    throw
    return
}

Set-StrictMode -Version 2.0

Write-Verbose "Inspecting $Filename"

# make sure all VnetAddressPrefix & Location are consistent across the entire VnetName
$distinctVnets = $csvFile | 
    Where-Object {$_.Location -ne '' -or $_.VnetAddressPrefix -ne ''} | 
    Select-Object -Property VnetName, Location, VnetAddressPrefix -Unique | 
    Sort
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
$deploymentName = $resourceGroupName + $(get-date -f yyyyMMddHHMMss)
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
    $subnets = $csvFile | Where-Object {$_.VnetName -eq $vnet.VnetName} | Sort
    foreach ($subnet in $subnets) {
        $vnetResource = $vnetResource |
             Add-PsArmVnetSubnet -Name $subnet.SubnetName -AddressPrefix $subnet.SubnetAddressPrefix
    }

    $template.resources += $vnetResource

}

Save-PsArmTemplate -Template $template -TemplateFile $deploymentFile

if ($TemplateOnly) {
    return
}

# deploy the template
New-AzureRmResourceGroup -Name $ResourceGroupName -Location $Location -Force
New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $deploymentFile -Verbose

return
