# monitor.ps1 - USB Device Removal Warning Monitor
#
# All settings live in config.json next to this script.
# Produce one with generator.html, or just edit config.json by hand - this
# script is fixed and does not need to be regenerated when settings change.

# Auto-unblock files in this folder (in case downloaded from browser / copied from network share)
Get-ChildItem $PSScriptRoot -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ config --

$configPath = Join-Path $PSScriptRoot 'config.json'

if (-not (Test-Path $configPath)) {
    Write-Host "[Error] config.json not found next to monitor.ps1." -ForegroundColor Red
    Write-Host "        Expected at: $configPath"
    Write-Host "        Generate one with generator.html, then put it in this folder."
    exit 1
}

try {
    $cfg = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[Error] config.json is not valid JSON: $_" -ForegroundColor Red
    exit 1
}

function Get-Setting {
    param([string] $Name, $Default)

    $prop = $cfg.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    if ($prop.Value -is [string] -and $prop.Value.Trim() -eq '') { return $Default }
    return $prop.Value
}

$serverUrl        = [string](Get-Setting 'serverUrl' 'https://localhost:8443/api/usb-event')
$apiKey           = [string](Get-Setting 'apiKey' '')
$computerId       = [string](Get-Setting 'computerName' $env:COMPUTERNAME)
$pollSeconds      = [int]   (Get-Setting 'pollSeconds' 3)
$soundSetting     = [string](Get-Setting 'sound' 'Alarm')
$soundLoopSeconds = [int]   (Get-Setting 'soundLoopSeconds' 0)
$urgent           = [bool]  (Get-Setting 'urgent' $true)
$skipCertCheck    = [bool]  (Get-Setting 'skipCertificateCheck' $false)
$identifyBy       = [string](Get-Setting 'identifyBy' 'auto')

# watchIds is the current name; watchSerials is still honoured for older configs.
$watchList = @(Get-Setting 'watchIds' @())
if ($watchList.Count -eq 0) { $watchList = @(Get-Setting 'watchSerials' @()) }

if ($pollSeconds -lt 1) { $pollSeconds = 1 }

if ($identifyBy -notin @('auto', 'serial', 'diskId')) {
    Write-Host "[Warning] Unknown identifyBy '$identifyBy', falling back to 'auto'." -ForegroundColor Yellow
    $identifyBy = 'auto'
}

# An empty list means "watch every USB disk". Otherwise only the listed
# identifiers are monitored and reported.
$watchSet = @{}
foreach ($s in $watchList) {
    $key = "$s".Trim().Trim('{', '}')
    if ($key -ne '') { $watchSet[$key.ToUpperInvariant()] = $true }
}
$watchAll = ($watchSet.Count -eq 0)

# --------------------------------------------------------------------- TLS --

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

if ($skipCertCheck) {
    Write-Host "[Warning] TLS certificate validation is DISABLED (skipCertificateCheck = true)." -ForegroundColor Yellow
    Write-Host "          Only acceptable on a trusted LAN with a self-signed certificate."
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# ------------------------------------------------------------------- sound --

$builtInSounds = @(
    'Default', 'IM', 'Mail', 'Reminder', 'SMS',
    'Alarm', 'Alarm2', 'Alarm3', 'Alarm4', 'Alarm5',
    'Alarm6', 'Alarm7', 'Alarm8', 'Alarm9', 'Alarm10',
    'Call', 'Call2', 'Call3', 'Call4', 'Call5',
    'Call6', 'Call7', 'Call8', 'Call9', 'Call10'
)

# 'Silent' / a built-in name / a path to an audio file.
# Custom files are played by this script (SoundPlayer or Windows Media Player)
# rather than by the toast, because Windows silently falls back to the default
# sound when a toast's custom audio cannot be loaded.
$soundMode       = 'BuiltIn'
$soundName       = 'Alarm'
$customSoundPath = $null

if ($soundSetting -eq 'Silent') {
    $soundMode = 'Silent'
} elseif ($builtInSounds -contains $soundSetting) {
    $soundMode = 'BuiltIn'
    $soundName = $soundSetting
} else {
    $candidate = $soundSetting
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $PSScriptRoot $candidate
    }

    if (Test-Path $candidate) {
        $soundMode       = 'Custom'
        $customSoundPath = (Resolve-Path $candidate).Path
    } else {
        Write-Host "[Warning] Custom sound file not found: $candidate" -ForegroundColor Yellow
        Write-Host "          Falling back to the built-in 'Alarm' sound."
        $soundMode = 'BuiltIn'
        $soundName = 'Alarm'
    }
}

