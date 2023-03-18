<#
.SYNOPSIS
Start or Stop a set of Virtual Macheins.

.DESCRIPTION
This script is used to Start, Stop or Shutdown a set of Vms. All item listed in the -Include parameters combine to narrow down the VMs to action on. Any matching criteria listed in the -Exclude will be excluded. Exclusions will take precedence.

If more than one virtual machine is identified, this runbook will queue a job for itself to action each virtual machine individually. An internal variable 'AutomationRunbookName' needs to be set to the RunbookName to queue the jobs.

.PARAMETER Action
Start, Stop, Shutdown action to take

.PARAMETER IncludeResourceGroupNames
List of resource group names to include in the action

.PARAMETER IncludeVmNames
List of Virtual Machine Names to include

.PARAMETER IncludeTags
List of tags and tag values to include in the action

.PARAMETER ExcludeResourceGroupNames
List of resource group names to exclude in the action

.PARAMETER ExcludeVmNames
List of Virtual Machine Names to exclude

.PARAMETER ExcludeTags
List of tags and tag values to exclude in the action

.EXAMPLE
.\StartStopVm.ps1 -IncludeResourceGroupNames 'dev-rg, test-rg' -IncludeTags = 'ENIVRONMENT = "DEV", ENVIRONMENT = "TEST", -ExcludeVmNames 'my-db'

.NOTES
#>
[CmdletBinding()]

Param (
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Shutdown')]
    [string] $Action,

    [Parameter()]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [Alias('ResourceGroupName')]
    [string] $IncludeResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [Alias('VmName')]
    [string] $IncludeVmNames,

    [Parameter(Mandatory = $false)]
    [Alias('Tag')]
    [string] $IncludeTags,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeVmNames,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeTags,

    [Parameter(Mandatory = $false)]
    [switch] $Whatif
)


#######################################################################
## MAIN
Set-StrictMode -Version 2.0

$startTime = Get-Date

# convert all string parameters to arrays
Write-Host '========== PARAMETERS ===================='

if ($Action) {
    Write-Host "Action: $Action"
}

if ($SubscriptionId) {
    Write-Host "SubscriptionId: $SubscriptionId"
}

if ($IncludeVmNames) {
    Write-Host 'IncludeVmNames: ' $IncludeVmNames
    $IncludeVmNames = $IncludeVmNames -Split ','
}

if ($ExcludeVmNames) {
    Write-Host 'ExcludeVmNames: ' $ExcludeVmNames
    $ExcludeVmNames = $ExcludeVmNames -Split ','
}

if ($IncludeResourceGroupNames) {
    Write-Host 'IncludeResourceGroupNames: ' $IncludeResourceGroupNames
    $IncludeResourceGroupNames = $IncludeResourceGroupNames -Split ','
}

if ($ExcludeResourceGroupNames) {
    Write-Host 'ExcludeResourceGroupNames: ' $ExcludeResourceGroupNames
    $ExcludeResourceGroupNames = $ExcludeResourceGroupNames -Split ','
}

if ($IncludeTags) {
    Write-Host 'IncludeTags: ' $IncludeTags
    [hashtable[]] $IncludeTags = ($IncludeTags -Split ',').Replace('"', '').Replace("'", '') | ConvertFrom-StringData

}

if ($ExcludeTags) {
    Write-Host 'ExcludeTags: ' $ExcludeTags
    [hashtable[]] $ExcludeTags = ($ExcludeTags -Split ',').Replace('"', '').Replace("'", '') | ConvertFrom-StringData
}


# login to the subscription
Write-Host '========== Connecting to Azure =========='

