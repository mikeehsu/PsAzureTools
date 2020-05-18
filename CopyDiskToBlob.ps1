<#
.SYNOPSIS
Copy a managed disk to blob storage. 

.DESCRIPTION
This script will copy a managed disk and create a VHD file in blob storage.
    
.PARAMETER ResourceGroupName
Resource Group Name of the Managed Disk

.PARAMETER DiskName
Name of the disk to copy.

.PARAMETER StorageAccountName
Name of the Storage Account where you want the VHD file created.

.PARAMETER ContainerName
Name of the Container where you want the VHD file created

.PARAMETER VhdFileName
Name of the full blob name. This should include the full path.

.PARAMETER UseAzcopy
Use this setting if you wish to copy the disk to a VHD blob immediately, otherwise the Azure copy job will occur in the background. To use this feature, you will need to have AZCOPY installed locally. 

.PARAMETER AzcopyDir
Specifies the directory where the AZCOPY command resides. If this parameter is not supplied it will try to execute AZCOPY from your environment PATH

.EXAMPLE
CopyDiskToBlob.ps1 -ResourceGroupName MyResourceGroup -DiskName MyVM_Data_Disk1 -StorageAccountName mystorageaccount001 -ContainerName vhds-container -VhdFileName datadiskcopy.vhd -UseAzcopy -AzcopyDir C:\Utils\

.EXAMPLE
CopyDiskToBlob.ps1 -ResourceGroupName MyResourceGroup -DiskName MyVM_Data_Disk1 -StorageAccountName mystorageaccount001 -ContainerName vhds-container -VhdFileName datadiskcopy.vhd
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName, 

    [Parameter(Mandatory = $true)]
    [string] $DiskName,

    [Parameter(Mandatory = $true)]
    [string] $StorageAccountName,
    
    [Parameter(Mandatory = $true)]
    [string] $ContainerName,

    [Parameter(Mandatory = $false)]
    [string] $VhdFileName,

    [Parameter(Mandatory = $false)]
    [switch] $UseAzcopy,

    [Parameter(Mandatory = $false)]
    [string] $AzcopyDir

)

# this script is based on a code found here:
# https://docs.microsoft.com/en-us/azure/virtual-machines/scripts/virtual-machines-windows-powershell-sample-copy-managed-disks-vhd

$sasExpiryDuration = "3600"

if (-not $VhdFileName) {
    $VhdFileName = $DiskName + '.vhd'
}

# confirm user is logged into subscription
try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}
catch {
    throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
}

# check azcopy path
if ($AzCopyDir -and -not $AzCopyDir.EndsWith('\')) {
    $AzCopyDir += '\'
}
$azcopyExe = $AzCopyCommandDir + 'azcopy.exe'


#Generate the SAS for the managed disk 
try {
    Write-Progress -Activity  "Copy $ResourceGroup/$DiskName to $StorageAccountName/$ContainerName/$VhdFilename" -Status "Getting disk access information..."
    $diskAccess = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $DiskName -DurationInSecond $sasExpiryDuration -Access Read 
}
catch {
    throw "Enable to get access to disk $diskName"
}

#Create the context of the storage account where the underlying VHD of the managed disk will be copied
$resource = Get-AzResource -Name $StorageAccountName -ResourceType 'Microsoft.Storage/storageAccounts'
$storageAccount = Get-AzStorageAccount -StorageAccountName $storageAccountName -ResourceGroupName $resource.ResourceGroupName

#Copy the VHD of the managed disk to the storage account
if ($UseAzCopy) {
    $containerSASURI = New-AzStorageContainerSASToken -Context $storageAccount.Context -ExpiryTime(get-date).AddSeconds($sasExpiryDuration) -FullUri -Name $ContainerName -Permission rw
    $containerUri, $sastoken = $containerSASURI -split "\?"
    $containerSASURI = "$containerUri/$VhdFileName`?$sastoken"
    try {
        $null = Invoke-Expression -Command $azcopyExe -ErrorAction SilentlyContinue
    }
    catch {
        Write-Error "Unable to find azcopy.exe command. Please make sure azcopy.exe is in your PATH or use -AzCopyDir to specify azcopy.exe path" -ErrorAction Stop
    }

    $params = @('copy', $diskAccess.AccessSAS, $containerSASURI, '--s2s-preserve-access-tier=false')
    & $azcopyExe $params
    if (-not $?) {
        throw "Error occured while copying using: $azcopyExe - $($params -join ' ')"
    }

}
else {
    Write-Progress -Activity  "Copy $ResourceGroup/$DiskName to $StorageAccountName/$ContainerName/$VhdFilename" -Status "Starting disk copy..."
    Start-AzStorageBlobCopy -AbsoluteUri $diskAccess.AccessSAS -DestContainer $ContainerName -DestContext $storageAccount.Context -DestBlob $VhdFileName
    Write-Output "Disk copy to $StorageAccountName/$ContainerName/$VhdFilename started. Check storage blob for copy status."
}