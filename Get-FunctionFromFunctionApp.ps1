<#
.SYNOPSIS
Retrieves functions from a specified Azure Function App.

.DESCRIPTION
The `Get-FunctionFromFunctionApp` function retrieves functions from a specified Azure Function App.

.PARAMETER ResourceGroupName
The name of the Azure Resource Group that contains the Function App. This parameter is mandatory.

.PARAMETER Name
The name of the Azure Function App. This parameter is mandatory.

.EXAMPLE
Get-FunctionFromFunctionApp -ResourceGroupName "myResourceGroup" -Name "myFunctionApp"
Retrieves the functions from the Azure Function App named "myFunctionApp" in the resource group "myResourceGroup".

.NOTES
This function relies on the `Get-AzResource` cmdlet to query the Azure Resource Manager API. Make sure the Azure PowerShell module is installed and authenticated before using this function.
#>
function Get-FunctionFromFunctionApp
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory=$true, ValueFromPipelineByPropertyName=$true)]
        [string] $Name
    )

    begin {
    }

    process {
        $functions = Get-AzResource -ResourceGroupName $ResourceGroupName -Name $Name -ResourceType "Microsoft.Web/sites/functions/" -ExpandProperties -ApiVersion "2022-03-01"
        return $functions
    }

    end {
    }

}
