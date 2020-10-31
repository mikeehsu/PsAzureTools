# only supported with Powershell .NET framework
# needs ParsedHTML support in order to parse tables

[CmdletBinding()]
param (
    [Parameter()]
    [string] $Url = 'https://aws.amazon.com/ec2/instance-types/'
)

if ($PSVersionTable.PSVersion.Major -ge 6) {
    Write-Error "This script currently only runs under Windows Powershell due to its use of ParsedHtml functions"
    return
}

class VmInstance {
    [string] $instance
    [string] $vcpu
    [string] $memory
    [string] $storage
    [string] $network
}
$vms = @()

$page = Invoke-WebRequest $Url

$tables = $page.ParsedHtml.body.getElementsByTagName('Table')

for ($t = 0; $t -lt $tables.Length - 2; $t++) {
    Write-Progress -Activity "Parsing data..." -PercentComplete $($t / $tables.Length * 100)

    $table = $tables[$t]
    foreach ($row in $($table.rows | Select-Object -Skip 1)) {
        $vm = [VmInstance]::New()
        $vm.instance = $row.cells[0].innerText
        $vm.vcpu = $row.cells[1].innerText
        $vm.memory = $row.cells[2].innerText
        $vm.storage = $row.cells[3].innerHTML
        $vm.network = $row.cells[4].innerHTML
        $vms += $vm
    }
}

$vms | ft