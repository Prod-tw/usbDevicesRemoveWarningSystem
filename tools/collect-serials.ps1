# collect-serials.ps1 - Discover USB disk serial numbers for the deploy table.
#
# Run this once on a staging machine and plug the drives in one at a time;
# every newly attached disk is printed as a ready-to-paste table row.
#
#   .\collect-serials.ps1                     list what is attached right now
#   .\collect-serials.ps1 -Watch              keep running, report each insertion
#   .\collect-serials.ps1 -Watch -OutFile ..\deploy-table.csv
#
# Rows are appended to -OutFile as they are discovered, so a Ctrl+C at any
# point still leaves a usable file. Fill in the deployAt column afterwards.

param(
    [switch] $Watch,
    [switch] $Detail,
    [string] $OutFile,
    [int]    $PollSeconds = 2,
    [string] $DeployAt = ''
)

if ($PollSeconds -lt 1) { $PollSeconds = 1 }

function Get-USBDisks {
    Get-Disk -ErrorAction Stop |
        Where-Object { $_.BusType -eq 'USB' } |
        Select-Object Number, FriendlyName, SerialNumber, Guid, Signature, PartitionStyle
}

function Get-Serial {
    param($Disk)
    return "$($Disk.SerialNumber)".Trim()
}

function Get-DiskId {
    param($Disk)

    # Lives in the partition table on the disk, so it follows the drive rather
    # than the enclosure - the identifier to prefer when serials collide.
    if ($Disk.Guid) { return "$($Disk.Guid)".Trim().Trim('{', '}').ToUpperInvariant() }
    if ($Disk.Signature) { return 'SIG-{0:X8}' -f [uint32]$Disk.Signature }
    return $null
}

function Get-DiskKey {
    param($Disk)

    $id = Get-DiskId $Disk
    if ($id) { return $id }
    $sn = Get-Serial $Disk
    if ($sn -ne '') { return $sn.ToUpperInvariant() }
    return "disk$($Disk.Number)|$($Disk.FriendlyName)"
}

# Serials that cheap USB-SATA bridges hand out instead of a real per-unit value.
$suspectSerials = @(
    '000000000000', '0000000000000000', '123456789012',
    '0123456789ABCDEF', '000000000001', '0000'
)

function Test-SuspectSerial {
    param([string] $Serial)

    if ($Serial -eq '') { return 'no serial reported' }
    if ($suspectSerials -contains $Serial.ToUpperInvariant()) { return 'known placeholder serial' }
    if ($Serial -match '^0+$') { return 'all zeros' }
    if ($Serial.Length -lt 6) { return 'suspiciously short' }
    return $null
}

# ------------------------------------------------------------------- output --

$script:Written = @{}

function Write-Row {
    param($Disk)

    $serial = Get-Serial $Disk
    $diskId = Get-DiskId $Disk
    $note   = Test-SuspectSerial $serial

    Write-Host "  $($Disk.FriendlyName)"
    Write-Host "    diskId : $(if ($diskId) { $diskId } else { '(disk not initialised)' })"

    if ($note) {
        Write-Host "    serial : $(if ($serial -eq '') { '(none)' } else { $serial })  <- $note" -ForegroundColor Yellow
    } else {
        Write-Host "    serial : $serial"
    }

    if ($OutFile) {
        $row = [PSCustomObject]@{
            deployAt = $DeployAt
            ssdName  = $Disk.FriendlyName
            diskIds  = $diskId
            serials  = $serial
        }
        $row | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8 -Append
    }
}

# ------------------------------------------------------------------ initial --

try {
    $disks = @(Get-USBDisks)
} catch {
    Write-Host "[Error] Could not query disks. Run as Administrator. ($_)" -ForegroundColor Red
    exit 1
}

if ($OutFile -and -not (Test-Path $OutFile)) {
    # Export-Csv -Append needs the file to exist with matching headers, or it
    # creates it on first write - either way this just reports where it goes.
    Write-Host "Writing rows to: $OutFile"
}

Write-Host "============================================"
Write-Host " USB disks attached right now: $($disks.Count)"
Write-Host "============================================"

foreach ($d in $disks) {
    $script:Written[(Get-DiskKey $d)] = $true
    Write-Row $d
}

# Two physically different disks reporting the same serial is exactly the cheap
# enclosure failure mode - watchSerials cannot tell them apart.
$dupes = $disks |
    Where-Object { (Get-Serial $_) -ne '' } |
    Group-Object { (Get-Serial $_).ToUpperInvariant() } |
    Where-Object { $_.Count -gt 1 }

foreach ($g in $dupes) {
    Write-Host ""
    Write-Host "[Warning] $($g.Count) attached disks share the serial '$($g.Name)':" -ForegroundColor Yellow
    $g.Group | ForEach-Object { Write-Host "            - disk $($_.Number)  $($_.FriendlyName)" -ForegroundColor Yellow }
    Write-Host "          The enclosure is not handing out per-unit serials." -ForegroundColor Yellow
    Write-Host "          Use the diskId instead - see identifyBy in the README." -ForegroundColor Yellow
}

