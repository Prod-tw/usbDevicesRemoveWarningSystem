# deploy.ps1 - Build one deployment package per site from a mapping table.
#
#   .\deploy.ps1                              build from ..\deploy-table.json
#   .\deploy.ps1 -Table ..\sites.csv          use a CSV table instead
#   .\deploy.ps1 -ConfigOnly                  emit config.json only, no file copies
#
# Table columns:
#   deployAt  site name   -> becomes the folder name and computerName  (required)
#   diskIds   disk ID(s)  -> becomes watchIds                          (preferred)
#   serials   USB serial(s) -> also becomes watchIds; use either or both
#   ssdName   model name  -> documentation only, ends up in the manifest
#
# At least one of diskIds / serials must be present on every row.
#
# Any additional column that matches a key in the base config.json overrides
# that key for the site (e.g. a serverUrl column to split sites across servers).

param(
    [string] $Table,
    [string] $BaseConfig,
    [string] $OutputRoot,
    [switch] $ConfigOnly,
    [switch] $Force
)

$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not $Table)      { $Table      = Join-Path $repoRoot 'deploy-table.json' }
if (-not $BaseConfig) { $BaseConfig = Join-Path $repoRoot 'config.json' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $repoRoot 'deploy' }

$errorCount = 0
function Write-Err { param([string] $Msg); $script:errorCount++; Write-Host "[Error] $Msg" -ForegroundColor Red }

# ------------------------------------------------------------- base config --

if (-not (Test-Path $BaseConfig)) {
    Write-Host "[Error] Base config not found: $BaseConfig" -ForegroundColor Red
    exit 1
}

