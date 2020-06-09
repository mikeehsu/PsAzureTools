<#
.SYNOPSIS
Backup the contents of an Azure KeyVault to a file

.DESCRIPTION
This script will copy the contents of an Azure KeyVault to a ZIP archive file.

.PARAMETER VaultName
Name of the Azure KeyVault to backup

.PARAMETER OutputFile
Name of the archive file to create. If -OutputFile is not specified, a file with the name "<Azure KeyVault Name>-backup.zip" will be created.

.EXAMPLE
Backup-KeyVault.ps1 -VaultName MyKeyVault -OutputFile "MyKeyVault.zip"

.EXAMPLE
Backup-KeyVault.ps1 MyKeyVault
#>

[CmdletBinding()]

Param (
    [Parameter(Mandatory, Position=0)]
    [string] $VaultName,

    [Parameter(Position=1)]
    [string] $OutputFile
)

#################################################
# MAIN

#region - confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}
catch {
    throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
}
#endregion

#region - validate parameter values
# check OutputFile path
if (-not $OutputFile) {
    $OutputFile = "$VaultName-backup.zip"
}

if (Test-Path $OutputFile) {
    throw "$OutputFIle already exsists. Please remove before starting backup."
}

# create folder for storing keys
$now = Get-Date
if ($env:TEMP) {
    $backupPath = "$env:TEMP/$VaultName" + $now.ToString("yyyyMMddhhmm")
}
else {
    $backupPath = "./$VaultName" + $now.ToString("yyyyMMddhhmm")
}

if (Test-Path "$backupPath/*") {
    throw "Backup folder $backupPath exists. Please make sure it is empty before starting."
}
$null = New-Item -Path $backupPath -ItemType Directory -ErrorAction Stop
#endregion

$certCount = 0
$keyCount = 0
$secretCount = 0

# get keyvault
$vault = Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop
if (-not $vault) {
    throw "Unable to open key vault - $VaultName"
}

#region - backup certificates
$certs = Get-AzKeyVaultCertificate -VaultName $vault.VaultName
foreach ($cert in $certs) {
    Write-Verbose $cert.Name
    Write-Progress -Activity "Backing up $($vault.VaultName)" -Status "Working on cert $($cert.Name)..."
    $null = Backup-AzKeyVaultCertificate -VaultName $VaultName -Name $cert.Name -OutputFile "$backupPath/$($cert.Name).certificate"
    $certCount++
}
#endregion

#region - backup keys
# need to filter out certs that are getting returned by Get-AzKeyVaultKey
$keys = Get-AzKeyVaultKey -VaultName $vault.VaultName | Where-object {$certs.Name -notcontains $_.Name}
foreach ($key in $keys) {
    Write-Verbose $key.Name
    Write-Progress -Activity "Backing up $($vault.VaultName)" -Status "Working on key $($key.Name)..."
    $null = Backup-AzKeyVaultKey -VaultName $VaultName -Name $key.Name -OutputFile "$backupPath/$($key.Name).key"
    $keyCount++
}
#endregion

#region - backup secrets
# need to filter out certs that are getting returned by Get-AzKeyVaultSecret
$secrets = Get-AzKeyVaultSecret -VaultName $vault.VaultName | Where-object {$certs.Name -notcontains $_.Name}
foreach ($secret in $secrets) {
    Write-Verbose $secret.Name
    Write-Progress -Activity "Backing up $($vault.VaultName)" -Status "Working on secret $($secret.Name)..."
    $null = Backup-AzKeyVaultSecret -VaultName $VaultName -Name $secret.Name -OutputFile "$backupPath/$($secret.Name).secret"
    $secretCount++
}
#endregion

#region - package all the backup files into a zip
Write-Progress -Activity "Backing up $($vault.VaultName)" -Status "Creating archive $($OutputFile)"
Compress-Archive -Path "$backupPath/*" -DestinationPath $OutputFile
Write-Progress -Activity "Backing up $($vault.VaultName)" -Complete
#endregion

# clean up
Remove-item -Path $backupPath -Force -Recurse

Write-Information "$keyCount keys backed up"
Write-Information "$secretCount secrets backed up"
Write-Information "$certCount certificates backed up"
Write-Information "$($keyCount + $secretCount + $certCount) items backed up to $OutputFile"
