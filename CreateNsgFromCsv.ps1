<#
.SYNOPSIS

Create or update a RouteTable with IP addressed necessary to reach services on the public internet
.DESCRIPTION

This Powershell command takes an XML file with a list of IP addresses to be whitelisted and creates a RouteTable for a specified region. Additionally, it can associate the RouteTable with the necessary subnets.

The list of Azure IP addresses can be found at: https://www.microsoft.com/en-us/download/details.aspx?id=41653

.PARAMETER Filename

Name of file containing Network Security Group configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Network Security Group in
.PARAMETER Location

Location for the ResourceGroup
.EXAMPLE

.\CreateNsgFromCsv.ps1 .\sample\SampleNsg.csv -ResourceGroupName 'RG-Test' -Location 'EastUS'
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

# make sure all VnetAddressPrefix & Location are consistent (or blank) across the entire VnetName
$distinctNsgs = $csvFile | 
    Where-Object {$_.Location -ne '' } | 
    Select-Object -Property NsgName, Location -Unique | 
    Sort
$nsgCount = $csvFile | 
    Where-Object {$_.Location -ne ''} | 
    Select-Object -Property NsgName -Unique |
    Measure-Object
if ($nsgCount.count -ne $($distinctNsgs | Measure-Object).Count) {
    $distinctNsgs | Format-Table
    throw "Nsg properties are inconsistent. Please check Nsg and Location"
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
foreach ($nsg in $distinctNsgs) {

    $nsgResource = New-PsArmNetworkSecurityGroup -Name $nsg.NsgName -Location $nsg.Location

    # loop through all rules
    $rules = $csvFile | Where-Object {$_.NsgName -eq $nsg.NsgName} | Sort
    foreach ($rule in $rules) {

        $rule

        $nsgResource = $nsgResource |
             Add-PsArmNetworkSecurityGroupRule -Name $rule.RuleName `
                -Priority $rule.Priority `
                -Access $rule.Access `
                -Direction $rule.Direction `
                -Protocol $rule.Protocol `
                -SourceAddressPrefix $rule.SourceAddressPrefix `
                -SourcePortRange $rule.SourcePortRange `
                -DestinationAddressPrefix $rule.DestinationAddressPrefix `
                -DestinationPortRange $rule.DestinationPortRange
    }

    $template.resources += $nsgResource

}

Save-PsArmTemplate -Template $template -TemplateFile $deploymentFile

if ($TemplateOnly) {
    return
}

# deploy the template
New-AzureRmResourceGroup -Name $ResourceGroupName -Location $Location -Force
New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $deploymentFile -Verbose

return