$script:WavPlayer   = $null
$script:ComPlayer   = $null
$script:SoundStopAt = $null
$script:WavStream   = $null

# Read the .wav into memory now rather than at alarm time. If the script is run
# from the drive it is watching, the file vanishes at the exact moment the alarm
# is needed - and even on a local disk this avoids disk I/O in that path.
if ($soundMode -eq 'Custom' -and [System.IO.Path]::GetExtension($customSoundPath).ToLower() -eq '.wav') {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($customSoundPath)
        $script:WavStream = New-Object System.IO.MemoryStream (, $bytes)
        $probe = New-Object System.Media.SoundPlayer $script:WavStream
        $probe.Load()
        $probe.Dispose()
    } catch {
        Write-Host "[Warning] Could not preload '$customSoundPath': $_" -ForegroundColor Yellow
        Write-Host "          Falling back to reading it when the alarm fires." -ForegroundColor Yellow
        $script:WavStream = $null
    }
}

function Stop-AlarmSound {
    if ($script:WavPlayer) {
        try { $script:WavPlayer.Stop() } catch { }
        $script:WavPlayer = $null
    }
    if ($script:ComPlayer) {
        try { $script:ComPlayer.controls.stop() } catch { }
        $script:ComPlayer = $null
    }
    $script:SoundStopAt = $null
}

function Start-AlarmSound {
    if ($soundMode -ne 'Custom') { return }

    Stop-AlarmSound
    $loop = ($soundLoopSeconds -ne 0)

    try {
        if ([System.IO.Path]::GetExtension($customSoundPath).ToLower() -eq '.wav') {
            if ($script:WavStream) {
                $script:WavStream.Position = 0
                $script:WavPlayer = New-Object System.Media.SoundPlayer $script:WavStream
            } else {
                $script:WavPlayer = New-Object System.Media.SoundPlayer $customSoundPath
            }
            if ($loop) { $script:WavPlayer.PlayLooping() } else { $script:WavPlayer.Play() }
        } else {
            # .mp3 / .wma / etc. via the Windows Media Player COM object
            $script:ComPlayer = New-Object -ComObject WMPlayer.OCX
            $script:ComPlayer.settings.setMode('loop', $loop)
            $script:ComPlayer.URL = $customSoundPath
            $script:ComPlayer.controls.play()
        }

        if ($loop -and $soundLoopSeconds -gt 0) {
            $script:SoundStopAt = (Get-Date).AddSeconds($soundLoopSeconds)
        }
    } catch {
        Write-Host "  [Warning] Could not play custom sound: $_" -ForegroundColor Yellow
        Stop-AlarmSound
    }
}

function Test-AlarmAcknowledged {
    # Any keypress in this console stops a looping alarm.
    if (-not ($script:WavPlayer -or $script:ComPlayer)) { return }

    try {
        if ([Console]::KeyAvailable) {
            [Console]::ReadKey($true) | Out-Null
            Write-Host "  Alarm acknowledged."
            Stop-AlarmSound
            return
        }
    } catch {
        # stdin is redirected - no interactive acknowledgement available
    }

    if ($script:SoundStopAt -and (Get-Date) -ge $script:SoundStopAt) {
        Stop-AlarmSound
    }
}

# ------------------------------------------------------------------- toast --

$modulePath  = Join-Path $PSScriptRoot 'Modules\BurntToast\BurntToast.psd1'
$toastLoaded = $false

if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue
    $toastLoaded = [bool](Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue)
}

if (-not $toastLoaded) {
    Write-Host "[Warning] BurntToast module not found, toast notifications are disabled." -ForegroundColor Yellow
}

function Show-RemovalToast {
    param($Disk)

    if (-not $toastLoaded) { return }

    $params = @{
        Text        = @('USB Device Removed', "$($Disk.FriendlyName) (ID: $(Get-DiskKey $Disk))")
        ErrorAction = 'SilentlyContinue'
    }

    if ($urgent) { $params['Urgent'] = $true }

    if ($soundMode -eq 'BuiltIn') {
        $params['Sound'] = $soundName
    } else {
        # Silent mode, or a custom file this script plays itself
        $params['Silent'] = $true
    }

    New-BurntToastNotification @params
}

