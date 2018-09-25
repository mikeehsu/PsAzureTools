$storageResourceGroupName = 'tsa-singlesubnet'
$storageAccountName = 'testsinglesubnet'
$storageContainerName = 'testnsg'

$dbServer = 'testbillingdb.database.usgovcloudapi.net'
$dbName = 'testbillingdb'
$dbTable = 'nsgflowlog'
$userid = 'mike'
$password = 'P@$$word12345'

$batchSize = 10000

$elapsed = [System.Diagnostics.Stopwatch]::StartNew()

# connect to db
$connectionString = "Server=$dbServer;Database=$dbName;User Id=$UserId;Password=$Password"

$tableData = New-Object System.Data.DataTable
$null = $tableData.Columns.Add('Timestamp')
$null = $tableData.Columns.Add('Rule')
$null = $tableData.Columns.Add('LogId')
$null = $tableData.Columns.Add('SourceIPAddress')
$null = $tableData.Columns.Add('DestinationIPAddress')
$null = $tableData.Columns.Add('SourcePort')
$null = $tableData.Columns.Add('DestinationPort')
$null = $tableData.Columns.Add('Protocol')
$null = $tableData.Columns.Add('Direction')
$null = $tableData.Columns.Add('Action')

$tableRow = [Object[]]::new($tableData.Columns.Count)

$bulkcopy = New-Object Data.SqlClient.SqlBulkCopy($connectionstring, [System.Data.SqlClient.SqlBulkCopyOptions]::TableLock)
$bulkcopy.DestinationTableName = $dbTable
$bulkcopy.bulkcopyTimeout = 0
$bulkcopy.batchsize = $batchsize

# open storage
$storageAccountKey = Get-AzureRmStorageAccountKey -ResourceGroupName $storageResourceGroupName -AccountName $storageAccountName
$storageContext = New-AzureStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey[1].Value

# get all blobs in container
$processedTotal = 0

$blobs = Get-AzureStorageBlob -Container $storageContainerName -Context $storageContext
foreach ($blob in $blobs) {
    # download the blob
    Write-Output "Processing $($blob.Name)"
    $localPath = "$env:TEMP\$($blob.Name)"
    $result = Get-AzureStorageBlobContent -Container $storageContainerName -Blob $blob.Name -Context $storageContext -Destination $localPath -Force

    # read the log
    $log = Get-Content $localPath | ConvertFrom-Json

    $fileRowCount = 0
    $currentRecordCount = 0
    $recordCount = $log.records.Count

    foreach ($record in $log.records) {
        $currentRecordCount++
        $time = $record.time
        $nsgFlows = $record.properties.flows

        foreach ($nsgFlow in $nsgFlows) {
            $rule = $nsgFlow.rule

            foreach ($flow in $nsgFlow.flows) {
                foreach ($flowTuple in $flow.flowTUples) {
                    $tableRow = @()
                    $tableRow += $time
                    $tableRow += $rule
                    $tableRow += $($flowTuple -split ',')

                    # Write-Output "$time,$rule,$flowTuple"

                    # load the SQL datatable
                    $null = $tableData.Rows.Add($tableRow)
                    $fileRowCount++
                    if (($fileRowCount % $batchSize) -eq 0) {
                        try {
                            $bulkcopy.WriteToServer($tableData)
                        }
                        catch {
                            Write-Output "Error in file $($blob.Name)"
                            Write-Output $tableData.Rows
                            throw
                            return
                        }
                        finally {
                            $tableData.Clear()
                        }
                        $percentage = $currentRecordCount / $recordCount * 100
                        Write-Progress -Activity "Loading ..." -Status "$currentRecordCount of $recordCount added..." -PercentComplete $percentage
                    }
                }
            }
        }

    }

    # flush at end of every file
    if ($tableData.Rows.Count -gt 0) {
        $bulkcopy.WriteToServer($tableData)
        $tableData.Clear()
    }

    Remove-Item -Path $localPath -Force

    $processedTotal += $fileRowCount
    Write-Output " $fileRowCount rows processed"
}

Write-Output "$processedTotal rows inserted into the database."
Write-Output "Total Elapsed Time: $($elapsed.Elapsed.ToString())"

# Clean Up
$bulkcopy.Close()
$bulkcopy.Dispose()

[System.GC]::Collect()
