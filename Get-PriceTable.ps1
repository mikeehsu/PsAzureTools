<#
.SYNOPSIS
Get the current prices for Azure resources.

.DESCRIPTION
Create a price table for Virtual Machines and Disks which includes the Pay-As-You-Go, Spot, Low Priority and Reserved Instance (1 Year and 3 Year) prices.

.PARAMETER Location
Specifies the location of the resource prices that you want to retrieve.

.PARAMETER Product
Specifies the product which you want to retrieve the prices for. Valid products are: VirutalMachines, Disks

.EXAMPLE
.\Get-PriceTable.ps1 -Location "West US" -Product "VirtualMachines"

.NOTES

#>
Param (
    [Parameter(Mandatory)]
    [string] $Location,

    [Parameter()]
    [ValidateSet('VirtualMachines','Disks')]
    [string] $Product = 'VirtualMachines'
)

Set-StrictMode -Version 3


$ONE_MONTH_IN_HOURS = 730

class PriceDetail {
    [string] $Name
    [float] $PaygPrice
    [float] $SpotPrice
    [float] $LowPriorityPrice
    [float] $WindowsPaygPrice
    [float] $WindowsSpotPrice
    [float] $RI1YearPrice
    [float] $RI3YearPrice
    [string] $Location
}


# SAMPLE: https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Virtual Machines' and armRegionName eq 'usgovvirginia'
$uri = 'https://prices.azure.com/api/retail/prices'

# API matches are case-sensitive
$Location = $Location.ToLower().Replace(' ','')
$Product = $Product.ToLower().Replace(' ','')

$filter = "armRegionName eq '$location' "
$productName = $null
if ($Product -eq 'virtualmachines') {
    $filter = $filter + "and serviceName eq 'Virtual Machines'"

} elseif ($Product -eq 'disks') {
    $productName = '*Disks'
    $filter = $filter + "and serviceName eq 'Storage' and meterName ne 'Disk Operations'"
}

$products = @{}
$done = $false
$nextPageLink = $null
do {
    if ($nextPageLink) {
        $prices = Invoke-RestMethod -Method Get -Uri $nextPageLink
    }
    else {
        $prices = Invoke-RestMethod -Method Get -Uri $uri -Body @{'$filter' = $filter }
    }

    foreach ($item in $prices.items) {

        if ($productName) {
            if ($item.ProductName -notlike $productName) {
                continue
            }
        }

        # parse out proper sku
        if ($Product -eq 'virtualmachines') {
            $sku = $item.armSkuName
        } elseif ($Product -eq 'disks') {
            $sku = $item.skuName
        } else {
            Write-Error 'Unsupported Product=$Product' -ErrorAction Stop
            return
        }

        $detail = $products[$sku]
        if (-not $detail) {
            $detail = [PriceDetail]::New()
            $detail.name = $sku
            $detail.location = $item.location
            $products[$sku] = $detail
        }

        if ($item.type -eq 'Consumption') {

            if ($item.unitOfMeasure -like '*Hour*') {
                $price = $item.retailPrice * $ONE_MONTH_IN_HOURS

            } elseif ($item.unitOfMeasure -like '*Month*') {
                $price = $item.retailPrice

            } else {
                Write-Host "Unknown unitofMeasure=$($item.unitOfMeasure)"
                $item
            }

            # account for different types of consumption options & licenses
            if ($item.productName -like '*Windows*') {
                if ($item.skuName -like '*Spot*') {
                    $detail.windowsSpotPrice = $price
                }
                else
                {
                    $detail.windowsPaygPrice = $price
                }
            }
            else {
                if ($item.skuName -like '*Spot*') {
                    $detail.spotPrice = $price
                }
                elseif ($item.skuName -like '*Low Priority*')
                {
                    $detail.lowPriorityPrice = $price
                }
                else {
                    $detail.paygPrice = $price
                }
            }
        }
        elseif ($item.type -eq 'Reservation') {

            if ($item.reservationTerm -eq '1 Year') {
                $detail.RI1YearPrice = $item.retailPrice / 12

            }
            elseif ($item.reservationTerm -eq '3 Years') {
                $detail.RI3YearPrice = $item.retailPrice / 36

            }
            else {
                Write-Host "Unknown reservationTerm=$($item.reservationTerm)"
            }

        }
        else {
            Write-Host "Unknown type=$($item.price)"
        }

    }

    $nextPageLink = $prices.NextPageLink

    if ($nextPageLink) {
        $null = $nextPageLink -match '(?<=\$skip\=)\d+'
        Write-Progress -Activity "Loading $product Price Table" -Status "Getting next $($matches[0])"
    }

} until (-not $nextPageLink)

Write-Progress -Activity "Loading $product Price Table" -Completed

$products.GetEnumerator() | ForEach-Object { $_.Value }
