##############################
#.SYNOPSIS
# Copy the tags at the Resource Group level to the individual resources
# within the resource group.
#
#.DESCRIPTION
# Copy the tags from the Resource Group down to the individual resources.
# By default, only tags that do not exist in the individual resource will
# be created, any existing tags in the individuial resource will keep
# their current values, additional tags at the individual resource will
# not be deleted.
#
#.PARAMETER ResourceGroupName
# If this parameter is provided, it will limit the copying of tags
# to just the resource group indicated
#
#.PARAMETER Replace
# If this parameter is specified, the tags from the Resource Group will
# replace ALL tags in the individual resource. Any existing tags on
# the individual resource will be delete.
#
#.PARAMETER Overwrite
# If this parameter is specified, the tags from the Resource Group will
# replace ALL tags in the individual resource
#
#
#.EXAMPLE
# CopyTagsToResources.ps1
#
#.NOTES
#
##############################

[CmdletBinding()]

Param (
    [parameter(Mandatory=$False)]
    [string] $ResourceGroupName,

    [parameter(Mandatory=$False)]
    [switch] $Replace,

    [parameter(Mandatory=$False)]
    [switch] $Overwrite
)


# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
        exit
    }
    $azureEnvironmentName = $result.Environment.Name

} catch {
    Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription (Select-AzureRmSubscription) context before proceeding."
    exit
}

$params = @{}
if ($ResourceGroupName) {
    $params += @{
        ResourceGroupName = $ResourceGroupName
    }
} else {
}
$resourceGroups = Get-AzureRmResourceGroup @params

if (-not $resourceGroups) {
    Write-Error "No resource groups found."
    exit
}

Write-Verbose "$($resourceGroups.Length) resource groups found"
foreach ($resourceGroup in $resourceGroups) {
    if (-not $resourceGroup.Tags) {
        Write-Output "$($resourceGroup.ResourceGroupName), Resource Group has no tags"
        continue
    }

    $resources = Get-AzureRmResource |
        Where-Object {$_.ResourceGroupName -eq $resourceGroup.ResourceGroupName}
    foreach ($resource in $resources) {
        $tags = $resource.Tags
        $needUpdate = $False

        if (-not $tags -or $ReplaceTags)  {
            # resource tags do not exists -or- ReplaceTags parameter set
            Write-Verbose "$($resource.Name)...replacing tags"

            $diff = Compare-Object $(ConvertTo-Json $tags) $(ConvertTo-Json $resourceGroup.Tags)
            if ($diff) {
                $tags = $resourceGroup.Tags
                $needUpdate = $True
            }

        } else {
            # check & sync resource tags & values
            Write-Verbose "$($resource.Name)...syncing tags"

            $resourceGroup.Tags.GetEnumerator() | foreach-object {
                if ($Overwrite) {
                    if ($tags[$_.Name] -ne $_.Value) {
                        $tags[$_.Name] = $_.Value
                        $needUpdate = $True
                    }
                } else {
                    if (-not $tags[$_.Name]) {
                        $tags[$_.Name] = $_.Value
                        $needUpdate = $True
                    }
                }
            }
        }

        if ($needUpdate) {
            Write-Verbose "$($resource.Name)...saving updates to tags"
            $result = Set-AzureRmResource -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -ResourceType $resource.ResourceType -Tag $tags -Force
            if (-not $result) {
                Write-Error "$($resource.Name), unable to update."
            } else {
                Write-Output "$($resource.Name) updated."
            }

        }
    }
}
