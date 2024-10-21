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

    [parameter()]
    [switch] $Create
)

Set-StrictMode -Version 2.0

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (! $result.Environment) {
        Write-Error "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
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

# make sure all RouteTableName & Location are consistent (or blank) across the entire RouteTable
$distinctRouteTables = $csvFile |
    Where-Object {$_.Location -ne '' } |
    Select-Object -Property RouteTableName, Location -Unique |
    Sort-Object
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

# check for existing resources
$resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
if (-not $resourceGroup) {
    throw "ResourceGroup $ResourceGroupName not found. Please create and try again."
    return
}

# make sure all RouteTables exist or created
foreach ($routeTableDefinition in $distinctRouteTables) {
    Write-Verbose "Working on $($routeTableDefinition.RouteTableName)"

    try {
        $routeTable = Get-AzRouteTable -ResourceGroupName $ResourceGroupName -Name $routeTableDefinition.RouteTableName -ErrorAction SilentlyContinue
        if (-not $routeTable -and -not $Create) {
            throw "RouteTable $($routeTableDefinition.RouteTableName) not found in $ResourceGroupName. Please use -Create switch to create a new Route Table."
            return
        }
    } catch {
        throw $_
        return
    }

    # if routetable doesn't exist, create it
    if (-not $routeTable) {
        Write-Verbose "Creating $($routeTableDefinition.RouteTableName)"
        $routeTable = New-AzRouteTable -ResourceGroupName $ResourceGroupName -Name $routeTableDefinition.RouteTableName -Location $routeTableDefinition.Location
    }

    # recreate routes
    $routeTable.Routes = @()
    $routes = $csvFile | Where-Object {$_.RouteTableName -eq $routeTableDefinition.RouteTableName} | Sort-Object -Property Route
    foreach ($route in $routes) {
        $params = @{
            Name = $route.RouteName
            RouteTable = $routeTable
            AddressPrefix = $route.AddressPrefix
            NextHopType = $route.NextHopType
            NextHopIpAddress = $route.NextHopAddress
        }

        $routeTable = Add-AzRouteConfig @params
    }

    # update routeTable
    $routeTable = Set-AzRouteTable -RouteTable $routeTable
}
