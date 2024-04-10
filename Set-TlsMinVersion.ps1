<#
.SYNOPSIS
Updates storage accounts and web apps to use TLS 1.2.

.DESCRIPTION
This script checks the existing storage accounts and web apps for their TLS versions and updates them to use TLS 1.2 if needed.

.PARAMETER ShowDetails
A switch parameter to display the TLS versions of all storage accounts and web apps.

.PARAMETER ApplyTLS12
A switch parameter to apply the update to TLS 1.2. If not supplied, the script will only display the current TLS versions. No updates will be made.

.EXAMPLE
.\Set-TlsMinVersion.ps1 -ShowDetails
This command will display the TLS versions of all storage accounts and web apps .

.EXAMPLE
.\Set-TlsMinVersion.ps1 -ApplyTLS12
This command will update all storage accounts and web apps to use TLS 1.2.
#>

[CmdletBinding()]

param (
    [Parameter()]
    [switch] $ShowDetails,

    [Parameter()]
    [switch] $ApplyTls12
)

function Update-StorageAccounts {
    [CmdletBinding()]

    param (
        [Parameter()]
        [switch] $ShowDetails,

        [Parameter()]
        [switch] $ApplyTLS12
    )

    Write-Host '===== Checking Storage Accounts ====='
    $storageAccounts = Get-AzStorageAccount
    if ($storageAccounts) {
        Write-Host "$($storageAccounts.Count) storage accounts in subscription"
    }
    else {
        Write-Host 'No storage accounts found in subscription.'
    }

    $tlsGroups = $storageAccounts | Group-Object -Property MinimumTLSVersion
    foreach ($tlsGroup in $tlsGroups) {
        Write-Host ''
        Write-Host "$($tlsGroup.Name) - $($tlsGroup.Count) storage accounts"

        if (-not $ShowDetails) {
            Continue
        }

        # list name of each storage account
        foreach ($acount in $tlsGroup.Group) {
            Write-Host "$($acount.StorageAccountName)"
        }
    }

    # select all accounts without TLS 1.2
    $tls12Group = $tlsGroups | Where-Object { $_.Name -ne 'TLS1_2' }
    if (-not $tls12Group) {
        Write-Host ''
        Write-Host 'No storage accounts updates needed.'
        return
    }

    Write-Host ''
    Write-Host "$($tls12Group.Count) storage accounts need updating to TLS 1.2"

    # Apply TLS 1.2
    if (-not $ApplyTLS12) {
        return
    }

    Write-Host ''
    Write-Host 'Updating TLS 1.2...'
    foreach ($account in $tls12Group.Group) {
        try {
            $result = $account | Set-AzStorageAccount -MinimumTlsVersion TLS1_2
            Write-Host "$($account.StorageAccountName) updated to TLS 1.2"
        }
        catch {
            throw $_
        }
    }

}



function Update-WebApp {

    [CmdletBinding()]

    param (
        [Parameter()]
        [switch] $ShowDetails,

        [Parameter()]
        [switch] $ApplyTLS12
    )

    Write-Host '===== Checking WebApp ====='
    $webApps = Get-AzWebApp
    if ($webApps) {
        Write-Host "$($webApps.Count) web apps in subscription"
    }
    else {
        Write-Host 'No web apps found.'
    }

    # when getting all webapps without -ResourceGroupName and -Name parameters
    # the MinTlsVersion setting is not populated. We need to step through each
    # webapp one at a time to get the MinTlsVersion setting
    $webAppDetails = @()
    foreach ($webapp in $webApps) {
        $webAppDetail = Get-AzWebApp -ResourceGroupName $webapp.ResourceGroup -Name $webapp.Name
        $webAppDetails += [PSCustomObject] @{
            Name              = $webAppDetail.Name
            ResourceGroupName = $webAppDetail.ResourceGroup
            MinTlsVersion     = $webAppDetail.SiteConfig.MinTlsVersion
        }
    }

    $tlsGroups = $webAppDetails | Group-Object -Property MinTlsVersion
    foreach ($tlsGroup in $tlsGroups) {
        $name = $tlsGroup.Name
        if (-not $name) {
            $name = '<default>'
        }
        Write-Host ''
        Write-Host "$($name) - $($tlsGroup.Count) web apps"

        if (-not $ShowDetails) {
            Continue
        }

        # list name of each app
        foreach ($app in $tlsGroup.Group) {
            Write-Host "$($app.Name)"
        }
    }

    # select all accounts without TLS 1.2
    $tls12Group = $tlsGroups | Where-Object { $_.Name -ne '1.2' }
    if (-not $tls12Group) {
        Write-Host ''
        Write-Host 'No webapp updates needed.'
        return
    }

    Write-Host ''
    Write-Host "$($tls12Group.Count) web apps need updating to TLS 1.2"

    # Apply TLS 1.2
    if (-not $ApplyTLS12) {
        return
    }

    Write-Host ''
    Write-Host 'Updating TLS 1.2...'
    foreach ($resource in $tls12Group.Group) {
        try {
            $result = Set-AzWebApp -ResourceGroup $resource.ResourceGroupName -Name $resource.Name -MinTlsVersion '1.2'
            Write-Host "$($resource.Name) updated to TLS 1.2"
        }
        catch {
            throw $_
        }
    }

}

###########
## MAIN
###########

Set-StrictMode -Version 2

$ErrorActionPreference = 'Stop'

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

Update-StorageAccounts -ShowDetails:$ShowDetails -ApplyTLS12:$ApplyTLS12 -ErrorAction Stop
Update-WebApp -ShowDetails:$ShowDetails  -ApplyTLS12:$ApplyTLS12 -ErrorAction Stop
