# write-drives.ps1 - Copy each site's package onto its own drive.
#
# Looks up the attached drive's diskId in the mapping table, finds the matching
# site package under -DeployRoot, and copies it onto that drive. Nothing is
# written to a drive whose diskId is not in the table, so the wrong config
# cannot land on the wrong disk.
#
#   .\write-drives.ps1 -Table ..\deploy-table.csv -DryRun    show what would happen
#   .\write-drives.ps1 -Table ..\deploy-table.csv            write what is attached
#   .\write-drives.ps1 -Table ..\deploy-table.csv -Watch     write each drive as plugged in
#
# Run tools\deploy.ps1 first so the packages exist.

param(
    [string] $Table,
    [string] $DeployRoot,
    [string] $Subfolder = 'USB-Monitor',
    [switch] $Watch,
    [switch] $DryRun,
    [int]    $PollSeconds = 2
)

$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $Table)      { $Table      = Join-Path $repoRoot 'deploy-table.csv' }
if (-not $DeployRoot) { $DeployRoot = Join-Path $repoRoot 'deploy' }

if ($PollSeconds -lt 1) { $PollSeconds = 1 }

if (-not (Test-Path $Table)) {
    Write-Host "[Error] Mapping table not found: $Table" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $DeployRoot)) {
    Write-Host "[Error] Deploy folder not found: $DeployRoot" -ForegroundColor Red
    Write-Host "        Run tools\deploy.ps1 first."
    exit 1
}

# ---------------------------------------------------------------- the table --

$isCsv = ([System.IO.Path]::GetExtension($Table)).ToLower() -eq '.csv'

try {
    if ($isCsv) {
        $rows = @(Import-Csv -Path $Table -Encoding UTF8)
    } else {
        $parsed = Get-Content $Table -Raw -Encoding UTF8 | ConvertFrom-Json
        $rows = @($parsed)
    }
} catch {
    Write-Host "[Error] Could not read the mapping table: $_" -ForegroundColor Red
    exit 1
}

