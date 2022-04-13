<#
.SYNOPSIS
Set the auto-shutdown time for the virtual machines.

.DESCRIPTION
This script will create or update the auto-shutdown time for virtual machines. If an existing auto-shutdown schedule exists, it will be updated. At this time, the only notification option available using this script is email. Webhook may be available at a later time.

.PARAMETER ResourceGroupName
Name of the resource group.

.PARAMETER Name
Name of the virtual machine.

.PARAMETER Id
Resource ID of the virtual machine.

.PARAMETER Time
The time at which the virtual machine should be shut down. This is expressed as a number in the 24HR time format "HHMM".

.PARAMETER TimeZone
The time zone in which the scheduled time should use. If not specified it will default to UTC.

.PARAMETER NotificationEmail
The email address to send the notification to.

.PARAMETER NotificationMinutes
The number of minutes before the scheduled time to send the notification.

.PARAMETER Disable
If set to true, the auto-shutdown will be disabled. No other parameters will be processed.

.PARAMETER $DisableNotification
If set to true, the notification will be disabled.

.EXAMPLE
.\Set-VmAutoShutdown.ps1 -ResourceGroupName "MyResourceGroupName" -Name "MyVmName" -Time "1700" -TimeZone "Eastern Standard Time" -NotificationEmail "someone@somewhere.com" -NotificationMinutes "30"

.EXAMPLE
Get-AzVm | Where-Object {$_.Tags['ENVIRONMENT'] -eq 'Development'} | .\Set-VmAutoShutdown.ps1 -Time "1700" -TimeZone "Eastern Standard Time" -NotificationEmail "someone@somewhere.com" -NotificationMinutes "30"

#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, ParameterSetName="Name")]
    [string] $ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName="Name")]
    [string] $Name,

    [Parameter(Mandatory, ValueFromPipelineByPropertyName, ParameterSetName="Id")]
    [string] $Id,

    [Parameter()]
    [ValidateRange(0,2359)]
    [int] $Time,

    [Parameter()]
    [string] $Timezone,

    [Parameter()]
    [string] $NotificationEmail,

    [Parameter()]
    [ValidateRange(15,120)]
    [int] $NotificationMinutes,

#    [Parameter()]
#    [string] $notificationWebhook,

    [Parameter()]
    [switch] $Disable,

    [Parameter()]
    [switch] $DisableNotification
)

BEGIN {
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $result.Environment) {
            throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
        }
    }
    catch {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
}

PROCESS {
    Set-StrictMode -Version 2

    if ($PsCmdlet.ParameterSetName -eq "Name") {
        $subscriptionId = $context.Subscription
        $ResourceGroupName = $ResourceGroupName
        $Name = $Name
        $Id = "/subscriptions/$($subscriptionId)/resourceGroups/$($ResourceGroupName)/providers/Microsoft.Compute/$($Name)"

    } elseif ($PsCmdlet.ParameterSetName -eq "Id") {
        # SAMPLE VM ID: /subscriptions/xxxxxx-xxxxx-xxxx-xxxx-xxxxxx/resourceGroups/MyResourceGroup/providers/Microsoft.Compute/virtualMachines/MyVmName
        $dummy, $dummy, $subscriptionId, $dummy, $ResourceGroupName, $dummy, $provider, $service, $Name = $Id -split "/"
        if ($provider -ne "Microsoft.Compute") {
            throw "The Id parameter ($Id) must be a valid Azure Compute Resource Id"
        }

    } else {
        throw "Please specify a valid parameter set name."
    }

    $newResource = $false
    $shutdownResourceId = "/subscriptions/$($subscriptionId)/resourceGroups/$($ResourceGroupName)/providers/microsoft.devtestlab/schedules/shutdown-computevm-$($Name)"
    $resource = Get-AzResource -ResourceId $shutdownResourceId -ErrorAction SilentlyContinue
    if (-not $resource) {
        if ($Disable) {
            Write-Verbose "No shutdown schedule for $ResourceGroupe/$Name found."
            return
        }
        $newResource = $true

    } else {
        $properties = $resource.Properties
    }

    if ($Disable) {
        # disable existing schedule
        $properties.status = 'Disabled'
        $resource = Set-AzResource -ResourceId $shutdownResourceId -Properties $properties -Force
        Write-Host "Shutdown schedule for $ResourceGroupName/$Name has been disabled."
        return
    }

    if ($newResource) {
        # create a new schedule
        # validate required parameters for new schedule
        if (-not  $Time){
            throw "Please specify a valid time (HHMM) for new shutdown."
            return
        }

        if (-not $Timezone) {
            $Timezone = "UTC"
        }

        $properties = @{}
        $properties.Add('targetResourceId', $Id)
        $properties.Add('status', 'Enabled')
        $Properties.Add('taskType', 'ComputeVmShutdownTask')
        $Properties.Add('dailyRecurrence', @{'time'= $Time})
        $Properties.Add('timeZoneId', $Timezone)

        if ($NotificationEmail) {
            if (-not $NotificationMinutes) {
                $NotificationMinutes= 30
            }

            $Properties.Add('notificationSettings', @{'status'='Enabled'; 'timeInMinutes'= $NotificationMinutes; 'emailRecipient'= $NotificationEmail})
        }

        $resource = New-AzResource -ResourceId $shutdownResourceId -Location $vm.Location -Properties $properties -Force
        Write-Verbose "New schedule shutdown created for $ResourceGroupName/$Name"
        return
    }

    # update existing schedule
    $properties.status = 'Enabled'

    if ($Time) {
        $properties.dailyRecurrence.time = $Time
    }

    if ($Timezone) {
        $properties.timeZoneId = $Timezone
    }

    if ($DisableNotification) {
        if ($NotificationEmail -or $NotificationMinutes) {
            throw "Incompatible parameters either -DisableNotification or -NotificationEmail/-NotificationMinutes but not both."
            return
        }

        $properties.notificationSettings.status = 'Disabled'
    } else {
        if ($NotificationEmail) {
            $properties.notificationSettings.status = 'Enabled'
            $properties.notificationSettings.emailRecipient = $notificationEmail
        }

        if ($NotificationMinutes) {
            $properties.notificationSettings.status = 'Enabled'
            $properties.notificationSettings.timeInMinutes = $NotificationMinutes
        }

        if ($properties.notificationSettings.timeInMinutes -lt 15 -or $properties.notificationSettings.timeInMinutes -gt 120) {
            # in some cases timeInMinutes may have previously been set to an invalid value - default to 30 mins
            $properties.notificationSettings.timeInMinutes = 30
        }
    }

    $resource = Set-AzResource -ResourceId $shutdownResourceId -Properties $properties -Force
    Write-Verbose "Shutdown schedule for $ResourceGroupName/$Name has been updated."
    return
}

END {

}