# ----------------------------------------------------------------- reporting --

function Send-Event {
    param($Disk, [string] $EventName)

    # diskId is included because serial is unreliable - cheap enclosures report
    # one shared placeholder for a whole batch, which would make every site's
    # events look identical on the server.
    $payload = @{
        computer  = $computerId
        model     = $Disk.FriendlyName
        diskId    = Get-DiskId $Disk
        serial    = "$($Disk.SerialNumber)".Trim()
        timestamp = (Get-Date).ToString('o')
        event     = $EventName
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Uri $serverUrl -Method Post -Body $payload `
            -ContentType 'application/json; charset=utf-8' `
            -Headers @{ 'Authorization' = "Bearer $apiKey" } -TimeoutSec 5 | Out-Null

        Write-Host "  Reported [$EventName]: $($Disk.FriendlyName) - $(Get-DiskKey $Disk)"
    } catch {
        Write-Host "  Report failed: $_" -ForegroundColor Yellow
        $payload | Out-File -Append -Encoding UTF8 (Join-Path $PSScriptRoot 'failed-events.log')
    }
}

# --------------------------------------------------------------- monitoring --

function Get-USBDisks {
    Get-Disk -ErrorAction Stop |
        Where-Object { $_.BusType -eq 'USB' } |
        Select-Object Number, FriendlyName, SerialNumber, Guid, Signature, PartitionStyle
}

function Get-DiskId {
    param($Disk)

    # The GPT disk GUID and the MBR signature live in the partition table on the
    # disk itself, so unlike a bridge-chip serial they are genuinely per-drive
    # and follow it between ports and machines.
    if ($Disk.Guid) { return "$($Disk.Guid)".Trim().Trim('{', '}').ToUpperInvariant() }
    if ($Disk.Signature) { return 'SIG-{0:X8}' -f [uint32]$Disk.Signature }
    return $null
}

function Get-DiskSerialId {
    param($Disk)

    $sn = "$($Disk.SerialNumber)".Trim()
    if ($sn -ne '') { return $sn.ToUpperInvariant() }
    return $null
}

function Get-DiskKey {
    param($Disk)

    switch ($identifyBy) {
        'serial' { $id = Get-DiskSerialId $Disk }
        'diskId' { $id = Get-DiskId $Disk }
        default  {
            $id = Get-DiskId $Disk
            if (-not $id) { $id = Get-DiskSerialId $Disk }
        }
    }

    if ($id) { return $id }
    return "disk$($Disk.Number)|$($Disk.FriendlyName)"
}

function Get-DiskMap {
    param($Disks)

    # Cheap USB enclosures often hand out one serial for a whole production run,
    # so a key maps to a list of disks rather than a single disk. Counting is
    # what detects arrivals and removals when identity cannot tell units apart -
    # keying on the serial alone would collapse them and miss the removal.
    $map = @{}
    foreach ($d in $Disks) {
        $k = Get-DiskKey $d
        if (-not $map.ContainsKey($k)) { $map[$k] = New-Object System.Collections.ArrayList }
        [void]$map[$k].Add($d)
    }
    return $map
}

function Get-DiskDelta {
    param($From, $To)

    # Disks present in $From more often than in $To, one entry per lost copy.
    $lost = New-Object System.Collections.ArrayList
    foreach ($k in $From.Keys) {
        $before = $From[$k].Count
        $after  = if ($To.ContainsKey($k)) { $To[$k].Count } else { 0 }
        for ($i = 0; $i -lt ($before - $after); $i++) { [void]$lost.Add($From[$k][$i]) }
    }
    return @($lost)
}

function Test-Watched {
    param($Disk)

    if ($watchAll) { return $true }

    # Match on either identifier so a list of serials and a list of disk IDs
    # both work, and the two can be mixed while migrating a config.
    foreach ($candidate in @((Get-DiskId $Disk), (Get-DiskSerialId $Disk))) {
        if ($candidate -and $watchSet.ContainsKey($candidate)) { return $true }
    }
    return $false
}

function Get-WatchedDisks {
    @(Get-USBDisks | Where-Object { Test-Watched $_ })
}

try {
    $allDisks      = @(Get-USBDisks)
    $previousDisks = @($allDisks | Where-Object { Test-Watched $_ })
} catch {
    Write-Host "[Error] Could not query disks. Run this script as Administrator. ($_)" -ForegroundColor Red
    exit 1
}

