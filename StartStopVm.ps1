<#
.SYNOPSIS
Start or Stop a set of Virtual Macheins.

.DESCRIPTION
This script is used to Start or Stop a set of Vms. All item listed in the -Include parameters will be selected. All items listed in the -Exclude parameters will be excluded. Exclusions will take precedence.

.PARAMETER Action
Start of Stop action to take

.PARAMETER SetVmCount
Specify how many Virtual Machines to leave up and running

.PARAMETER IncludeVmNames
List of Virtual Machine Names to include

.PARAMETER ExcludeVmNames
List of Virtual Machine Names to exclude

.PARAMETER IncludeResourceGroupNames
List of resource group names to include in the action

.PARAMETER ExcludeResourceGroupNames
List of resource group names to exclude in the action

.PARAMETER IncludeTags
List of tags and tag values to include in the action

.PARAMETER ExcludeTags
List of tags and tag values to exclude in the action

.PARAMETER Wait
If specified this will wait until the action completes before returning back. By default, the script will end once the action has been requested.

.EXAMPLE
.\StartStopVm.ps1 -IncludeResourceGroupNames 'test-rg' -IncludeTags = @( @{ENIVRONMENT = 'DEV'} ) -ExcludeVmNames 'my-db'

.\StartStopVm.ps1 -SetVmCount 5 -IncludeResourceGroupNames 'test-rg'
.NOTES
#>
[CmdletBinding()]

Param (
    [Parameter(ParameterSetName='PerformAction',
        Mandatory = $true)]
    [ValidateSet('Start','Stop')]
    [string] $Action,

    [Parameter(ParameterSetName='SetVMCount',
        Mandatory = $true)]
    [int] $SetVmCount,

    [Parameter(Mandatory = $false)]
    [Alias('VmName')]
    [array] $IncludeVmNames,

    [Parameter(Mandatory = $false)]
    [array] $ExcludeVmNames,

    [Parameter(Mandatory = $false)]
    [Alias('ResourceGroupName')]
    [array] $IncludeResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [array] $ExcludeResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [Alias('Tag')]
    [array] $IncludeTags,

    [Parameter(Mandatory = $false)]
    [array] $ExcludeTags,

    [Parameter(Mandatory = $false)]
    [switch] $Wait
)

#######################################################################
## MAIN
Set-StrictMode -Version 2.0

$startTime = Get-Date

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw"Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }

}
catch {
    throw "Please login and set the proper subscription context before proceeding."
}

# make sure at least one selection parameter is passed in
if (-not $IncludeVmNames -and
    -not $IncludeResourceGroupNames -and
    -not $IncludeTags -and
    -not $ExcludeVmNames -and
    -not $ExcludeResourceGroupNames -and
    -not $ExcludeTags) {
    throw "Must specify at least one -Include or -Exclude criteria"
}

# build inclusion expression
$includeItems = @()
if ($IncludeVmNames) {
    $includeItems += '$IncludeVmNames -contains $_.Name'
}

if ($IncludeResourceGroupNames) {
    $includeItems += '$IncludeResourceGroupNames -contains $_.ResourceGroupName'
}

foreach ($tag in $IncludeTags) {
    $includeItems += '$_.Tags.' + $tag.Keys + " -eq '" + $tag.Values + "'"
}

$includeExpr = $includeItems -join ' -or '
if (-not $includeExpr) {
    $includeExpr = '$true'
}

# build exclusion expression
$excludeItems = @()
if ($ExcludeVmNames) {
    $excludeItems += '$ExcludeVmNames -contains $_.Name'
}

if ($ExcludeResourceGroupNames) {
    $excludeItems += '$ExcludeResourceGroupNames -contains $_.ResourceGroupName'
}

foreach ($tag in $ExcludeTags) {
    $excludeItems += '$_.Tags.' + $tag.Keys + " -eq '" + $tag.Values + "'"
}

$excludeExpr = $excludeItems -join ' -or '
if (-not $excludeExpr) {
    $excludeExpr = '$false'
}

