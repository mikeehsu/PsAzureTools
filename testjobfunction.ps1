[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $Name
)


function somefunc () {
 param (
     $name
 )
    Write-Output "hello $name" 2>&1 >> c:\temp\tmp.tmp
    write-output " here some output"  2>&1 >> c:\temp\tmp.tmp
    Write-error ' heres an error'  2>&1 >> c:\temp\tmp.tmp
    & c:\utils\7z.exe -name test 2>&1 >> c:\temp\tmp.tmp
}

Write-Host "starting...$Name"

$initScript = [ScriptBlock]::Create((Get-Command somefunc).ScriptBlock.StartPosition.Content)
start-job -InitializationScript $initScript -ScriptBlock {somefunc -name $using:Name}

start-sleep 3
$output = get-job | Receive-Job
Write-Output "========== job output"
Write-Output $output
get-job | Remove-Job
