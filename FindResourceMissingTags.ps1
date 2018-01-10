##############################
#.SYNOPSIS
# Find resources which are missing required tags
#
#.DESCRIPTION
# Find resources which are missing tags and list them
# optionally displaying a URL to directly modify the tags
# in the Azure portal
#
#.PARAMETER RequiredTags
# Comma separated list of required tags
#
#.PARAMETER DisplayUrl
# If this parameter is present, it will output a URL link
# directly to the portal to update the tags
#
#.EXAMPLE
# FindResourceMissingTags.ps1 -RequiredTags "Department" -DisplayUrl
#
#.NOTES
#
##############################

[CmdletBinding()]

Param (
    [parameter(Mandatory=$True)]
    [string] $RequiredTags,

    [parameter(Mandatory=$False)]
    [switch] $DisplayUrl
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

if ($DisplayUrl) {
    $portalUrl = "https://portal.azure.com/"

    if ($azureEnvironmentName -eq "AzureUSGovernment") {
        $portalUrl = "https://portal.azure.us/"

    } elseif ($azureEnvironmentName -eq "AzureChinaCloud") {
        $portalUrl = "https://portal.azure.cn/"

    } elseif ($azureEnvironmentName -eq "AzureGermanCloud") {
        $portalUrl = "https://portal.microsoftazure.de/"
    }
}

$requiredTagList = $RequiredTags.Split(",")

$resources = Get-AzureRmResource
Write-Verbose "$($resources.Length) resources found"
foreach ($resource in $resources) {
    if (-not $resource.Tags) {
        Write-Output "$($resource.Name) has no tags"
        continue
    }

    $missingTags = @()
    foreach ($requiredTag in $requiredTagList) {
        if (-not $resource.Tags.ContainsKey($requiredTag)) {
            $missingTags += $requiredTag
        }
    }
    if ($missingTags.Length -gt 0) {
        $tagText = $missingTags -join ","
        Write-Output "$($resource.Name) missing tags: $tagText"

        if ($DisplayUrl) {
            $url = $portalUrl + "#resource" + $resource.ResourceId + "/tags"
            Write-Output "     $url"
        }
    }
}
