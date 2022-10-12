
function ExecuteWorkspacePoolAction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $WorkspaceName,

        [Parameter()]
        [string[]] $SqlPoolName,


        [ValidateSet(“Stop”,"Start")]
        [Parameter(Mandatory)]
        [string] $Action
    )

    $workspace = Get-AzSynapseWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName
    if (-not $workspace) {
        Write-Error "Workspace ($ResourceGroupname/$WorkspaceName) not found"
        return
    }

    $sqlPools = Get-AzSynapseSqlPool -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    if ($sqlPools -and $SqlPoolName) {
        $sqlPools = $sqlPools | Where-Object {$SqlPoolName -contains $_.SqlPoolName}
        if (-not $sqlPools) {
            Write-Warning "No SQL Pools found matching $($SqlPoolName)"
            return
        }
    }

    if (-not $sqlPools) {
        Write-Warning "No SQL Pools found"
        return
    }

    # Loop through the SQL Pools
    foreach ($sqlPool in $sqlPools) {
        if ($Action -eq 'Stop') {
            if ($sqlPool.Status -eq 'Paused') {
                Write-Host "$($WorkspaceName)/$($sqlPool.SqlPoolName) already paused"
                continue
            }

            Write-Host "Stopping $($WorkspaceName)/$($sqlPool.SqlPoolName)"
            $result = Suspend-AzSynapseSqlPool -WorkspaceName $WorkspaceName -Name $sqlPool.SqlPoolName

        } elseif ($Action -eq 'Start') {
            if ($sqlPool.Status -eq 'Online' -or $sqlPool.Status -eq 'Resuming') {
                Write-Host "$($WorkspaceName)/$($sqlPool.SqlPoolName) already started"
                continue
            }

            Write-Host "Starting $($WorkspaceName)/$($sqlPool.SqlPoolName)"
            $result = Resume-AzSynapseSqlPool -WorkspaceName $WorkspaceName -Name $sqlPool.SqlPoolName

        }
    }

}

# ExecuteWorkspacePoolAction -ResourceGroupName "hokiesynapsedemo" -WorkspaceName "hokiesynapsews" -Action Stop
# ExecuteWorkspacePoolAction -ResourceGroupName "hokiesynapsedemo" -WorkspaceName "hokiesynapsews" -Action Start -SqlPoolName 'hokiesqlpool01'