# get Vms
try {
    $cmd = "Get-AzVm -Status | Where-Object { ($includeExpr) -and -not ($excludeExpr) }"
    Write-Debug $cmd
    $vms = Invoke-Expression $cmd
    if (-not $vms) {
        Write-Host "No VMs found matching the specified criteria."
        return
    }
} catch {
    throw "Error selecting VMs - $cmd"
}
Write-Host "VMs selected: $($vms.Name -join ', ')"

# set a -SetVmCount, instead of action. use $PSBoundParameters.ContainsKey, simple $SetVmCount returns false when 0
if ($PSBoundParameters.ContainsKey('SetVmCount')) {
    Write-Verbose "Setting VM count to: $SetVmCount"

    $runningVms = @()
    $runningVms += $vms | Where-Object {$_.PowerState -eq 'VM Running'} | Sort-Object -Property Name

    $otherVms = @()
    $otherVms += $vms | Where-Object {$_.PowerState -ne 'VM Running'} | Sort-Object -Property Name

    Write-Host "$($runningVms.Count) VMs running"

    if ($vms.Count -lt $SetVmCount) {
        Write-Host "Only $($vms.Count) VMs found, will start all VMs."
        $Action = 'Start'

    } elseif ($runningVms.Count -eq $SetVmCount) {
        $vms = $null

    } elseif ($runningVms.Count -gt $SetVmCount) {
        Write-Host "$($runningVms.Count-$SetVmCount) VMs to stop"
        $Action = 'Stop'
        if ($SetVmCount -eq 0 -and $runningVms.Count-1 -eq 0) {
            # some bug is preventing [0..0] from returning a single element
            $vms = $runningVms[0]
        } else {
            $vms = $runningVms[$($SetVmCount)..$($runningVms.Count-1)]
        }

    } elseif ($runningVms.Count -lt $SetVmCount) {
        Write-Host "$($SetVmCount-$runningVms.Count) VMs to start"
        $Action = 'Start'
        $lastVmIndex = $SetVmCount-$runningVms.Count-1
        if ($lastVmIndex -eq 0) {
            # some bug is preventing [0..0] from returning a single element
            $vms = $otherVms[0]
        } else {
            $vms = $otherVms[0..$lastVmIndex]
        }
    }
}

# check for VMs to process
if (-not $vms) {
    Write-Host 'No VMs selected.'
    Write-Host "Script complete. ($("{0:HH:mm:ss}" -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
    return
}
Write-Verbose "VMs to $($Action): $($vms.Name -join ', ')"

# execute the action
$jobs = @()
foreach ($vm in $vms) {
    if ($Action -eq 'Start') {
        if ($vm.PowerState -eq 'VM Running') {
            Write-Host "VM $($vm.Name) is already running."
            continue
        }
        $jobs += Start-AzVm -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -AsJob
        Write-Host "starting '$($vm.Name)'"

    } elseif ($Action -eq 'Stop') {
        if ($vm.PowerState -eq 'VM deallocated') {
            Write-Host "VM $($vm.Name) is already deallocated."
            continue
        }
        $jobs += Stop-AzVm -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -AsJob
        Write-Host "stopping '$($vm.Name)'"

    } else {
        throw "Invalid action ($Action)"
    }
}

if ($jobs.Count -eq 0) {
    Write-Host "Script complete. ($("{0:HH:mm:ss}" -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
    return
}

# wait for jobs to complete
if (-not $Wait) {
    Write-Host "Job submitted. Check job status using Get-Job."
    Write-Host "Script complete. ($("{0:HH:mm:ss}" -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
    return
}

$jobIds =  [System.Collections.ArrayList] @($jobs.Id)
do {
    $job = Wait-Job -Id $jobIds[0]
    Write-Host "$($job.Name) $($job.StatusMessage)"

    Remove-Job $job
    $jobIds.Remove($jobIds[0])
} until (-not $jobIds)

Write-Host "Script complete. ($("{0:HH:mm:ss}" -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