# Duplicate disk IDs are the serious case: the partition table itself is a copy,
# which happens when drives are cloned from one image. Nothing on the disk can
# tell them apart until one of them is repartitioned.
$idDupes = $disks |
    Where-Object { (Get-DiskId $_) } |
    Group-Object { Get-DiskId $_ } |
    Where-Object { $_.Count -gt 1 }

foreach ($g in $idDupes) {
    Write-Host ""
    Write-Host "[Warning] $($g.Count) attached disks share the diskId '$($g.Name)':" -ForegroundColor Red
    $g.Group | ForEach-Object { Write-Host "            - disk $($_.Number)  $($_.FriendlyName)" -ForegroundColor Red }
    Write-Host "          These disks were almost certainly cloned from one image." -ForegroundColor Red
    Write-Host "          Repartition or reformat one of them to get a fresh GUID." -ForegroundColor Red
}

# ------------------------------------------------------------------ detail --

# When a batch of enclosures shares one serial, some other field may still tell
# the units apart. Dump every candidate so we can see which one actually varies.
if ($Detail) {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " Full identifiers for every attached USB disk"
    Write-Host " Plug in two of the identical units, then compare the fields below."
    Write-Host "============================================"

    $pnp = @{}
    try {
        foreach ($d in Get-CimInstance Win32_DiskDrive -ErrorAction Stop) {
            $pnp[[int]$d.Index] = $d.PNPDeviceID
        }
    } catch {
        Write-Host "[Warning] Could not read Win32_DiskDrive: $_" -ForegroundColor Yellow
    }

    foreach ($d in @(Get-Disk | Where-Object { $_.BusType -eq 'USB' })) {
        Write-Host ""
        Write-Host "  Disk $($d.Number)  $($d.FriendlyName)"
        Write-Host "    SerialNumber : $($d.SerialNumber)"
        Write-Host "    UniqueId     : $($d.UniqueId)"
        Write-Host "    Signature    : $($d.Signature)"
        Write-Host "    Guid         : $($d.Guid)"
        Write-Host "    Path         : $($d.Path)"
        Write-Host "    PNPDeviceID  : $($pnp[[int]$d.Number])"
    }

    Write-Host ""
    Write-Host "Any field that differs between two identical units can identify them."
    Write-Host "Note that Path and PNPDeviceID may encode the USB port, so they change"
    Write-Host "if the drive is moved to another port."
    Write-Host ""
}

if (-not $Watch) {
    Write-Host ""
    if (-not $Detail) {
        Write-Host "Tip: -Watch captures drives as you plug them in one by one."
        Write-Host "     -Detail dumps every identifier field for the attached disks."
    }
    exit 0
}

# -------------------------------------------------------------------- watch --

Write-Host ""
Write-Host "Watching for new USB disks - plug them in one at a time. Ctrl+C to stop."
Write-Host ""

$seenSerials = @{}
$seenIds     = @{}
foreach ($d in $disks) {
    $sn = Get-Serial $d
    if ($sn -ne '') { $seenSerials[$sn.ToUpperInvariant()] = $d.FriendlyName }
    $id = Get-DiskId $d
    if ($id) { $seenIds[$id] = $d.FriendlyName }
}

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    try {
        $current = @(Get-USBDisks)
    } catch {
        Write-Host "[Warning] Get-Disk failed, retrying: $_" -ForegroundColor Yellow
        continue
    }

    foreach ($d in $current) {
        $key = Get-DiskKey $d
        if ($script:Written.ContainsKey($key)) { continue }

        $script:Written[$key] = $true
        Write-Host "New device:"
        Write-Row $d

        # Same serial as a drive seen earlier in this session, different unit.
        $sn = Get-Serial $d
        if ($sn -ne '') {
            $u = $sn.ToUpperInvariant()
            if ($seenSerials.ContainsKey($u)) {
                Write-Host "  [Warning] This serial was already reported by '$($seenSerials[$u])'." -ForegroundColor Yellow
                Write-Host "            The enclosure is not handing out per-unit serials," -ForegroundColor Yellow
                Write-Host "            so identify these drives by diskId instead." -ForegroundColor Yellow
            } else {
                $seenSerials[$u] = $d.FriendlyName
            }
        }

        # This is the check that matters: a repeated diskId means the drives were
        # cloned, and then nothing on the disk can tell them apart.
        $id = Get-DiskId $d
        if ($id) {
            if ($seenIds.ContainsKey($id)) {
                Write-Host "  [Warning] This diskId was already reported by '$($seenIds[$id])'." -ForegroundColor Red
                Write-Host "            These drives were cloned from one image - repartition" -ForegroundColor Red
                Write-Host "            one of them to get a fresh GUID." -ForegroundColor Red
            } else {
                $seenIds[$id] = $d.FriendlyName
            }
        } else {
            Write-Host "  [Warning] This disk has no diskId (not initialised)." -ForegroundColor Yellow
        }
        Write-Host ""
    }
}