try {

    # Ensures you do not inherit an AzContext in your runbook
    $results = Disable-AzContextAutosave -Scope Process

    # Connect to Azure with system-assigned managed identity
    $connection = Connect-AzAccount -Environment AzureUSGovernment -Identity -ErrorAction Stop
    Write-Host "Connected as $($connection.Context.Account.Id)"

    if ($SubscriptionId) {
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    else {
        $context = Get-AzContext -ErrorAction Stop
    }

    Write-Host "Connection to subcription $($context.Subscription.Id) established"
}
catch {
    Write-Error "Unable to Connect-AzAccount to Subscription ($SubscriptionId) using Managed Identity"
    throw $_
}

# make sure at least one selection parameter is passed in
if (-not $IncludeVmNames -and
    -not $IncludeResourceGroupNames -and
    -not $IncludeTags ) {
    throw 'Must specify at least one -Include criteria'
}

# build inclusion expression
$includeItems = @()
if ($IncludeVmNames) {
    [string[]] $IncludeVmNames = ($IncludeVmNames -Split ',').Trim()
    $includeItems += '($IncludeVmNames -contains $_.Name)'
}

if ($IncludeResourceGroupNames) {
    [string[]] $IncludeResourceGroupNames = ($IncludeResourceGroupNames -Split ',').Trim()
    $includeItems += '($IncludeResourceGroupNames -contains $_.ResourceGroupName)'
}

if ($IncludeTags) {
    $tagCond = @()
    foreach ($tag in $IncludeTags) {
        $tagCond += '($_.Tags.Keys -ceq "' + $tag.Keys + '" -and $_.Tags["' + $tag.Keys + '"] -like "' + $tag.Values + '")'
    }
    $includeItems += $tagCond -join ' -or '
}

$includeExpr = $includeItems -join ' -and '
if (-not $includeExpr) {
    $includeExpr = '$true'
}

# build exclusion expression
$excludeItems = @()
if ($ExcludeVmNames) {
    $excludeItems += '($ExcludeVmNames -contains $_.Name)'
}

if ($ExcludeResourceGroupNames) {
    $excludeItems += '($ExcludeResourceGroupNames -contains $_.ResourceGroupName)'
}

if ($ExcludeTags) {
    foreach ($tag in $ExcludeTags) {
        $excludeItems += '($_.Tags.Keys -ceq "' + $tag.Keys + '" -and $_.Tags["' + $tag.Keys + '"] -like "' + $tag.Values + '")'
    }
}

$excludeExpr = $excludeItems -join ' -or '
if (-not $excludeExpr) {
    $excludeExpr = '$false'
}


# select VMs to process
Write-Host '========== SELECTING VMs ===================='

try {
    $cmd = "Get-AzVm -Status | Where-Object { ($includeExpr) -and -not ($excludeExpr) }"

    Write-Host 'Selecting Virtual Machines...'
    Write-Host $cmd

    $vms = Invoke-Expression $cmd
    if (-not $vms) {
        Write-Host 'No VMs found matching the specified criteria.'
        return
    }
}
catch {
    Write-Error "Error selecting VMs - $cmd"
    throw $_
}

if (-not $vms) {
    Write-Host 'No VMs selected.'
    Write-Host "Script complete. ($('{0:HH:mm:ss}' -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
    return
}
Write-Host "VMs to $($Action): $($vms.Name -join ', ')"


# if not array, only one VM found
if ($vms -isnot [array]) {

    Write-Host "========== EXECUTING $action =========="

    $vm = $vms | Get-AzVM
    if (-not $vm) {
        Write-Error "$($vm.ResourceGroupName)/$($vm.Name) VM not found. Unable to $Action."
        Write-Host "Script complete. ($('{0:HH:mm:ss}' -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
        return
    }

    try {
        if ($Action -eq 'Start') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) starting..."
            $vm | Start-Azvm

        } elseif ($Action -eq 'Stop') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) stopping..."
            $vm | Stop-AzVm -Force

        } elseif ($Action -eq 'Shutdown') {
            if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') {
                Write-Host "$($vm.ResourceGroupName)/$($vm.Name) (windows) shutting down ..."
                $vm | Invoke-AzVmRunCommand -CommandId RunPowerShellScript -ScriptString 'Stop-Computer -ComputerName localhost -Force'

            } elseif ($vm.StorageProfile.OsDisk.OsType -eq 'Linux') {
                Write-Host "$($vm.ResourceGroupName)/$($vm.Name) (linux) shutting down..."
                $vm | Invoke-AzVmRunCommand -CommandId RunShellScript -ScriptString 'shutdown'

            } else {
                Write-Error "$ResourceGroupName/$VName unable to $Action."
                throw "unsupported OsTYpe ($($vm.StorageProfile.OsDisk.OsType))."
                return
            }
        }

    } catch {
        throw $_
    }

    Write-Host "Script complete. ($('{0:HH:mm:ss}' -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
    return
}

$automationRunbookName = Get-AutomationVariable -Name 'AutomationRunbookName'

Write-Host "========= CREATING JOBS for $Action =========="
Write-Host "Automation RunbookName: $($automationRunbookName)"

# submit job to perform action
foreach ($vm in $vms) {
    if ($Action -eq 'Start') {
        if ($vm.PowerState -eq 'VM Running') {
            Write-Host "$($vm.Name) is already running."
            continue
        }

    }
    elseif ($Action -eq 'Shutdown') {
        if ($vm.PowerState -eq 'VM deallocated' -or $vm.PowerState -eq 'VM stopped') {
            Write-Host "$($vm.Name) is already shutdown."
            continue
        }

    }
    elseif ($Action -eq 'Stop') {
        if ($vm.PowerState -eq 'VM deallocated') {
            Write-Host "$($vm.Name) is already deallocated."
            continue
        }

    }
    else {
        throw "Invalid action ($Action)"
    }

    if ($WhatIf) {
        Write-Host "WhatIf: Would have $($Action) VM $($vm.Name)"
        continue
    }

    try {
        $params = @{
            'Action' = $Action;
            'IncludeResourceGroupNames' = $vm.ResourceGroupName;
            'IncludeVmNames' = $vm.Name
        }

        # submit a job to perform the action
        $job = Start-AutomationRunbook -Name $automationRunbookName -Parameters $params -ErrorAction Continue
        if ($job) {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) $Action job submitted ($job)"
        }
         else {
            Write-Error "$($vm.ResourceGroupName)/$($vm.Name) $Action job submission failed."
        }
    }
    catch {
        Write-Error "$($vm.Name) unable to submit $Action job for $automationRunbookName"
        throw $_
    }
}

Write-Host "Script complete. ($('{0:HH:mm:ss}' -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
