<#
.SYNOPSIS
Stop unused session hosts in an Azure Virtual Desktop Host Pool.

.DESCRIPTION
Stop any session hosts with no attached sessions in an Azure Virtual Desktop Host Pool. Using a service principal, you can connect to the WVD control plan or WVD Hosts VMs in a different cloud, tenant and/or subscription by setting the environment varialbles for WVD_ENVIRONMENT, WVD_TENANTID, WVD_SUBSCRIPTIONID, WVD_APPLICATIONID, WVD_PASSWORD and/or WVD_HOST_ENVIRONMENT, WVD_HOST_TENANTID, WVD_HOST_SUBSCRIPTIONID, WVD_HOST_APPLICATIONID, WVD_HOST_PASSWORD

.PARAMETER ResourceGroupName
Resource Group Name of the Host Pool

.PARAMETER Name
Name of the Host Pool

.PARAMETER MinimumHostCount
Number of active VMs to leave running in the host pool. The default is 1. If you want to shutdown all hosts, you can specify 0.

.EXAMPLE
.\Stop-AvdUnusedSessionHost.ps1 -ResourceGroupName 'My-ResourceGroup' -Name 'My-HostPool' -MinimumHostCount 1

.NOTES
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [Alias('Name')]
    [string] $HostPoolName,

    [Parameter()]
    [int] $MinimumHostCount = 1
)

Set-StrictMode -Version 3

# parse ResourceGroupName and Name from resource
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

# load necessary modules
if (-not $(Get-Module -Name Az.DesktopVirtualization)) {
    Import-Module -Name Az.DesktopVirtualization -ErrorAction Stop
}

# connect to all necessary tenant contexts
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
        Write-Host "Connecting to WVD tenant ($env:WVD_TENANTID)"
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

$context = Get-AzContext -ListAvailable | Where-Object {$_.Subscription -and $_.Subscription.Id -eq $wvdSubscriptionId }
if (-not $context) {
    Write-Error "SubscriptionId $wvdSubscriptionId not available in current context. Please provide WVD_APPLICATIONID, WVD_TENANTID, WVD_PASSWORD and WVD_ENVIRONMENT necessary for connection"
    return
}
$currentContext = $context | Set-AzContext

# get full list of sessions in pool
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop
if (-not $sessionHosts) {
    Write-Error "Unable to find Session Hosts for Host Pool - $ResourceGroupName/$HostPoolName"
    return
}

# filter down to available hosts
$availableHosts = $sessionHosts | Where-Object { $_.AllowNewSession -eq $true -and $_.Status -eq 'Available' }
if (-not $availableHosts) {
    Write-Host "No sessions hosts available, skipping shutdown."
    return
}

if ($availableHosts.Count -le $MinimumHostCount) {
    Write-Host "Only $($availableHosts.Count) sessions hosts available, skipping shutdown."
    return
}

# get all active host connections, pulling user session (host.session property counts inactive sessions as well)
$activeUserSessions = Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
| Where-Object { $_.SessionState -eq 'Active' }
$activeHosts = @()
foreach ($userSession in $activeUserSessions) {
    $activeHosts += $HostPoolName + '/' + $(GetResourcePartFromId $userSession.Id -Part 'sessionhosts')
}
$activeHosts = $activeHosts | Sort-Object -Unique

# filter out active hosts from available hosts to create unused hosts
# trim list to leave a MinimumHostCount of VMs alive
# ordering by subscription to reduce AzContext switching
$unusedHosts = $availableHosts
| Where-Object { $activeHosts -notcontains $_.Name }
| Select-Object -First $($availableHosts.Count - $MinimumHostCount)
| Sort-Object -Property ResourceId
if ($unusedHosts.Count -eq 0) {
    Write-Host 'All session hosts currently being used, skipping shutdown.'
}

# loop through hosts
$shutdownCount = 0
foreach ($unusedHost in $unusedHosts) {
    try {
        $subscriptionId, $hostVmResourceGroupName, $hostVmName = GetResourcePartFromId -ResourceID $unusedHost.ResourceId -Part @('subscriptions', 'resourceGroups', 'virtualMachines')

        if ($currentContext.Subscription.Id -ne $subscriptionId) {
            Write-Verbose "Setting subscription context ($subscriptionId)"
            $context = Get-AzContext -ListAvailable | Where-Object { $_.Subscription.Id -eq $subscriptionId }
            if (-not $context) {
                Write-Error "SubscriptionId $wvdSubscriptionId not available in current context. Please provide WVD_HOSTS_APPLICATIONID, WVD_HOSTS_TENANTID, WVD_HOSTS_PASSWORD and WVD_HOSTS_ENVIRONMENT necessary for connection"
                return
            }
            $currentContext = $context | Set-AzContext
        }

        Write-Host "Stopping session host $hostVmResourceGroupName/$hostVmName"
        Stop-AzVM -ResourceGroupName $hostVmResourceGroupName -Name $hostVmName -ErrorAction Stop -Force -NoWait
        $shutdownCount++
    }
    catch {
        $ErrorMessage = $_.Exception.message
        Write-Error "Error stopping the session host: $ErrorMessage"
        break
    }
}

# reset to original context
$currentContext = Set-AzContext -Context $originalContext

Write-Host "$shutdownCount session host(s) shutdown."
