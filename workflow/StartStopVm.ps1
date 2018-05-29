Workflow StartStartVM {
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupList='',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $VmList='',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $VmExcludeList='',

        [Parameter(Mandatory = $true)]
        [ValidateSet("Start", "Stop")]
        [String] $Action,

        [Parameter(Mandatory = $false)]
        [String] $ExcludeDaysOfWeek=''
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