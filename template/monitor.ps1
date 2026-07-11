
# 請在此修改 API
# ---------------------------------------------------
$serverUrl = "https://localhost:8443/api/usb-event"
$apiKey = "your-secret-api-key-here"
# ---------------------------------------------------

# 其他可以自定義參數
# ---------------------------------------------------
$alarmType = 'Alarm1'

# ---------------------------------------------------


# 用相對路徑載入本地的 BurntToast 模組
$modulePath = Join-Path $PSScriptRoot "Modules\BurntToast\BurntToast.psd1"
Import-Module $modulePath -Force

[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

function Get-USBDisks {
    Get-Disk | Where-Object { $_.BusType -eq "USB" } | Select-Object Number, FriendlyName, SerialNumber
}

$previousDisks = Get-USBDisks
Write-Host "USB monitoring started. Detected $($previousDisks.Count) USB device(s):"
$previousDisks | ForEach-Object { Write-Host "  - $($_.FriendlyName) ($($_.SerialNumber))" }

while ($true) {
    Start-Sleep -Seconds 3
    $currentDisks = Get-USBDisks

    $removed = $previousDisks | Where-Object {
        $sn = $_.SerialNumber
        -not ($currentDisks | Where-Object { $_.SerialNumber -eq $sn })
    }

    $added = $currentDisks | Where-Object {
        $sn = $_.SerialNumber
        -not ($previousDisks | Where-Object { $_.SerialNumber -eq $sn })
    }

    foreach ($disk in $added) {
        Write-Host "Device connected: $($disk.FriendlyName) - $($disk.SerialNumber)"

        $payload = @{
            computer  = $env:COMPUTERNAME
            model     = $disk.FriendlyName
            serial    = $disk.SerialNumber
            timestamp = (Get-Date).ToString("o")
            event     = "connected"
        } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $serverUrl `
                -Method Post -Body $payload -ContentType "application/json" `
                -Headers @{ "Authorization" = "Bearer $apiKey" } -TimeoutSec 5

            Write-Host "Reported: $($disk.FriendlyName) - $($disk.SerialNumber)"
        } catch {
            Write-Host "Report failed: $_"
            $payload | Out-File -Append "failed-events.log"
        }
    }

    foreach ($disk in $removed) {
        New-BurntToastNotification -Text "USB Device Removed", "$($disk.FriendlyName) (Serial: $($disk.SerialNumber))" -Sound Alarm

        $payload = @{
            computer  = $env:COMPUTERNAME
            model     = $disk.FriendlyName
            serial    = $disk.SerialNumber
            timestamp = (Get-Date).ToString("o")
            event     = "removed"
        } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $serverUrl `
                -Method Post -Body $payload -ContentType "application/json" `
                -Headers @{ "Authorization" = "Bearer $apiKey" } -TimeoutSec 5

            Write-Host "Reported: $($disk.FriendlyName) - $($disk.SerialNumber)"
        } catch {
            Write-Host "Report failed: $_"
            $payload | Out-File -Append "failed-events.log"
        }
    }

    $previousDisks = $currentDisks
}