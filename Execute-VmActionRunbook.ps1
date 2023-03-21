<#
.SYNOPSIS
Start or Stop a set of Virtual Macheins.

.DESCRIPTION
This script is used to Start, Stop or Shutdown a set of Vms. All item listed in the -Include parameters combine to narrow down the VMs to action on. Any matching criteria listed in the -Exclude will be excluded. Exclusions will take precedence.

If more than one virtual machine is identified, this runbook will queue a job for itself to action each virtual machine individually. If the runbook is named something other than 'Execute-VmActionRunbok', an internal variable 'AutomationRunbookName' needs to be set to the RunbookName to queue the jobs.

.PARAMETER Action
Start, Stop, Shutdown action to take

.PARAMETER IncludeResourceGroupNames
List of resource group names to include in the action

.PARAMETER IncludeVmNames
List of Virtual Machine Names to include

.PARAMETER IncludeTags
List of tags and tag values to include in the action

.PARAMETER IncludVmState
State of VM to include in the action. Only one state can be specified.

.PARAMETER ExcludeResourceGroupNames
List of resource group names to exclude in the action

.PARAMETER ExcludeVmNames
List of Virtual Machine Names to exclude

.PARAMETER ExcludeTags
List of tags and tag values to exclude in the action

.EXAMPLE
.\Execute-VmActionRunbook.ps1 -Action 'Start' -IncludeResourceGroupNames 'dev-rg, test-rg'

.EXAMPLE
.\Execute-VmActionRunbook.ps1 -Action 'Shutdown' -IncludeResourceGroupNames 'dev-rg, test-rg' -IncludeTags = 'ENIVRONMENT = "DEV", ENVIRONMENT = "TEST", -ExcludeVmNames 'my-db'

.EXAMPLE
.\Execute-VmActionRunbook.ps1 -Action 'Stop'-IncludeResourceGroupNames 'dev-rg, test-rg' -IncludeVmState 'Stopped'

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
    [ValidateSet('Running', 'Stopped', 'Deallocated', 'VM running', 'VM stopped', 'VM deallocated')]
    [string] $IncludeVmState,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeResourceGroupNames,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeVmNames,

    [Parameter(Mandatory = $false)]
    [string] $ExcludeTags,

    [Parameter(Mandatory = $false)]
    [boolean] $Whatif = $false
)


#######################################################################
## MAIN

#requires -Module Az.Accounts
#requires -Module Az.Compute

Set-StrictMode -Version 2.0

$startTime = Get-Date

# convert all string parameters to arrays
Write-Host '============================== PARAMETERS =============================='

if ($Action) {
    Write-Host "Action: $Action"
}

if ($SubscriptionId) {
    Write-Host "SubscriptionId: $SubscriptionId"
}

if ($IncludeResourceGroupNames) {
    [string[]] $IncludeResourceGroupNames = ($IncludeResourceGroupNames -Split ',').Trim().Replace('"', '').Replace("'", '')
    Write-Host 'IncludeResourceGroupNames: ' $($IncludeResourceGroupNames -join ',')
}

if ($IncludeVmNames) {
    [string[]] $IncludeVmNames = ($IncludeVmNames -Split ',').Trim().Replace('"', '').Replace("'", '')
    Write-Host 'IncludeVmNames:' $($IncludeVmNames -join ',')
}

if ($IncludeTags) {
    Write-Host "IncludeTags: $IncludeTags"
    [hashtable[]] $IncludeTags = ($IncludeTags -Split ',').Replace('"', '').Replace("'", '') | ConvertFrom-StringData -ErrorAction Stop
    if ($IncludeTags -isnot [array]) {
        throw "Unable to convert -IncludeTags to hashtable. Check format and try again."
        return
    }
}

if ($IncludeVmState) {
    if (-not $IncludeVmState.StartsWith('VM')) {
        $IncludeVmState = "VM $IncludeVmState"
    }
    Write-Host "IncludeVmState: $IncludeVmState"
}

if ($ExcludeResourceGroupNames) {
    [string[]] $ExcludeResourceGroupNames = ($ExcludeResourceGroupNames -Split ',').Trim().Replace('"', '').Replace("'", '')
    Write-Host 'ExcludeResourceGroupNames: ' $($ExcludeResourceGroupNames -join ',')
}

if ($ExcludeVmNames) {
    [string[]] $ExcludeVmNames = ($ExcludeVmNames -Split ',').Trim().Replace('"', '').Replace("'", '')
    Write-Host 'ExcludeVmNames: ' $($ExcludeVmNames -join ',')
}

if ($ExcludeTags) {
    Write-Host "ExcludeTags: $ExcludeTags"
    [hashtable[]] $ExcludeTags = ($ExcludeTags -Split ',').Replace('"', '').Replace("'", '') | ConvertFrom-StringData
}

# make sure at least one selection parameter is passed in
if (-not $IncludeVmNames -and
    -not $IncludeResourceGroupNames -and
    -not $IncludeTags ) {
    throw 'Must specify at least one -Include criteria'
}

# login to the subscription
Write-Host '==================== Connecting to Azure ===================='

