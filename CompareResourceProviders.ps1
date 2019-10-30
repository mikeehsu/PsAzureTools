<#
.SYNOPSIS
Compare the current set of Azure resource providers with a previously saved copy.

.DESCRIPTION
This Powershell command will compare the current set of resource providers with a 
saved copy of the resource providers. This is useful in seeing what has changed 
in Azure since the last time you saved a copy, keeping you informed on new feature
that may have been introduced, or sometimes a peek into what might be coming up.

.PARAMETER FilePath
Path of file to compare against the current providers, or in the case where 
-SaveCurrentProviders is set the current providers details will be saved to this 
FilePath

.PARAMETER SaveCurrentProviders
If SaveCurrentProviders is set then the current provider details will be written 
to the provided FilePath 

.EXAMPLE
.\CompareResourceProviders.ps1 -FilePath SaveCopyOfProviders.json
.\CompareResourceProviders.ps1 -FilePath SaveCopyOfProviders.json -SaveCurrentProviders
#>

Param (
    [Parameter(Mandatory = $true)]
    [string] $FilePath,

    [Parameter(Mandatory = $false)]
    [switch] $SaveCurrentProviders
)

#################################################
Function Compare-ObjectProperties {
    Param(
        [PSObject]$ReferenceObject,
        [PSObject]$DifferenceObject
    )
    $objprops = $ReferenceObject | Get-Member -MemberType Property, NoteProperty | ForEach-Object Name
    $objprops += $DifferenceObject | Get-Member -MemberType Property, NoteProperty | ForEach-Object Name

    $objprops = $objprops | Sort-Object | Select-Object -Unique

    $diffs = @()
    foreach ($objprop in $objprops) {
        $diff = Compare-Object $ReferenceObject $DifferenceObject -Property $objprop
        if ($diff) {
            $diffprops = @{
                PropertyName = $objprop
                RefValue     = ($diff | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object $($objprop))
                DiffValue    = ($diff | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object $($objprop))
            }
            $diffs += New-Object PSObject -Property $diffprops
        }
    }
    if ($diffs) { return ($diffs | Select-Object PropertyName, RefValue, DiffValue) }
}

#################################################
# MAIN

if ($SaveCurrentProviders) {
    Get-AzResourceProvider | ConvertTo-Json -Depth 10 | Out-File $FilePath
    return
}

# load providers from file
$originalResources = @{ }
$original = Get-Content $Filepath | ConvertFrom-Json -ErrorAction Stop
foreach ($provider in $original) {
    foreach ($resourceType in $provider.resourceTypes) {
        $originalResources[$provider.ProviderNamespace + '/' + $resourceType.ResourceTypeName] = $resourceType
    }
}

# load current providers
# convertto & convertfrom to match structure of original
$new = Get-AzResourceProvider | ConvertTo-Json -Depth 10 | ConvertFrom-Json
foreach ($provider in $new) {

    # loop through each resourceType checking for diffs
    foreach ($resourceType in $provider.resourceTypes) {
        $originalResourceType = $originalResources[$provider.ProviderNamespace + '/' + $resourceType.ResourceTypeName]
        if ($originalResourceType) {
            $diffs = Compare-ObjectProperties $resourceType $originalResourceType

            if ($diffs) {
                Write-Output "-UPDATED- $($resourceType.ResourceTypeName)"
                $diffs
                #     foreach ($diff in $diffs) {
                #         Write-Output "-UPDATED- $($resourceType.ResourceTypeName),$($diff.PropertyName) $($(ConvertTo-Json $diff.RefValue) -replace "`t|`n|`r",''),$($(ConvertTo-Json $diff.DiffValue) -replace "`t|`n|`r",'')"
                #     }
            }
        }
        else {
            Write-Output "-NEW- $($provider.ProviderNamespace)/$($resourceType.ResourceTypeName)"
        }
    }
}

