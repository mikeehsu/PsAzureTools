<#
.SYNOPSIS
Enable Resource Guard on a Recover Service Vault

.DESCRIPTION
This script will enable Resource Guard on a Recover Service Vault

.PARAMETER Name
Name of the Azure Recovery Service Vault to enable Resource Guard on

.PARAMETER ResourceGuardId
Resource Id of the Resource Guard

.EXAMPLE
Enable-ResourceGuard.ps1 -ResourceGroupName MyResourceGroup -Name MyKeyVault -ResourceGuardId /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups//resourceGroups/MyGuardRG/providers/Microsoft.DataProtection/ResourceGuards/MyGuard

.EXAMPLE
Get-AzRecoveryServicesVault | Enable-ResourceGuard -ResourceGuardId $ResourceGuardId

#>

[CmdletBinding()]

Param (
    [Parameter(Mandatory=$true, Position=0, ValueFromPipelineByPropertyName=$true, HelpMessage="Name of the Resource Group for Recovery Service Vault to enable Resource Guard on")]
    [string] $ResourceGroupName,

    [Alias("Name")]
    [Parameter(Mandatory, Position=1, ValueFromPipelineByPropertyName=$true, HelpMessage="Name of the Azure Recovery Service Vault to enable Resource Guard on")]
    [string] $VaultName,

    [Parameter(Mandatory)]
    [string] $ResourceGuardId
)

#################################################
# MAIN

BEGIN {
    #confirm user is logged into subscription
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context.Environment) {
            throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
        }
    }
    catch {
        throw 'Please login (Connect-AzAccount) and set the proper subscription context before proceeding.'
    }
}


PROCESS {
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction Stop
    if (-not $vault) {
        throw 'Recovery Service Vault not found'
        return
    }

    $payloadObj = @{
        id = $vault.id + '/backupResourceguardProxies/VaultProxy'
        properties = @{
            resourceGuardResourceId = $ResourceGuardId
        }
    }
    $payload = ConvertTo-Json $payloadObj -Depth 100

    # build REST URL
    $params = @{
        Path = $vault.id + '/backupResourceguardProxies/VaultProxy?api-version=2022-03-01'
        Method = 'PUT'
        Payload = $payload
    }
    $results = Invoke-AzRestMethod @params -ErrorAction Stop
    if ($results.StatusCode -ne 200) {
        Write-Error "Error enabling Resource Guard on $ResourceGroupName/$VaultName"
        Write-Error $results.Content
        throw
    }

    Write-Host "$ResourceGroupName/$VaultName Resource Guard enabled"
}


END {

}

