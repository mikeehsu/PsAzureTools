$reservationVms = Import-Excel c:\temp\reservationVms.xlsx

$excel = $reservationVms | Export-Excel c:\temp\test.xlsx -PassThru -AutoSize -TableName VmData

$pivotTableParams = @{
    PivotTableName  = "ByFamily"
    Address         = $excel.Sheet1.cells["N1"]
    SourceWorkSheet = $excel.Sheet1
    PivotRows       = @("Family")
    PivotData       = @{'Name'='Count'}
    PivotTableStyle = 'Light21'
}

$pt = Add-PivotTable @pivotTableParams -PassThru
#$pt.RowHeaderCaption ="By Region,Fruit,Date"
$pt.RowHeaderCaption = "By " + ($pivotTableParams.PivotRows -join ",")

Close-ExcelPackage $excel -Show


