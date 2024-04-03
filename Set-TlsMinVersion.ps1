[CmdletBinding()]

param (
    [Parameter()]
    [switch] $ApplyTLS12
)

Set-StrictMode -Version 2

$ErrorActionPreference = 'Stop'


function Update-StorageAccounts {
    [CmdletBinding()]

    param (
        [Parameter()]
        [switch] $ApplyTLS12
    )

    Write-Host '===== Checking Storage Accounts ====='
    $webApps = Get-AzStorageAccount
    Write-Host "$($webApps.Count) storage accounts"

    $tlsGroups = $webApps | Group-Object -Property MinimumTLSVersion
    foreach ($tlsGroup in $tlsGroups) {
        Write-Host "$($tlsGroup.Name) - $($tlsGroup.Count) storage accounts"
    }

    # Apply TLS 1.2
    if (-not $ApplyTLS12) {
        return
    }

    # select all accounts without TLS 1.2
    $tls12Group = $tlsGroups | Where-Object { $_.Name -ne 'TLS1_2' }
    if (-not $tls12Group) {
        Write-Host "No storage accounts updates needed."
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
        [switch] $ApplyTLS12
    )

    Write-Host '===== Checking WebApp ====='
    $webApps = Get-AzWebApp
    Write-Host "$($webApps.Count) web apps"

    $webAppDetails = @()

    foreach ($webapp in $webApps) {
        $webAppDetail = Get-AzWebApp -ResourceGroupName $webapp.ResourceGroup -Name $webapp.Name
        $webAppDetails += [PSCustomObject] @{
            Name = $webAppDetail.Name
            ResourceGroupName = $webAppDetail.ResourceGroup
            MinTlsVersion = $webAppDetail.SiteConfig.MinTlsVersion
        }
    }

    $tlsGroups = $webAppDetails | Group-Object -Property MinTlsVersion
    foreach ($tlsGroup in $tlsGroups) {
        $name = $tlsGroup.Name
        if (-not $name) {
            $name = '<default>'
        }
        Write-Host "$($name) - $($tlsGroup.Count) web apps"
    }

    # Apply TLS 1.2
    if (-not $ApplyTLS12) {
        return
    }

    # select all accounts without TLS 1.2
    $tls12Group = $tlsGroups | Where-Object { $_.Name -ne '1.2' }
    if (-not $tls12Group) {
        Write-Host "No webapp updates needed."
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

Update-StorageAccounts -ApplyTLS12:$ApplyTLS12
Update-WebApp -ApplyTLS12:$ApplyTLS12