$soundLabel = switch ($soundMode) {
    'Custom' { "$customSoundPath$(if ($soundLoopSeconds -ne 0) { ' (looping)' })" }
    'Silent' { 'silent' }
    default  { "built-in '$soundName'" }
}

$scopeLabel = if ($watchAll) { 'every USB disk' } else { "$($watchSet.Count) listed identifier(s)" }

Write-Host "============================================"
Write-Host " USB monitoring started for [$computerId]"
Write-Host " Server : $serverUrl"
Write-Host " Poll   : every $pollSeconds second(s)"
Write-Host " Alarm  : $soundLabel"
Write-Host " Scope  : $scopeLabel"
Write-Host "============================================"

# Always list every USB disk, watched or not - this is how you look up the
# identifiers to put in config.json's watchIds.
Write-Host "USB disks currently attached: $($allDisks.Count)"
foreach ($d in $allDisks) {
    $mark   = if (Test-Watched $d) { '[watching]' } else { '[ignored] ' }
    $diskId = Get-DiskId $d
    Write-Host "  $mark $($d.FriendlyName)"
    Write-Host "             diskId: $(if ($diskId) { $diskId } else { '(disk not initialised)' })"
    Write-Host "             serial: $(if ($d.SerialNumber) { "$($d.SerialNumber)".Trim() } else { '(none)' })"
    Write-Host "             key   : $(Get-DiskKey $d)"
}

# Two attached disks sharing an identity cannot be told apart. Removals are
# still detected by counting, but the alert cannot say which unit went.
$sharedKeys = $allDisks | Group-Object { Get-DiskKey $_ } | Where-Object { $_.Count -gt 1 }

foreach ($g in $sharedKeys) {
    Write-Host "[Warning] $($g.Count) attached disks share the identity '$($g.Name)'." -ForegroundColor Yellow
    Write-Host "          Removals are still detected, but they cannot be told apart." -ForegroundColor Yellow
    if ($identifyBy -eq 'serial') {
        Write-Host "          Try identifyBy = 'auto' to use the disk GUID instead." -ForegroundColor Yellow
    }
}

if (-not $watchAll) {
    $present = @{}
    foreach ($d in $allDisks) {
        foreach ($candidate in @((Get-DiskId $d), (Get-DiskSerialId $d))) {
            if ($candidate) { $present[$candidate] = $true }
        }
    }
    $missing = @($watchSet.Keys | Where-Object { -not $present.ContainsKey($_) })

    if ($missing.Count -eq $watchSet.Count -and $allDisks.Count -gt 0) {
        Write-Host "[Warning] None of the identifiers in watchIds are attached right now." -ForegroundColor Yellow
        Write-Host "          Check for typos - the attached disks are listed above." -ForegroundColor Yellow
    } elseif ($missing.Count -gt 0) {
        Write-Host "[Note] Not attached yet: $($missing -join ', ')"
    }
}

Write-Host ""

while ($true) {
    Start-Sleep -Seconds $pollSeconds
    Test-AlarmAcknowledged

    try {
        $currentDisks = Get-WatchedDisks
    } catch {
        # A transient Get-Disk failure would otherwise look like every device
        # was removed at once, so skip the cycle instead of raising alarms.
        Write-Host "[Warning] Get-Disk failed, skipping this cycle: $_" -ForegroundColor Yellow
        continue
    }

    $prevMap = Get-DiskMap $previousDisks
    $currMap = Get-DiskMap $currentDisks

    # PowerShell unrolls a single-element return into a scalar, so re-wrap.
    $added   = @(Get-DiskDelta -From $currMap -To $prevMap)
    $removed = @(Get-DiskDelta -From $prevMap -To $currMap)

    foreach ($disk in $added) {
        Write-Host "Device connected: $($disk.FriendlyName) - $(Get-DiskKey $disk)"
        Send-Event -Disk $disk -EventName 'connected'
    }

    foreach ($disk in $removed) {
        Write-Host "Device REMOVED: $($disk.FriendlyName) - $(Get-DiskKey $disk)" -ForegroundColor Red
        Show-RemovalToast -Disk $disk
        Start-AlarmSound
        Send-Event -Disk $disk -EventName 'removed'
    }

    $previousDisks = $currentDisks
}