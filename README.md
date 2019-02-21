# PsAzureTools
Welcome to the PsAzureTools (Powershell Azure Tools) repository.

This repository contains a collection of Powershell commands to help manage Azure Resources.

Below is a list of commands available in the PsAzureTools module:

- **Move-PsAzNetworkInterface** - Move a NetworkInterface to a specific subnet

- **Remove-PsAzNetworkSecurityGroupById** - Remove unused NetworkSecurityGroup by Id

- **Remove-PsAzStorageBlobByUri** - Remove a blob from a StorageAccount using the URI

- **Remove-PsAzVm** - Remove a VirtualMachine and all associated resources

- **Update-PsAzVm** - update VirtualMachine settings, which may require deleting the machine and recreating it.

## Stand-Alone tools

- **AddRoutesForAzureServices.ps1** - Download IP Addresses from Microsoft and add routes to a route table.

- **CreateNsgFromCsv.ps1** - Create Network Security Groups from a CSV document.

- **CreateRouteTableFromCsv.ps1** - Create Route Tables from a CSV document.

- **CreateVmFromCsv.ps1** - Create Virtual Machines from a CSV document.

- **CreateVnetFromCsv.ps1** - Create Virtual Networks from a CSV document.

- **CreateWhitelistRouteTable.ps1** - Create a RouteTable from Azure Whitelist XML document.

- **FindPublicAccessStorage.ps1** - List all storage containers that allow public access.

- **FindResourceMissingTags.ps1** - List all resources that do not have specified tags associated.

- **FindUnusedNetworkResources.ps1** - List all orphaned network resources.

- **FindUnusedStorage.ps1** - List all orphaned storage accounts.

- **MoveVmToNewResourceGroup.ps1** - Move virtual machines (with Managed Disk attached) to a different resource group.

## Contributing

Mike Hsu
