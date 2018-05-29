##############################
#.SYNOPSIS
# Workflow for starting and stopping VMs.
#
#.DESCRIPTION
# This workflow will start or stop virtual machines on a schedule when
# used with an Azure Automation job. This workflow was designed for used
# with Azure Automation. It requires credentials called 'AzureCredential'
# to be created and stored in the automation account.
#
#.PARAMETER SubscriptionId
# This perameter is required and indicates the subscription in which to
# execute the start/stop against.
#
#.PARAMETER ResourceGroupList
# If specified, this workflow will attempt to start/stop all virtual
# machines in the resource groups listed. This parameter allows for
# multiple resource groups to be listed, each on being separated by
# a comma.
#
#.PARAMETER VmList
# If specified, this workflow will attempt to start/stop all virtual
# machines listed. This parameter allows for multiple virtual machines
# to be listed, each on being separated by a comma.
#
#.PARAMETER VmExcludeList
# If specified, the start/stop action will not be applied to any virtual
# machines listed here. This is useful when you want to start/stop all
# machines in a resource group except for a specific one or two. This
# parameter allows for multiple virtual machines to be excluded by listing
# all virtual machines, each separated by a comma.
#
#.PARAMETER Action
# This parameter is required. Provide either 'Start' or 'Stop' to indicate
# whether this workflow should Start or Stop the virtual machines.
#
#.PARAMETER ExcludeDaysOfWeek
# If provided, this parameter specifies which days of the week this
# workflow should not run on. This feature is provided to overcome the
# shortcomings in the Azure Automation scheduling functionality. You can
# list mulitple days by separating each one with a comma. For example,
# if you do not want the workflow to execute on the weekends, you can specify
# 'Saturday,Sunday'.
#
#.EXAMPLE
#
#.NOTES
#
##############################

Workflow StartStopVM {
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupList = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $VmList = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $VmExcludeList = '',

        [Parameter(Mandatory = $true)]
        [ValidateSet("Start", "Stop")]
        [String] $Action,

        [Parameter(Mandatory = $false)]
        [String] $ExcludeDaysOfWeek = ''
    )

    [string] $dow = (date).DayOfWeek
    if ($dow -in $ExcludeDaysOfWeek.Split(',').Trim()) {
        Write-Output "Script does not run on $ExcludeDaysOfWeek. Today is $dow."
        return
    }

    # login and set subscription
    $credential = Get-AutomationPSCredential -Name 'AzureCredential'
    Login-AzureRmAccount -Credential $credential -Environment AzureUSGovernment
    Select-AzureRmSubscription -SubscriptionId $SubscriptionId

    # get list of VMs to process
    $resourceGroupNames = $ResourceGroupList.Split(',').Trim()
    $vmNames = $VmList.Split(',').Trim()
    $vmNameExcludes = $VmExcludeList.Split(',').Trim()

    $allVms = Get-AzureRmVm

    $vmsToProcess = $allVms | Where-Object {$_.ResourceGroupName -in $resourceGroupNames -and $_.Name -notin $vmNameExcludes}
    $vmsToProcess += $allVms | Where-Object {$_.Name -in $vmNames -and $_.Name -notin $vmNameExcludes}

    Write-Output "VMs to $Action"
    Write-Output $vmsToProcess.Name
    Write-Output '--------------------'

    if ($Action -eq "Stop") {
        foreach -parallel ($vm in $vmsToProcess) {
            Write-Output "$($vm.Name) stopping...";
            $vm | Stop-AzureRmVM -Force
            Write-Output "$($vm.Name) stopped."
        }
    }
    else {
        foreach -parallel ($vm in $vmsToProcess) {
            Write-Output "$($vm.Name) starting..."
            $vm | Start-AzureRmVM
            Write-Output "$($vm.Name) started."
        }
    }
}