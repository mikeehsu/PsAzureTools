<#
.SYNOPSIS
Start session hosts in an Azure Virtual Desktop Host Pool.

.DESCRIPTION
Start a number session hosts necesary in an Azure Virtual Desktop Host Pool to meet the utilization percentage. Utilization is calculated by taking the number of active session divided by the MaxSessionLimit set for each host in the pool. Using a service principal, you can connect to the WVD control plan or WVD Hosts VMs in a different cloud, tenant and/or subscription by setting the environment varialbles for WVD_ENVIRONMENT, WVD_TENANTID, WVD_SUBSCRIPTIONID, WVD_APPLICATIONID, WVD_PASSWORD and/or WVD_HOST_ENVIRONMENT, WVD_HOST_TENANTID, WVD_HOST_SUBSCRIPTIONID, WVD_HOST_APPLICATIONID, WVD_HOST_PASSWORD

.PARAMETER ResourceGroupName
Resource Group Name of the Host Pool

.PARAMETER Name
Name of the Host Pool

.PARAMETER Utilization
Utilization limit of host pool. If utilization of the pool exceeds the amount specified, an existing session host in the pool will be started. Default utilization is 80%.

.PARAMETER MinimumHostCount
Number of active VMs to have running.

.EXAMPLE
.\Start-AvdSessionHost.ps1 -ResourceGroupName 'My-ResourceGroup' -Name 'My-HostPool' -Utilization 0.50

.NOTES
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [Alias('Name')]
    [string] $HostPoolName,

    [Parameter(Mandatory)]
    [float] $Utilization = 0.80,

    [Parameter()]
    [float] $MinimumHostCount = 1
)

Set-StrictMode -Version 3

# parse a specific section from ResourceId
function GetResourcePartFromId {

    param (
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string[]] $Part
    )

    $result = @()

    $array = $ResourceID.Split('/')
    foreach ($item in $Part) {
        $found = 0..($array.Length - 1) | Where-Object { $array[$_] -eq $item }
        if ($found) {
            $result += $array[$found + 1]
        }
    }
    return $result
}


#
##### START PROCESSING #####
#


# load needed modules
if (-not $(Get-Module -Name Az.DesktopVirtualization)) {
    Import-Module -Name Az.DesktopVirtualization -ErrorAction Stop
}

# check parameters
if ($Utilization -gt 1) {
    $Utilization = $Utilization / 100
}

$originalContext = Get-AzContext
if (-not $originalContext) {
    Write-Error 'No Azure Context loaded. Please use Connect-AzAccount/Set-AzContext to login and set subscription and try again.'
    return
}
$wvdSubscriptionId = $originalContext.Subscription.Id


# check to see if WVD variables for a different tenant/subscription are provided
if ($env:WVD_APPLICATIONID) {

    if (-not $env:WVD_TENANTID) {
        Write-Error 'WVD_TENANTID is required to login to WVD subscription'
        return
    }

    if (-not $env:WVD_APPLICATIONID) {
        Write-Error 'WVD_APPLICATIONID is required to login to WVD subscription'
        return
    }

    if (-not $env:WVD_PASSWORD) {
        Write-Error 'WVD_PASSWORD is required to login to WVD subscription'
        return
    }

    $environment = 'AzureCloud'
    if ($env:WVD_ENVIRONMENT) {
        $environment = $env:WVD_ENVIRONMENT
    }

    try {
        Write-Host "Connecting to WVD tenant ($env:WVD_SUBSCRIPTIONID)"
        $securePassword = ConvertTo-SecureString $env:WVD_PASSWORD -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($env:WVD_APPLICATIONID, $securePassword)
        $result = Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $env:WVD_TENANTID -ErrorAction Stop -Environment $environment
    }
    catch {
        $ErrorMessage = $_.Exception.message
        Write-Error "Error logging into WVD subscription: $ErrorMessage"
        return
    }
}

# check to see if WVD_HOSTS_* variables for a different tenant/subscription are provided
if ($env:WVD_HOSTS_APPLICATIONID) {
    if (-not $env:WVD_HOSTS_TENANTID) {
        Write-Error 'WVD_HOSTS_TENANTID is required to login to WVD subscription'
        return
    }

    if (-not $env:WVD_HOSTS_PASSWORD) {
        Write-Error 'WVD_HOSTS_PASSWORD is required to login to WVD subscription'
        return
    }

    $environment = 'AzureCloud'
    if ($env:WVD_HOSTS_ENVIRONMENT) {
        $environment = $env:WVD_HOSTS_ENVIRONMENT
    }

    try {
        Write-Host "Connecting to WVD HOSTS tenant ($env:WVD_HOSTS_TENANTID)"
        $securePassword = ConvertTo-SecureString $env:WVD_HOSTS_PASSWORD -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential ($env:WVD_HOSTS_APPLICATIONID, $securePassword)
        $result = Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $env:WVD_HOSTS_TENANTID -ErrorAction Stop -Environment $environment
    }
    catch {
        $ErrorMessage = $_.Exception.message
        Write-Error "Error logging into WVD HOST subscription: $ErrorMessage"
        return
    }
}

# switch to WVD subscription
Write-Verbose "Setting subscription context ($wvdSubscriptionId)"
if ($env:WVD_SUBSCRIPTIONID) {
    $wvdSubscriptionId = $env:WVD_SUBSCRIPTIONID
}

