Param (
    [Parameter(Mandatory = $true)]
    [string] $VaultName,

    [Parameter(Mandatory = $true)]
    [string] $InputPath
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

# create folder for storing keys
$filename = Split-Path $InputPath -Leaf -Resolve
if ($filename.substring($filename.length - 4) -eq '.zip') {
    $filename = $filename.substring(0, $filename.length - 4)
}
else {
    $filename = $filename + ".expand"
}

if ($env:TEMP) {
    $expandPath = "$env:TEMP/$filename"
}
else {
    $expandPath = "./$filename"
}

# check InputPath
if (Test-Path $expandPath) {
    $answer = Read-Host -Prompt "$expandPath already exsits. Overwrite? (Y/N)"
    if (-not $answer.StartsWith('Y')) {
        return
    }
}

# expand zip to a folder
Expand-Archive -Path $InputPath -DestinationPath $expandPath -Force


# get keyvault
$vault = Get-AzKeyVault -VaultName $VaultName -ErrorAction Stop
if (-not $vault) {
    throw "Unable to open key vault - $VaultName"
    return
}

# restore keys
$count = 0
$keyFiles = Get-Item "$expandPath/*.key"
foreach ($keyFile in $keyFiles) {
    Write-Verbose "KEY: $($keyFile.Name)"
    $result = Restore-AzKeyVaultKey -VaultName $VaultName -InputFile "$expandPath/$($keyFile.Name)"
    if (-not $result) {
        Write-Output "Unable to load key from $($keyFile.Name)"
    }
    else {
        $count += 1
    }
}

# restore secrets
$secretFiles = Get-Item "$expandPath/*.secret"
foreach ($secretFile in $secretFiles) {
    Write-Verbose "secret: $($secretFile.Name)"
    $result = Restore-AzKeyVaultsecret -VaultName $VaultName -InputFile "$expandPath/$($secretFile.Name)"
    if (-not $result) {
        Write-Output "Unable to load secret from $($secretFile.Name)"
    }
    else {
        $count += 1
    }
}

# restore certs
$certFiles = Get-Item "$expandPath/*.certificate"
foreach ($certFile in $certFiles) {
    Write-Verbose "CERTIFICATE: $($certFile.Name)"
    $result = Restore-AzKeyVaultCertificate -VaultName $VaultName -InputFile "$expandPath/$($certFile.Name)"
    if (-not $result) {
        Write-Output "Unable to load certificate from $($certFile.Name)"
    }
    else {
        $count += 1
    }
}

# clean up
Remove-item -Path $expandPath -Force -Recurse

Write-Output "$count items restored to $VaultName"