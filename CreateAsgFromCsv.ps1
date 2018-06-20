<#
.SYNOPSIS

Create Application Security Groups from a CSV file
.DESCRIPTION

This Powershell command takes a CSV file with a list of Application Security Groups and associated Virtual Machines, creates the Application Security Groups and associates all the NIC cards tied to the virtual machine and puts them into the Application Security Group.

Before executing this script, make sure you have logged into Azure (using Login-AzureRmAccount) and have the Subscription you wish to deploy to in context (using Select-AzureRmSubscription).
.PARAMETER Filename

Name of file containing Application Security Group configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Virtual Network in
.PARAMETER Location

Location for the Application Security Group
.PARAMETER Test

Provide this parameter if you only want to test the created template, without deploying it.
.EXAMPLE

.\CreateAsgFromCsv.ps1 .\sample\SampleAsg.csv
#>
[CmdletBinding()]

Param(
    [parameter(Mandatory=$True)]
    [string] $Filename
)

Class MapProperties {
    [string] $ResourceGroupName
    [string] $AsgName
    [string] $Id
    [string] $Location
    [string] $VmName
    [string] $NicId
}


# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (! $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login and set the proper subscription context before proceeding."
    exit
}

try {
    $csvFile = Import-Csv $Filename
} catch {
    throw
    return
}

Write-Verbose "Inspecting $Filename"

# get all VMs
$vms = Get-AzureRmVm | Where-Object {$_.Name -in $csvFile.VmName}
if ($vms.count -ne $csvFile.count) {
    foreach ($vmName in $csvFile.VmName) {
        if ($vmName -notin $vms.Name) {
            Write-Output "VM $vmName not found."
        }
    }
}

# build mapping of all asg, nic and location
$mapList = @()
foreach ($assignment in $csvFile) {
    $vm = $vms | Where-Object {$_.Name -eq $assignment.VmName}
    if ($vm) {
        $map = [MapProperties]::New()
        $map.ResourceGroupName = $assignment.ResourceGroupName
        $map.AsgName           = $assignment.AsgName
        $map.VmName            = $vm.Name
        $map.Location          = $vm.Location

        # create separate entry per NIC
        foreach ($nicId in $vm.NetworkProfile.NetworkInterfaces) {
            $map.NicId = [string] $nicId.Id
            $mapList += $map
        }
    }
}

# make sure all Location are consistent (or blank) across the entire Application Security Group
$distinctAsgs = $mapList |
    Select-Object -Property ResourceGroupName, AsgName, Location -Unique |
    Sort-Object
$asgCount = $distinctAsgs |
    Select-Object -Property AsgName -Unique |
    Measure-Object
if ($asgCount.count -ne $($distinctAsgs | Measure-Object).Count) {
    $distinctAsgs | Format-Table
    throw "ASG properties and/or members are inconsistent. Please check ResourceGroupName and ASG Names for consistency. Please ensure all VMs in each ASG are in the same location."
    return
}

# create any missing ResourceGroups
Write-Output 'Creating new ResourceGroups...'
$existingResourceGroups = Get-AzureRmResourceGroup
$mapList |
    Where-Object {$_.ResourceGroupName -notin $existingResourceGroups.ResourceGroupName} |
    Select-Object -Property ResourceGroupName, Location -Unique |
    Foreach-Object {
        $resourceGroup = New-AzureRmResourceGroup -ResourceGroupName $_.ResourceGroupName -Location $_.Location
        Write-Output "$($resourceGroup.ResourceGroupName) created"
    }

# create any missing ASGs
Write-Output 'Creating new ASGs...'
$existingAsgs = Get-AzureRmResource -ResourceType 'Microsoft.Network/applicationSecurityGroups'
$distinctAsgs | Where-Object {$_.AsgName -notin $existingAsgs.Name} | Foreach-Object {
    $asg = New-AzureRmApplicationSecurityGroup -ResourceGroupName $_.ResourceGroupName -Name $_.AsgName -Location $_.Location
    Write-Output "$($asg.Name) created"
}

# associate Id with MapList
$asgs = Get-AzureRmApplicationSecurityGroup # -- piping to Where-object didn't work
$asgs = $asgs | Where-Object {$_.Name -in $mapList.AsgName}
foreach ($map in $mapList) {
    $map.Id = $($asgs | Where-Object {$_.Name -eq $map.AsgName}).Id
}

# set ASG on each NIC
Write-Verbose 'Updating VMs...'
$distinctNicIds = $($mapList | Select-Object -Property nicId -Unique).nicId
foreach ($nicId in $distinctNicIds) {
    $nicIdParts = $nicId.Split('/')
    $nic = Get-AzureRmNetworkInterface -ResourceGroupName $nicIdParts[4] -Name $nicIdParts[8]

    $asgForNic = $mapList | Where-Object {$_.NicId -eq $nicId} | Select-Object -Property Id
    $nic.IpConfigurations[0].ApplicationSecurityGroups = $asgForNic
    $nic = Set-AzureRmNetworkInterface -NetworkInterface $nic
    Write-Output "$($nic.VirtualMachine.Id.Split('/')[8]) updated"
}

Write-Output "Done."