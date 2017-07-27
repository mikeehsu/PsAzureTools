<#
.SYNOPSIS

Create route table and associated routes from a CSV file
.DESCRIPTION

This Powershell command takes a CSV file with a list of Route Table and Route configurations and executes a ARM deployment to create them.

Existing Route Tables listed in the CSV file will be altered to match the routes in the CSV file.

Before executing this script, make sure you have logged into Azure (using Login-AzureRmAccount) and have the Subscription you wish to deploy to in context (using Select-AzureRmSubscription).
.PARAMETER Filename

Name of file containing Route Table configuration
.PARAMETER ResourceGroupname

Name of ResourceGroup to build the Route Tables in
.PARAMETER Location

Location for the ResourceGroup
.PARAMETER TemplateFile

Destination for the ARM Template file that is created. This is an optional parameter. Provide this parameter if you want the created template saved to a specific destination.
.PARAMETER Test

Provide this parameter if you only want to test the created template, without deploying it.
.EXAMPLE

.\CreateRouteTableFromCsv.ps1 .\sample\SampleRouteTable.csv -ResourceGroupName 'RG-Test' -Location 'EastUS'
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
} catch {
    throw
    return
}

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


Write-Verbose "Inspecting $Filename"

# make sure all RouteTableName & Location are consistent (or blank) across the entire RouteTable
$distinctRouteTables = $csvFile |
    Where-Object {$_.Location -ne '' } |
    Select-Object -Property RouteTableName, Location -Unique |
    Sort
$routeTableCount = $csvFile |
    Where-Object {$_.Location -ne ''} |
    Select-Object -Property RouteTableName -Unique |
    Measure-Object
if ($routeTableCount.count -ne $($distinctRouteTables | Measure-Object).Count) {
    $distinctRouteTables | Format-Table
    throw "RouteTable properties are inconsistent. Please check RouteTableName and Location"
    return
}

Write-Verbose "Initial inspection passed"

# set deployment info
$deploymentName = $resourceGroupName + $(get-date -f yyyyMMddHHmmss)
$deploymentFile = $env:TEMP + '\'+ $deploymentName + '.json'
if ($TemplateFile) {
    $deploymentFile = $TemplateFile
}


# start building the template resources
$template = New-PsArmTemplate

# loop through all Vnets
foreach ($routeTable in $distinctRouteTables) {

    $routeTableResource = New-PsArmRouteTable -Name $routeTable.RouteTableName -Location $routeTable.Location

    # loop through all rules
    $routes = $csvFile | Where-Object {$_.RouteTableName -eq $routeTable.RouteTableName} | Sort
    foreach ($route in $routes) {
        $routeTableResource = $routeTableResource |
             Add-PsArmRoute -Name $route.RouteName `
                -AddressPrefix $route.AddressPrefix `
                -NextHopType $route.NextHopType `
                -NextHopIpAddress $route.NextHopAddress
    }

    $template.resources += $routeTableResource

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

Write-Output "Route Tables created successfully."
return
