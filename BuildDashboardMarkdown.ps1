<#
.SYNOPSIS
Merge an Azure dashboard with content from Powershell commands. 

.DESCRIPTION
This Powershell command will render the dynamic contents of an Azure dashboard template embedded with
special HTML comments containing Powershell commands. It is intended to create dashboard that are
updated with data on a periodic basis. These embedded commands are contained within the Markdown text 
using HTML comments.

.PARAMETER DashboardTemplateFile
Path of file containing the dashboard with Markdown parts. A sample file can be found in ./sample/SampleDashboardTemplate.json

.PARAMETER ConfigFile
Path of JSON file containing configuration settings using in rendering content. These settings will be
exposed in public variable $config.

.PARAMETER OutputFile
Path of optional output file. If specified, this file will contain the JSON definition of the Azure dashboard resource.
This output can be incorporated into an Azure ARM template for deployment.

.PARAMETER DeployTemplate
If specified, the dashboard output will be deployed to Azure. Please ensure that you are logged in and 
context has been set to the proper subscription if executing this command.

.PARAMETER ResourceGroupName
If -DeployTemplate is specified, -ResourceGroupName needs to be specified for the deployment

.EXAMPLE
.\BuildDashboardMarkdown.ps1 -DashboardTemplateFile <DashboardArmTemplate> -ConfigFile <ConfigFile>
#>

Param (
    [Parameter(Mandatory = $true)]
    [string] $DashboardTemplateFile,

    [Parameter(Mandatory = $false)]
    [string] $ConfigFile,

    [Parameter(Mandatory = $false)]
    [string] $OutputFile,

    [Parameter(Mandatory = $false)]
    [boolean] $DeployTemplate,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName
)

# load needed assemblies
Import-Module SqlServer

#################################################
function MonthBegin
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        $Date
    )

    if (-not $Date) {
        $Date = Get-Date
    }

    return (Get-Date -Year $($Date.Year) -Month $($Date.Month) -Day 1 -Hour 0 -Minute 0 -Second 0)
}

#################################################
function MonthEnd
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        $Date
    )

    if (-not $Date) {
        $Date = Get-Date
    }

    return (MonthBegin -Date $Date).AddMonths(1).AddSeconds(-1)
}

#################################################
function QuarterBegin
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        $Date
    )

    if (-not $Date) {
        $Date = Get-Date
    }

    $month = $Date.Month
    $month = [System.Math]::Floor(($month-1)/3)*3+1
    
    return (MonthBegin -Date $(Get-Date -Year $Date.Year -Month $month -Day 1) )
}

#################################################
function QuarterEnd
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        $Date
    )

    if (-not $Date) {
        $Date = Get-Date
    }

    return (QuarterBegin -Date $Date).AddMonths(3).AddSeconds(-1)
}

#################################################
function FormatMarkdownTable 
{
    <#
        .SYNOPSIS
            Format an array of data elements returned from an Invoke-SQLCmd into a markdown table

        .EXAMPLE
            Invoke-SQLCmd ... | FormatMarkdownTable -TableHeader "|-|-|-|-:|-:|-:|"
    #>
    Param (
        [Parameter(ValueFromPipeline=$true)]
        $Data,

        [Parameter(Mandatory=$False)]
        [string] $TableHeader
    )

    # assign data from pipeline
    $Data = $input

    # return if data is empty
    if (-not $Data) {
        return "\n"
    }

    # create standard header, if one is not provided
    if (-not $TableHeader) {
        $TableHeader = "|" + ("-|" * $Data[0].Table.Columns.ColumnName.Length)
    }

    # create markdown table header
    $markdown = "|" + $($Data[0].Table.Columns.ColumnName -Join '|') + "|`n"
    $markdown += $TableHeader + "`n"

    # render data in markdown rows
    foreach ($row in $Data) {
        $markdown += "|" + $($row.ItemArray -Join '|') + "|`n"
    }
    
    return $markdown
}

#################################################
function EvaluateContent
{
    <#
        .SYNOPSIS
            Execute Powershell statements inside of content and merge in output.

            The content should contain Powershell statements contained within HTML comment tags <!-- -->. 
            The statements will be evaluated and rendered in place of the HTML comment. For example:

                Hello, today is <!-- Get-Date -->

            returns "Hello, today is Wednesday, January 1, 2020 9:00:00 AM "

        .EXAMPLE
            EvaluateContent <content>
    #>

    Param (
        [Parameter(Mandatory=$true)]
        [string] $Content
    )

    $startToken = '<!-- '
    $endToken = ' -->'  

    # loop through multiple table definitions
    do {
        $cmdStart = $Content.IndexOf($startToken)
        if ($cmdStart -eq -1) {
            return $Content
        }

        $cmdEnd = $Content.IndexOf($endToken)
        if ($cmdEnd -eq -1) {
            Write-Error "Powershell statement not propertly closed - $Content"
            return $Content
        }

        $beforeStr = $Content.Substring(0, $cmdStart) 
        $afterStr = $Content.Substring($cmdEnd+$endToken.Length)
        $powershellCmd = $Content.Substring($cmdStart+$startToken.Length,$cmdEnd-$cmdStart-$startToken.Length)

        Write-Verbose "executing command: $powershellCmd"
        $results = $(Invoke-Expression $powershellCmd)
        $Content = $beforeStr + $results + $afterStr
    } while (1 -eq 1)

}

#################################################
# MAIN 

# check parameters
$dashboard = Get-Content $DashboardTemplateFile | ConvertFrom-Json

if ($ConfigFile) {
    $config = Get-Content $ConfigFile | ConvertFrom-Json
}

if ($DeployTemplate) {
    if (-not $ResourceGroupName) {
        Write-Error "ResourceGroupName must be specified when -DeployTemplate is specified"
    }

    $deploymentFilePath = $env:TEMP + "/BuildDashboardMarkdown_" + $ResourceGroupName + ".json"
}

# loop through all dashboard components
$i = 0
while ($widget = $dashboard.properties.lenses."0".parts."$i") {
    if ($widget.metadata.type -eq "Extension/HubsExtension/PartType/MarkdownPart") {
        # execute Powershell inside Markdown parts
        if ($widget.metadata.settings.content.settings.title) {
            $widget.metadata.settings.content.settings.title = EvaluateContent -Content $widget.metadata.settings.content.settings.title 
        }

        if ($widget.metadata.settings.content.settings.subtitle) {
            $widget.metadata.settings.content.settings.subtitle = EvaluateContent -Content $widget.metadata.settings.content.settings.subtitle 
        }

        if ($widget.metadata.settings.content.settings.content) {
            $widget.metadata.settings.content.settings.content = EvaluateContent -Content $widget.metadata.settings.content.settings.content
        }
    }
    $i++
}

if ($DeployTemplate) {
    # set fields that default incorrectly in downloaded dashboard template
    $resourceGroup = Get-AzResourceGroup -ResourceGroupName $ResourceGroupName
    $dashboard.location = $resourceGroup.location
    $dashboard.name = $dashboard.name -replace '[^a-zA-Z0-9\-]', ''

    '{ "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#", "contentVersion": "1.0.0.0","resources": [' + $( $dashboard | ConvertTo-Json -Depth 100 ) + ']}' | Out-File $deploymentFilePath
    New-AzResourceGroupDeployment -ResourceGroupName test-dashboard -TemplateFile $deploymentFilePath

} else {
    if (-not $OutputFile) {
        $dashboard | ConvertTo-Json -Depth 100 
    } else {
        $dashboard | ConvertTo-Json -Depth 100 | Out-File $OutputFile
    }
}

