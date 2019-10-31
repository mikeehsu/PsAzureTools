Param (
    [Parameter(Mandatory = $true)]
    [string] $VaultName
)

$backupPath = "./$VaultName"

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

$vault = Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop
if (-not $vault) {
    throw "Unable to open key vault - $VaultName"
    return
}


if (Test-Path "$backupPath/*") {
    throw "Backup folder $backupPath exists. Please make sure it is empty before starting."
}
$null = New-Item -Path $backupPath -ItemType Directory -ErrorAction Stop

$count = 0
$keys = Get-AzKeyVaultKey -VaultName $vault.VaultName
foreach ($key in $keys) {
    Backup-AzKeyVaultKey -VaultName $VaultName -Name $key.Name -OutputFile "$backupPath/$($key.Name).key"
    $count += 1
}

$secrets = Get-AzKeyVaultSecret -VaultName $vault.VaultName
foreach ($secret in $secrets) {
    Backup-AzKeyVaultSecret -VaultName $VaultName -Name $secret.Name -OutputFile "$backupPath/$($secret.Name).secret"
    $count += 1
}

$certificates = Get-AzKeyVaultCertificate -VaultName $vault.VaultName
foreach ($certificate in $certificates) {
    Backup-AzKeyVaultCertificate -VaultName $VaultName -Name $certificate.Name -OutputFile "$backupPath/$($certificate.Name).certificate"
    $count += 1
}

Write-Output "$count keys/secrets/certificates backed up"
