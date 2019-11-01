Param (
    [Parameter(Mandatory = $true)]
    [string] $VaultName,

    [Parameter(Mandatory = $false)]
    [string] $OutputFile
)

#################################################
# MAIN

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw"Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}
catch {
    throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
}

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


# get keyvault
$vault = Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop
if (-not $vault) {
    throw "Unable to open key vault - $VaultName"
    return
}

$count = 0
$keys = Get-AzKeyVaultKey -VaultName $vault.VaultName
foreach ($key in $keys) {
    $null = Backup-AzKeyVaultKey -VaultName $VaultName -Name $key.Name -OutputFile "$backupPath/$($key.Name).key"
    Write-Verbose $key.Name
    $count += 1
}

$secrets = Get-AzKeyVaultSecret -VaultName $vault.VaultName
foreach ($secret in $secrets) {
    $null = Backup-AzKeyVaultSecret -VaultName $VaultName -Name $secret.Name -OutputFile "$backupPath/$($secret.Name).secret"
    Write-Verbose $secret.Name
    $count += 1
}

$certs = Get-AzKeyVaultCertificate -VaultName $vault.VaultName
foreach ($cert in $certs) {
    $null = Backup-AzKeyVaultCertificate -VaultName $VaultName -Name $cert.Name -OutputFile "$backupPath/$($cert.Name).certificate"
    Write-Verbose $cert.name
    $count += 1
}

# package all the backup files into a zip
Compress-Archive -Path "$backupPath/*" -DestinationPath $OutputFile

# clean up
Remove-item -Path $backupPath -Force -Recurse

Write-Output "$count items backed up to $OutputFile"
