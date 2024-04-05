<#
.SYNOPSIS
    This script copies LinkedServices from one Azure Synapse workspace to another.

.DESCRIPTION
    The script uses the Azure Synapse REST API to import or update LinkedServices.

.PARAMETER ResourceGroupName
    The resource group name of the Azure Synapse workspace. This is mandatory.

.PARAMETER WorkspaceName
    The name of the destination Azure Synapse workspace. This is mandatory.

.PARAMETER $name
    The name of the LinkedService(s) to import from the provided file. If this is not supplied, all LinkedServices from the file will be imported.

.PARAMETER Suffix
    A suffix to append to the name of the LinkedService. This is optional.

.EXAMPLE
    .\Import-SynapseLinkedService.ps1 -ResourceGroupName "myResourceGroup" -WorkspaceName "myWorkspace" -Path "LinkedServices.json" -Overwrite
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $WorkspaceName,

    [Parameter()]
    [string[]] $LinkedServiceName,

    [Parameter(Mandatory)]
    [string] $Path,

    [Parameter()]
    [string] $Suffix = '',

    [Parameter()]
    [switch] $Overwrite
)


function Get-SynapseLinkedService {
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse
    )

    $linkedservices = @()
    $uri = "$($Synapse.connectivityEndpoints.dev)/linkedservices?api-version=2019-06-01-preview"

    do {
        $results = Invoke-AzRestMethod -Uri $uri -Method GET
        if ($results.StatusCode -ne 200) {
            Write-Error "Failed to get LinkedService: $($results.Content)"
            return $null
        }

        $content = $results.Content | ConvertFrom-Json
        $linkedservices += $content.value

        if ($content.PSobject.Properties.name -like 'nextLink') {
            $uri = $content.nextLink
        }
        else {
            $uri = $null
        }
    } while ($uri)

    return $linkedservices
}

function New-SynapseLinkedService {
    param (
        [Parameter(Mandatory)]
        [PSCustomObject] $Synapse,

        [Parameter(Mandatory)]
        [string] $name,

        [Parameter(Mandatory)]
        [PSCustomObject] $Properties
    )


    $uri = "$($Synapse.connectivityEndpoints.dev)/linkedServices/$($name)?api-version=2019-06-01-preview"
    $payload = @{
        name       = $name
        properties = $Properties
    } | ConvertTo-Json -Depth 10


    Write-Verbose "$name...creating"
    # Write-Host $uri
    # Write-Host $payload

    $results = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $payload
    if ($results.StatusCode -ne 202) {
        Write-Error "Failed to create $($name): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    # check status of request
    do {
        Start-Sleep -Seconds 5

        $location = $results.headers | Where-Object { $_.key -eq 'Location' }
        if (-not $location) {
            Write-Error "Failed to create $($name): $($results | ConvertTo-Json -Depth 10)"
            return $null
        }

        $results = Invoke-AzRestMethod -Uri $location.value[0] -Method GET
        if ($results.StatusCode -eq 202) {
            Write-Verbose "$($name)...$($($results.Content | ConvertFrom-Json).status)"
        }

    } while ($results.StatusCode -eq 202)

    Write-Verbose "$name...$($results.Content)"
    if ($results.StatusCode -ne 200) {
        Write-Error "Failed to create $($name): $($results | ConvertTo-Json -Depth 10)"
        return $null
    }

    $content = $results.Content | ConvertFrom-Json
    if (-not ($content.PSobject.Properties.name -like 'id')) {
        Write-Error "Failed to create $($name): $($content.error | ConvertTo-Json -Depth 10)"
        return $null
    }

    Write-Verbose "$name...created"

    return ($results.Content | ConvertFrom-Json)
}

##
## MAIN
##
Set-StrictMode -Version 2

# check parameters

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
        return
    }

}
catch {
    Write-Error 'Please login (Connect-AzAccount) and set the proper subscription (Select-AzSubscription) context before proceeding.'
    return
}

$synapse = Get-AzSynapseWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction Stop
if (-not $synapse) {
    Write-Error "Unable to find Synapse workspace $ResourceGroupName/$WorkspaceName"
    return
}

# get existing LinkedServices
$existingLinkedServices = Get-SynapseLinkedService -Synapse $synapse -ErrorAction Stop

# get LinkedServices from file
$linkedServices = Get-Content $Path | ConvertFrom-Json

# only one LinkedService to copy, if specified
if ($LinkedServiceName) {
    $linkedServices = $linkedServices | Where-Object { $LinkedServiceName -contains $_.name }
    if (-not $linkedServices) {
        Write-Error "Unable to find LinkedService '$name' in $SourceResourceGroupName/$SourceWorkspaceName"
        return
    }

    # convert to array
    $linkedServices = @($linkedServices)
}

# sort list of LinkedServices to copy
$linkedServices = $linkedServices | Sort-Object -Property Name

$successCount = 0
$skipCount = 0
$failedCount = 0
$failedNames = @()
foreach ($linkedService in $linkedServices) {
    $name = $linkedService.name + $Suffix
    Write-Progress -Activity 'Creating LinkedServices' -Status $name -PercentComplete (($successCount + $failedCount + $skipCount) / $linkedServices.Count * 100)

    if (-not $Overwrite) {
        # check if LinkedService already esxists
        $found = $existingLinkedServices | Where-Object { $LinkedServiceName -contains $_.name }
        if ($found) {
            $skipCount++
            Write-Host "$($name)...skipped (exists)"
            continue
        }
    }

    # create LinkedService
    try {
        $newService = New-SynapseLinkedService -Synapse $synapse -name $name -Properties $linkedService.Properties
        if (-not $newService) {
            throw "Untrapped error creating LinkedService '$name' in destination data factory ($ResourceGroupName/$WorkspaceName)."
        }
        $successCount++
        Write-Host "$name...created"
    }
    catch {
        Write-Error $_
        $failedCount++
        $failedNames = $failedNames + $name
        Write-Host "$name...FAILED"
    }
}

Write-Host "$successCount LinkedServices created/updated."
Write-Host "$skipCount LinkedServices skipped."
Write-Host "$failedCount LinkedServices failed."

if ($failedCount -gt 0) {
    Write-Host
    Write-Host "Failed LinkedServices: $($failedNames -join ', ')"
}