function Get-Field {
    param($Row, [string] $Name)
    $prop = $Row.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# diskId -> site name
$owner = @{}
foreach ($row in $rows) {
    $site = "$(Get-Field $row 'deployAt')".Trim()
    if ($site -eq '') { continue }

    $ids = "$(Get-Field $row 'diskIds')" -split '[;,\s]+'
    foreach ($id in $ids) {
        $k = "$id".Trim().Trim('{', '}').ToUpperInvariant()
        if ($k -ne '') { $owner[$k] = $site }
    }
}

if ($owner.Count -eq 0) {
    Write-Host "[Error] No diskIds found in the table." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------- helpers --

function Get-USBDisks {
    Get-Disk -ErrorAction Stop |
        Where-Object { $_.BusType -eq 'USB' } |
        Select-Object Number, FriendlyName, SerialNumber, Guid, Signature
}

function Get-DiskId {
    param($Disk)
    if ($Disk.Guid) { return "$($Disk.Guid)".Trim().Trim('{', '}').ToUpperInvariant() }
    if ($Disk.Signature) { return 'SIG-{0:X8}' -f [uint32]$Disk.Signature }
    return $null
}

function Get-DriveLetter {
    param([int] $DiskNumber)

    try {
        $letters = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
                     Where-Object { $_.DriveLetter } |
                     ForEach-Object { $_.DriveLetter })
    } catch {
        return $null
    }

    if ($letters.Count -eq 0) { return $null }
    if ($letters.Count -gt 1) {
        Write-Host "    [Note] Disk $DiskNumber has several volumes ($($letters -join ', ')); using $($letters[0])."
    }
    return $letters[0]
}

$script:Done = @{}
$okCount    = 0
$skipCount  = 0   # not part of this deployment - expected, not an error
$failCount  = 0   # should have been written but could not be
$matchCount = 0   # matched a site, whether or not anything was written

function Write-Drive {
    param($Disk)

    $diskId = Get-DiskId $Disk
    Write-Host ""
    Write-Host "  $($Disk.FriendlyName)  ->  diskId: $(if ($diskId) { $diskId } else { '(none)' })"

    # These two are not failures - an unrelated USB stick being plugged in is
    # normal, and refusing to write to it is the point.
    if (-not $diskId) {
        Write-Host "    [Skip] Disk is not initialised, no diskId to match." -ForegroundColor Yellow
        $script:skipCount++
        return
    }

    if (-not $owner.ContainsKey($diskId)) {
        Write-Host "    [Skip] This diskId is not in the table - nothing written." -ForegroundColor Yellow
        $script:skipCount++
        return
    }

    $site   = $owner[$diskId]
    $source = Join-Path $DeployRoot $site

    if (-not (Test-Path $source)) {
        Write-Host "    [Failed] No package for site '$site' at $source" -ForegroundColor Red
        Write-Host "             Run tools\deploy.ps1 first." -ForegroundColor Red
        $script:failCount++
        return
    }

    $letter = Get-DriveLetter -DiskNumber $Disk.Number
    if (-not $letter) {
        Write-Host "    [Failed] No drive letter - the disk may be unformatted or offline." -ForegroundColor Red
        $script:failCount++
        return
    }

    $target = "${letter}:\$Subfolder"
    Write-Host "    site  : $site"
    Write-Host "    target: $target"
    $script:matchCount++

    if ($DryRun) {
        Write-Host "    [DryRun] Matched OK. Re-run without -DryRun to write." -ForegroundColor Cyan
        return
    }

    try {
        if (-not (Test-Path $target)) {
            New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "    [Failed] $_" -ForegroundColor Red
        $script:failCount++
        return
    }

    # Copy-Item -Recurse reports per-file errors but still returns, so compare
    # counts before calling the drive good.
    $srcCount = @(Get-ChildItem $source -Recurse -File -ErrorAction SilentlyContinue).Count
    $dstCount = @(Get-ChildItem $target -Recurse -File -ErrorAction SilentlyContinue).Count

    if ($srcCount -ne $dstCount) {
        Write-Host "    [Failed] Copied $dstCount of $srcCount files." -ForegroundColor Red
        $script:failCount++
        return
    }

    Write-Host "    [OK] $dstCount files copied." -ForegroundColor Green
    $script:okCount++
}

# ------------------------------------------------------------------- start --

try {
    $disks = @(Get-USBDisks)
} catch {
    Write-Host "[Error] Could not query disks. Run as Administrator. ($_)" -ForegroundColor Red
    exit 1
}

Write-Host "============================================"
Write-Host " Writing site packages to their own drives"
Write-Host " Table  : $Table  ($($owner.Count) diskIds)"
Write-Host " Source : $DeployRoot"
Write-Host " Target : <drive>\$Subfolder"
if ($DryRun) { Write-Host " Mode   : DRY RUN - nothing will be written" -ForegroundColor Cyan }
Write-Host "============================================"
Write-Host "USB disks attached right now: $($disks.Count)"

foreach ($d in $disks) {
    $script:Done["$(Get-DiskId $d)|$($d.Number)"] = $true
    Write-Drive $d
}

function Write-Summary {
    Write-Host ""
    Write-Host "============================================"

    if ($DryRun) {
        Write-Host " DRY RUN - nothing was written." -ForegroundColor Cyan
        Write-Host " Matched : $matchCount  (would be written)"
    } else {
        Write-Host " Written : $okCount of $($owner.Count) sites"
    }

    Write-Host " Skipped : $skipCount  (not in the table)"

    if ($failCount -gt 0) {
        Write-Host " FAILED  : $failCount  - these drives are not ready to ship" -ForegroundColor Red
    } else {
        Write-Host " Failed  : 0"
    }

    if (-not $DryRun -and $okCount -lt $owner.Count) {
        Write-Host " Still to do: $($owner.Count - $okCount) site(s) in the table have not been written yet."
    }

    Write-Host "============================================"
}

if (-not $Watch) {
    Write-Summary
    if ($failCount -gt 0) { exit 1 }
    exit 0
}

# ------------------------------------------------------------------- watch --

Write-Host ""
Write-Host "Watching - plug the drives in one at a time. Ctrl+C to stop."

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    try {
        $current = @(Get-USBDisks)
    } catch {
        Write-Host "[Warning] Get-Disk failed, retrying: $_" -ForegroundColor Yellow
        continue
    }

    foreach ($d in $current) {
        $key = "$(Get-DiskId $d)|$($d.Number)"
        if ($script:Done.ContainsKey($key)) { continue }
        $script:Done[$key] = $true

        # A freshly attached disk may not have its volumes mounted yet.
        Start-Sleep -Seconds 1
        Write-Drive $d
        Write-Host "    (progress: $okCount of $($owner.Count) sites written, $failCount failed)"
    }
}