try {
    $context = Get-AzContext
    if (-not $context) {
        # Ensures you do not inherit an AzContext in your runbook
        $results = Disable-AzContextAutosave -Scope Process

        # Connect to Azure with system-assigned managed identity
        $connection = Connect-AzAccount -Environment AzureUSGovernment -Identity -ErrorAction Stop
        $context = $connection.context
        Write-Host "New connection as $($context.Account.Id)"
    }

    if ($SubscriptionId) {
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    Write-Host "Subcription set to: $($context.Subscription.Id) established"
}
catch {
    Write-Error "Unable to Connect-AzAccount to Subscription ($SubscriptionId) using Managed Identity"
    throw $_
}


# select VMs to process
Write-Host '==================== SELECTING VMs =============================='

# build inclusion expression
$includeItems = @()
if ($IncludeResourceGroupNames) {
    $includeItems += '($IncludeResourceGroupNames -contains $_.ResourceGroupName)'
}

if ($IncludeVmNames) {
    $includeItems += '($IncludeVmNames -contains $_.Name)'
}

if ($IncludeTags) {
    $tagCond = @()
    foreach ($tag in $IncludeTags) {
        $tagCond += '($_.Tags.Keys -ceq "' + $tag.Keys + '" -and $_.Tags["' + $tag.Keys + '"] -like "' + $tag.Values + '")'
    }
    $includeItems += '(' + $($tagCond -join ' -or ') + ')'
}

if ($IncludeVmState) {
    $includeItems += '($_.PowerState -eq "' + $IncludeVmState + '")'
}

$includeExpr = $includeItems -join ' -and '
if (-not $includeExpr) {
    $includeExpr = '$true'
}

# build exclusion expression
$excludeItems = @()
if ($ExcludeResourceGroupNames) {
    $excludeItems += '($ExcludeResourceGroupNames -contains $_.ResourceGroupName)'
}

if ($ExcludeVmNames) {
    $excludeItems += '($ExcludeVmNames -contains $_.Name)'
}

if ($ExcludeTags) {
    $tagCond = @()
    foreach ($tag in $ExcludeTags) {
        $tagCond += '($_.Tags.Keys -ceq "' + $tag.Keys + '" -and $_.Tags["' + $tag.Keys + '"] -like "' + $tag.Values + '")'
    }
    $excludeItems += '(' + $($tagCond -join ' -or ') + ')'
}

$excludeExpr = $excludeItems -join ' -or '
if (-not $excludeExpr) {
    $excludeExpr = '$false'
}


# execute VM query
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

    Write-Host "==================== EXECUTING $action ===================="

    $vm = $vms | Get-AzVM
    if (-not $vm) {
        Write-Error "$($vm.ResourceGroupName)/$($vm.Name) VM not found. Unable to $Action."
        Write-Host "Script complete. ($('{0:HH:mm:ss}' -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
        return
    }

    try {
        if ($Action -eq 'Start') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) starting..."
            $vm | Start-AzVM -WhatIf:$WhatIf

        }
        elseif ($Action -eq 'Stop') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) stopping..."
            $vm | Stop-AzVM -Force -WhatIf:$WhatIf

        }
        elseif ($Action -eq 'Shutdown') {
            if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') {
                Write-Host "$($vm.ResourceGroupName)/$($vm.Name) (windows) shutting down ..."
                $vm | Invoke-AzVMRunCommand -CommandId RunPowerShellScript -ScriptString 'Stop-Computer -ComputerName localhost -Force' -WhatIf:$WhatIf

            }
            elseif ($vm.StorageProfile.OsDisk.OsType -eq 'Linux') {
                Write-Host "$($vm.ResourceGroupName)/$($vm.Name) (linux) shutting down..."
                $vm | Invoke-AzVMRunCommand -CommandId RunShellScript -ScriptString 'shutdown' -WhatIf:$WhatIf

            }
            else {
                Write-Error "$ResourceGroupName/$VName unable to $Action."
                throw "unsupported OsTYpe ($($vm.StorageProfile.OsDisk.OsType))."
                return
            }
        }

    }
    catch {
        throw $_
    }

    Write-Host "Script complete. ($('{0:HH:mm:ss}' -f $([datetime] $($(Get-Date) - $startTime).Ticks)) elapsed)"
    return
}

# get name of AutomationRunbook
$automationRunbookName = Get-AutomationVariable -Name 'AutomationRunbookName' -ErrorAction SilentlyContinue
if (-not $automationRunbookName) {
    $automationRUnbookName = 'Execute-VmActionRunbook'
}

Write-Host "==================== SUBMITTING JOBS for $Action ===================="
Write-Host "Automation RunbookName: $($automationRunbookName)"

# submit job to perform action
foreach ($vm in $vms) {
    if ($Action -eq 'Start') {
        if ($vm.PowerState -eq 'VM Running') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) no action required,$($vm.Powerstate)."
            continue
        }

    }
    elseif ($Action -eq 'Shutdown') {
        if ($vm.PowerState -eq 'VM deallocated' -or $vm.PowerState -eq 'VM stopped') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) no action required, $($vm.Powerstate)"
            continue
        }

    }
    elseif ($Action -eq 'Stop') {
        if ($vm.PowerState -eq 'VM deallocated') {
            Write-Host "$($vm.ResourceGroupName)/$($vm.Name) no action required, $($vm.Powerstate)."
            continue
        }

    }
    else {
        throw "Invalid action ($Action)"
    }

    try {
        $params = @{
            'Action'                    = $Action;
            'SubscriptionId'            = $context.Subscription.Id;
            'IncludeResourceGroupNames' = $vm.ResourceGroupName;
            'IncludeVmNames'            = $vm.Name
        }

        # submit a job to perform the action
        if ($WhatIf) {
            Write-Host "What If: submitting job to $Action VM $($vm.ResourceGroupName)/$($vm.Name)"
            continue
        }

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
