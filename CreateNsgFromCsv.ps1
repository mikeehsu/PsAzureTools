<#
.SYNOPSIS

Create Network Security Groups and associated rules from a CSV file
.DESCRIPTION

This Powershell command takes a CSV file with a list of Network Security Groups and Rules configurations and executes a ARM deployment to create them.

Existing Network Security Groups listed in the CSV file will be altered to match the rules in the CSV file.

Before executing this script, make sure you have logged into Azure (using Login-AzureRmAccount) and have the Subscription you wish to deploy to in context (using Select-AzureRmSubscription).
.PARAMETER Filename

Name of file containing Network Security Group configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Network Security Group in
.PARAMETER Location

Location for the ResourceGroup
.PARAMETER TemplateFile

Destination for the ARM Template file that is created. This is an optional parameter. Provide this parameter if you want the created template saved to a specific destination.
.PARAMETER Test

Provide this parameter if you only want to test the created template, without deploying it.
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
$distinctNsgs = $csvFile |
    Where-Object {$_.Location -ne '' } |
    Select-Object -Property NsgName, Location -Unique |
    Sort-Object
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
$deploymentName = $resourceGroupName + $(get-date -f yyyyMMddHHmmss)
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

# save the template locally
Save-PsArmTemplate -Template $template -TemplateFile $deploymentFile

# perform a test deployment
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

Write-Output "Virtual Networks created successfully."
return
