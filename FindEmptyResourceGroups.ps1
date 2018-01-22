# confirm user is logged into subscription
try {
    $result = Get-AzureRmContext -ErrorAction Stop
    if (! $result.Environment) {
        Write-Error "Please login (Login-AzureRmAccount) and set the proper subscription context before proceeding."
        exit
    }

} catch {
    Write-Error "Please login and set the proper subscription context before proceeding."
    exit
}

$definedGroups = Get-AzureRmResourceGroup | Select-Object -Property ResourceGroupName | Sort-Object -Property ResourceGroupname -Unique

$usedGroups = Get-AzureRmResource | Select-Object -Property ResourceGroupName | Sort-Object -Property ResourceGroupname -Unique

$emptyGroups = Compare-Object -ReferenceObject $definedGroups.ResourceGroupName -DifferenceObject $usedGroups.ResourceGroupName
if ($emptyGroups) {
    Write-Output "Empty Resource Groups:"
    Write-Output $emptyGroups.InputObject
} else {
    Write-Output "No empty Resource Groups found"
}
