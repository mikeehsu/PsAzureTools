# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (! $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login and set the proper subscription context before proceeding."
    exit
}

# get all unattached Nics
$unattachedNics = Get-AzureRmNetworkInterface | Where-Object {$_.VirtualMachine -eq $null}
$unattachedNicIds = $unattachedNics | Select-Object -Expand Id

Write-Output "Unattached NetworkInterfaces:"
if ($unattachedNics.Count -eq 0) {
    Write-Output "-None-"
} else {
    $unattachedNics | Select-Object -ExpandProperty Name
}

# get all unused Nsgs
$unusedNsgs = @()
$unattachedNsgs = @()
$nsgs = Get-AzureRMNetworkSecurityGroup
foreach ($nsg in $nsgs) {
    $used = $false

    # attached to subnet
    if ($nsg.Subnets.Count -gt 0) {
        continue
    }

    # no NIC attached to the Nsg
    if ($nsg.NetworkInterfaces.Count -eq 0) {
        $unattachedNsgs += $nsg
        continue
    }

    # attached to a Nic, but Nic has no VM
    foreach ($nic in $nsg.NetworkInterfaces) {
        if ($nic.Id -notin $unattachedNicIds) {
            $used = $true
            break
        }
    }

    if (-not $used) {
        $unusedNsgs += $nsg
    }
}

Write-Output ""
Write-Output "Unattached NetworkSecurityGroups:"
if ($unattachedNsgs.Count -eq 0) {
    Write-Output "-None-"
} else {
    $unattachedNsgs | Select-Object -ExpandProperty Name | Write-Output
}

Write-Output ""
Write-Output "Unused NetworkSecurityGroups:"
if ($unusedNsgs.Count -eq 0) {
    Write-Output "-None-"
} else {
    $unusedNsgs | Select-Object -ExpandProperty Name | Write-Output
}

# find all unused Vnets
$unusedVnets = @()
$vnets = Get-AzureRmVirtualNetwork
foreach ($vnet in $vnets) {
    $used = $false

    foreach ($subnet in $vnet.Subnets) {
        if ($subnet.IpConfigurations.Count -eq 0) {
            continue
        }

        foreach ($ipconfig in $subnet.IpConfigurations) {
            $split = $ipconfig.Id.split('/')
            $nicId = $split[0..$($split.count-3)] -join '/'
            if ($nicId -notin $unattachedNicIds) {
                $used = $true
                break
            }
        }

        if ($used) {
            break
        }
    }

    if (-not $used) {
        $unusedVnets += $vnet
    }
}

Write-Output ""
Write-Output "Unused Virtual Networks:"
if ($unusedVnets.Count -eq 0 ) {
    Write-Output "-None-"
} else {
    $unusedVnets | Select-Object -ExpandProperty Name | Write-Output
}
