# Copy all Tags from the Resource Group to Resources inside of it
# This script will loop through ALL subscriptions

# FUNCTIONS
function TagsUpToDate {
    [CmdletBinding()]
    param (
        [Parameter()]
        [hashtable] $tags1,

        [Parameter()]
        [hashtable] $tags2
    )

    foreach ($key in $tags1.Keys) {
        if ($tags2.keys -contains $key -and $tags2[$key] -eq $tags1[$key]) {
            continue
        }
        return $false
    }

    return $true
}

# MAIN

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$groupsMissingTags = @()

Write-Host "STARTING. $((Get-Date).ToString())"

$subscriptions = Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' }

foreach ($subscription in $subscriptions) {
    $context = Set-AzContext -Subscription $subscription
    Write-Host "Context set to $($context.Subscription.Name)"

    #grabs all RG's
    $resourceGroups = Get-AzResourceGroup -DefaultProfile $context
    $resources = Get-AzResource -DefaultProfile $context

    foreach ($resourceGroup in $resourceGroups) {
        if ($resourceGroup.ResourceGroupName -like 'synapseworkspace-managedrg-*') {
            # skip synapse managed resource groups
            continue
        }

        #grab the RGs tags
        $ResourceGroupTags = $resourceGroup.Tags

        if (-not $ResourceGroupTags -or $ResourceGroupTags.count -eq 0) {
            # Write-Host "$($resourceGroup.ResourceGroupName) resource group, no tags found" -ForegroundColor "red"
            $groupsMissingTags += $resourceGroup
        }
        else {
            # get all resources in the resource group
            $resourcesInGroup = $resources | Where-Object { $_.ResourceGroupName -eq $resourceGroup.ResourceGroupName }

            #push tags, Name fields for each device will have to be done manually, if too many, write another script!!
            foreach ($resource in $resourcesInGroup) {
                if ($resource.ResourceType -eq 'Microsoft.Compute/virtualMachines/extensions'                     `
                    -or $resource.ResourceType -eq 'microsoft.insights/alertrules'                                `
                    -or $resource.ResourceType -eq 'Microsoft.MachineLearningServices/workspaces/batchEndpoints'  `
                    -or $resource.ResourceType -eq 'Microsoft.MachineLearningServices/workspaces/onlineEndpoints' `
                    -or $resource.ResourceType -eq 'Microsoft.MachineLearningServices/workspaces/batchEndpoints/deployments') {
                    # skip these resource types -- fails consistenty for certain resources
                    continue
                }

                if (($resource.Tags) -and (TagsUpToDate -Tags1 $resourceGroupTags -Tags2 $resource.Tags)) {
                    # tags already up-to-date
                    continue
                }

                # delete existing tags - must delete tags first since MERGE operation does not update case on tag names
                $result = Update-AzTag -ResourceId $resource.ResourceId -Tag $ResourceGroupTags -Operation Delete -DefaultProfile $context -ErrorAction SilentlyContinue
                if (-not $result) {
                    Write-Host "FAILED: $($resource.ResourceId) update"
                    continue
                }

                # wait for deletion to update
                Start-Sleep 1

                # update changes
                $result = Update-AzTag -ResourceId $resource.ResourceId -Tag $ResourceGroupTags -Operation Merge -DefaultProfile $context -ErrorAction SilentlyContinue
                if (-not $result) {
                    Write-Host "FAILED: $($resource.ResourceId) update"
                    continue
                }

                Write-Host "$($resource.ResourceId) updated"
            }
        }
    }
}


if ($groupsMissingTags) {

    $groupsMissingTags = $groupsMissingTags | Where-Object {       `
        $_.ResourceGroupName -notlike 'cloud-shell*'                `
        -and $_.ResourceGroupName -notlike 'AzureBackupRG_*'        `
        -and $_.ResourceGroupName -notlike 'DefaultResourceGroup-*' `
        -and $_.ResourceGroupName -notlike 'NetworkWatcherRG*'      `
    }

    Write-Host "Tagging anomolies detected... sending reports"

    $emailBody = "The following ResourceGroups have no tags: `n"
    $emailBody += $groupsMissingTags.ResourceGroupName -join "`n"
    Write-Host $emailBody
    # Send-MailMessage -From "ICE_Automation_Notification@ice.dhs.gov" -To "azuredashboardalerts@icegov.onmicrosoft.com" -Subject $emailsubjectline -Body $emailbody -SmtpServer $smtpserver
}

Write-Host "DONE. $((Get-Date).ToString())"