try {
    $base = Get-Content $BaseConfig -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "[Error] Base config is not valid JSON: $_" -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------- read table --

if (-not (Test-Path $Table)) {
    Write-Host "[Error] Mapping table not found: $Table" -ForegroundColor Red
    Write-Host "        See deploy-table.example.json for the expected shape."
    exit 1
}

$isCsv = ([System.IO.Path]::GetExtension($Table)).ToLower() -eq '.csv'

try {
    if ($isCsv) {
        $rows = @(Import-Csv -Path $Table -Encoding UTF8)
    } else {
        # ConvertFrom-Json emits a JSON array as one object in PS 5.1, so wrapping
        # the pipeline in @() would nest it - assign first, then wrap.
        $parsed = Get-Content $Table -Raw -Encoding UTF8 | ConvertFrom-Json
        $rows = @($parsed)
    }
} catch {
    Write-Host "[Error] Could not read the mapping table: $_" -ForegroundColor Red
    exit 1
}

if ($rows.Count -eq 0) {
    Write-Host "[Error] The mapping table is empty." -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------- normalise --

function Get-Field {
    param($Row, [string] $Name)

    $prop = $Row.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function ConvertTo-SerialList {
    param($Value)

    if ($null -eq $Value) { return @() }

    # JSON gives an array; CSV gives one cell holding separated values.
    if ($Value -is [string]) {
        $parts = $Value -split '[;,\s]+'
    } else {
        $parts = @($Value)
    }

    return @($parts | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
}

function Get-SafeName {
    param([string] $Name)

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    $safe = $sb.ToString().Trim(' ', '.')
    if ($safe -eq '') { $safe = 'site' }
    return $safe
}

# Group rows by site so one site can span several rows (one per drive).
$sites = [ordered]@{}
$rowNumber = 0

foreach ($row in $rows) {
    $rowNumber++

    $deployAt = "$(Get-Field $row 'deployAt')".Trim()
    $ssdName  = "$(Get-Field $row 'ssdName')".Trim()

    $diskIds   = @(ConvertTo-SerialList (Get-Field $row 'diskIds'))
    $serialIds = @(ConvertTo-SerialList (Get-Field $row 'serials'))

    # A diskId identifies one physical drive; a serial often does not, because
    # cheap enclosures hand out one placeholder for a whole batch. monitor.ps1
    # matches on either, so keeping a shared serial alongside a good diskId
    # would let the wrong drive satisfy the whitelist. Prefer the diskId alone.
    $ids = if ($diskIds.Count -gt 0) { $diskIds } else { $serialIds }
    $serials = @($ids | ForEach-Object { $_.Trim('{', '}') } | Where-Object { $_ -ne '' })

    if ($deployAt -eq '') { Write-Err "row $rowNumber has no deployAt, skipped."; continue }
    if ($serials.Count -eq 0) { Write-Err "row $rowNumber ($deployAt) has no diskIds or serials, skipped."; continue }

    if (-not $sites.Contains($deployAt)) {
        $sites[$deployAt] = [PSCustomObject]@{
            DeployAt  = $deployAt
            Models    = New-Object System.Collections.ArrayList
            Serials   = New-Object System.Collections.ArrayList
            Overrides = @{}
        }
    }

    $site = $sites[$deployAt]
    if ($ssdName -ne '') { [void]$site.Models.Add($ssdName) }

    foreach ($s in $serials) {
        if ($site.Serials -notcontains $s) { [void]$site.Serials.Add($s) }
    }

    # Extra columns matching a base-config key override it for this site.
    foreach ($prop in $row.PSObject.Properties) {
        if ($prop.Name -in @('deployAt', 'ssdName', 'serials', 'diskIds')) { continue }
        if ($null -eq $base.PSObject.Properties[$prop.Name]) { continue }

        $raw = "$($prop.Value)".Trim()
        if ($raw -eq '') { continue }

        # CSV hands everything over as a string; coerce to the base value's type.
        $baseValue = $base.PSObject.Properties[$prop.Name].Value
        try {
            if     ($baseValue -is [bool]) { $site.Overrides[$prop.Name] = [System.Convert]::ToBoolean($raw) }
            elseif ($baseValue -is [int])  { $site.Overrides[$prop.Name] = [int]$raw }
            else                           { $site.Overrides[$prop.Name] = $raw }
        } catch {
            Write-Err "row $rowNumber ($deployAt): could not read '$($prop.Name)' value '$raw'."
        }
    }
}

if ($sites.Count -eq 0) {
    Write-Host "[Error] No usable rows in the mapping table." -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------- cross-site conflicts --

# The same serial assigned to two sites is either a copy/paste mistake or the
# cheap-enclosure problem where a whole batch reports one serial. Both make the
# whitelist meaningless, so refuse to build rather than ship a broken config.
$serialOwners = @{}
foreach ($site in $sites.Values) {
    foreach ($s in $site.Serials) {
        $k = $s.ToUpperInvariant()
        if (-not $serialOwners.ContainsKey($k)) { $serialOwners[$k] = New-Object System.Collections.ArrayList }
        if ($serialOwners[$k] -notcontains $site.DeployAt) { [void]$serialOwners[$k].Add($site.DeployAt) }
    }
}

foreach ($k in $serialOwners.Keys) {
    if ($serialOwners[$k].Count -gt 1) {
        Write-Err "serial '$k' is assigned to more than one site: $($serialOwners[$k] -join ', ')"
    }
}

if ($errorCount -gt 0 -and -not $Force) {
    Write-Host ""
    Write-Host "Aborted with $errorCount problem(s). Fix the table, or pass -Force to build anyway." -ForegroundColor Red
    exit 1
}

# Problems found in the table itself, as opposed to failures while copying.
$tableErrors = $errorCount

# ------------------------------------------------------------------- build --

if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$payload = @('monitor.ps1', 'run.bat', 'Modules', 'sounds')
$manifest = New-Object System.Collections.ArrayList

# Windows caps paths at 260 characters and BurntToast nests its assemblies
# deeply, so a long output path silently truncates the copy. Measure the worst
# case up front and refuse sites that cannot fit.
$maxPayloadPath = 0
if (-not $ConfigOnly) {
    foreach ($item in $payload) {
        $src = Join-Path $repoRoot $item
        if (-not (Test-Path $src)) { continue }
        foreach ($f in @(Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Length - $repoRoot.Length
            if ($rel -gt $maxPayloadPath) { $maxPayloadPath = $rel }
        }
    }
}

function Test-CopyComplete {
    param([string] $Source, [string] $Destination)

    $srcCount = @(Get-ChildItem $Source -Recurse -File -ErrorAction SilentlyContinue).Count
    $dstCount = @(Get-ChildItem $Destination -Recurse -File -ErrorAction SilentlyContinue).Count
    return [PSCustomObject]@{ Source = $srcCount; Copied = $dstCount; Ok = ($srcCount -eq $dstCount) }
}

Write-Host "============================================"
Write-Host " Building $($sites.Count) site package(s)"
Write-Host " Table  : $Table"
Write-Host " Base   : $BaseConfig"
Write-Host " Output : $OutputRoot"
Write-Host "============================================"

foreach ($site in $sites.Values) {
    $folderName = Get-SafeName $site.DeployAt
    $siteDir    = Join-Path $OutputRoot $folderName

    if (-not (Test-Path $siteDir)) {
        New-Item -ItemType Directory -Path $siteDir -Force | Out-Null
    }

    # Start from the base config so every site inherits serverUrl, apiKey,
    # sound settings and so on; only the per-site bits are replaced.
    $cfg = [ordered]@{}
    foreach ($prop in $base.PSObject.Properties) { $cfg[$prop.Name] = $prop.Value }

    $cfg['computerName'] = $site.DeployAt
    $cfg['watchIds']     = @($site.Serials)
    $cfg.Remove('watchSerials')

    foreach ($k in $site.Overrides.Keys) { $cfg[$k] = $site.Overrides[$k] }

    $configPath = Join-Path $siteDir 'config.json'
    ($cfg | ConvertTo-Json -Depth 5) + "`n" | Set-Content -Path $configPath -Encoding UTF8 -NoNewline

    $copied = @()
    if (-not $ConfigOnly) {
        if (($siteDir.Length + $maxPayloadPath) -gt 259) {
            $budget = 259 - $maxPayloadPath
            Write-Err "$($site.DeployAt): output path is too long for Windows ($($siteDir.Length) chars, limit $budget). Use a shorter -OutputRoot."
        } else {
            foreach ($item in $payload) {
                $src = Join-Path $repoRoot $item
                if (-not (Test-Path $src)) { continue }

                try {
                    Copy-Item -Path $src -Destination $siteDir -Recurse -Force -ErrorAction Stop
                } catch {
                    Write-Err "$($site.DeployAt): copying '$item' failed - $_"
                    continue
                }

                # Copy-Item -Recurse reports per-file errors but still returns, so
                # confirm the whole tree landed before calling this package good.
                if (Test-Path $src -PathType Container) {
                    $check = Test-CopyComplete -Source $src -Destination (Join-Path $siteDir $item)
                    if (-not $check.Ok) {
                        Write-Err "$($site.DeployAt): '$item' is incomplete - copied $($check.Copied) of $($check.Source) files."
                        continue
                    }
                }

                $copied += $item
            }
        }
    }

    $models = @($site.Models | Select-Object -Unique)
    Write-Host ""
    Write-Host "  $($site.DeployAt)  ->  $siteDir"
    Write-Host "    serials : $($site.Serials -join ', ')"
    if ($models.Count -gt 0) { Write-Host "    models  : $($models -join ', ')" }
    if ($site.Overrides.Count -gt 0) { Write-Host "    override: $($site.Overrides.Keys -join ', ')" }

    [void]$manifest.Add([PSCustomObject]@{
        deployAt    = $site.DeployAt
        folder      = $folderName
        ssdName     = ($models -join '; ')
        serialCount = $site.Serials.Count
        serials     = ($site.Serials -join '; ')
        payload     = ($copied -join '; ')
    })
}

$manifestPath = Join-Path $OutputRoot 'manifest.csv'
$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

$buildErrors = $errorCount - $tableErrors

Write-Host ""
Write-Host "============================================"

if ($buildErrors -gt 0) {
    Write-Host " FAILED: $buildErrors problem(s) while building." -ForegroundColor Red
    Write-Host " Some packages are incomplete - do not ship them." -ForegroundColor Red
} else {
    Write-Host " Done. $($sites.Count) package(s) written."
}

Write-Host " Manifest: $manifestPath"
if ($ConfigOnly)      { Write-Host " (config.json only - monitor.ps1 and Modules were not copied)" }
if ($tableErrors -gt 0) { Write-Host " Table had $tableErrors problem(s), built anyway because -Force was set." -ForegroundColor Yellow }
Write-Host "============================================"

if ($buildErrors -gt 0) { exit 1 }