$context = Get-AzContext -ListAvailable | Where-Object { $_.Subscription -and $_.Subscription.Id -eq $wvdSubscriptionId }
if (-not $context) {
    Write-Error "SubscriptionId $wvdSubscriptionId not available in current context. Please provide WVD_APPLICATIONID, WVD_TENANTID, WVD_PASSWORD and WVD_ENVIRONMENT necessary for connection"
    return
}
$currentContext = $context | Set-AzContext


# get host pool info
$hostPool = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName -ErrorAction Stop
if (-not $hostPool) {
    Write-Error "Unable to find Host Pool - $ResourceGroupName/$HostPoolName"
    return
}

# get full list of sessions in pool
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop
if (-not $sessionHosts) {
    Write-Error "Unable to find Session Hosts for Host Pool - $ResourceGroupName/$HostPoolName"
    return
}
Write-Host "Host Pool ($ResourceGroupName/$HostPoolName) - $($sessionHosts.Count) session host(s) in pool"

# get utilization stats
$totalSession = 0
$availableHosts = $sessionHosts | Where-Object { $_.AllowNewSession -eq $true -and $_.Status -eq 'Available' }
if (-not $availableHosts) {
    $availableHostNames = @()

    Write-Host 'Host Pool ($ResourceGroupName/$HostPoolName) - No available hosts running.'

    if ($MinimumHostCount -eq 0) {
        Write-Error 'Unable to get utilization. Please set a MinimumHostCount greater than 0, or start hosts manually'
        return
    }

    $newHostsNeeded = $MinimumHostCount
}
else {
    $availableHostNames = $availableHosts.Name

    Write-Host "Host Pool ($ResourceGroupName/$HostPoolName) - $($availableHosts.Count) active session host(s)"

    $activeUserSessions = Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
    | Where-Object { $_.SessionState -eq 'Active' }
    $totalSession = $activeUserSessions.Count
    $maxSession = $availableHosts.Count * $hostPool.MaxSessionLimit
    Write-Verbose "Host Pool ($ResourceGroupName/$HostPoolName) - $totalSession out of $maxSession sessions used"

    # exit if still under utilization percentage
    $currentUtilization = $totalSession / $maxSession
    Write-Host "Current Utilization at $($currentUtilization*100)%. Target utilization $($Utilization*100)%"
    if ($currentUtilization -lt $Utilization) {
        Write-Host "Host Pool Utilization ($($Utilization*100)%) not met, no host started"
        return
    }

    # determine how many VMs needed to bring utilization in line
    $totalHostsNeeded = [Math]::Ceiling($totalSession / ($maxSession * $Utilization))
    $newHostsNeeded = $totalHostsNeeded - $availableHosts.Count
    if ($newHostsNeeded -eq 0) {
        Write-Host 'No additional hosts needed at this time.'
        return
    }

}
Write-Host "$newHostsNeeded additional hosts needed."

$newHosts = $sessionHosts
| Where-Object { $_.AllowNewSession -eq $true -or $_.Status -ne 'Available' -and $availableHostNames -notcontains $_.Name }
if ($newHosts.Count -eq 0) {
    Write-Host 'All available hosts already running. Please add more session hosts into pool if needed.'
    return

}
elseif ($newHosts.Count -lt $newHostsNeeded) {
    Write-Host "Only $($newHosts.Count) available to start. $newHostsNeeded hosts needed. Will start all session hosts in the pool."
}


# loop though the VMs
$startupCount = 0
foreach ($newHost in $newHosts) {
    if ($startupCount -ge $newHostsNeeded) {
        break
    }

    # skip hosts where health check is failing
    $failedHealth = $newHost.HealthCheckResult | Where-Object { $_.HealthCheckResult -eq 'HealthCheckFailed' }
    if ($failedHealth) {
        Write-Error "$($newHost.Name) is in an unhealthy condition. Please fix - $($failedHealth.AdditionalFailureDetailMessage)."
        continue
    }

    try {
        $subscriptionId, $hostVmResourceGroupName, $hostVmName = GetResourcePartFromId -ResourceID $newHost.ResourceId -Part @('subscriptions', 'resourceGroups', 'virtualMachines')

        if ($currentContext.Subscription.Id -ne $subscriptionId) {
            Write-Verbose "Setting subscription context ($subscriptionId)"
            $context = Get-AzContext -ListAvailable | Where-Object { $_.Subscription.Id -eq $subscriptionId }
            if (-not $context) {
                Write-Error "SubscriptionId $wvdSubscriptionId not available in current context. Please provide WVD_HOSTS_APPLICATIONID, WVD_HOSTS_TENANTID, WVD_HOSTS_PASSWORD and WVD_HOSTS_ENVIRONMENT necessary for connection"
                return
            }
            $currentContext = $context | Set-AzContext
        }

        Write-Host "Starting session host $hostVmResourceGroupName/$hostVmName"
        Start-AzVM -ResourceGroupName $hostVmResourceGroupName -Name $hostVmName -ErrorAction Stop -NoWait
        $startupCount++
    }
    catch {
        $ErrorMessage = $_.Exception.message
        Write-Error "Error starting the session host: $ErrorMessage"
        break
    }
}
Write-Host "$startupCount session hosts started."

# reset to original context
$currentContext = Set-AzContext -Context $originalContext

