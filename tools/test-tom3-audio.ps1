#Requires -Version 5.1
<#
    test-tom3-audio.ps1 - end-to-end leak benchmark for Tom3_Fix-style add-ons.

    Same scenarios, sampling, fit and thresholds as the original project:
      repro : reproducer only (Fix=0) -> growth >= 60 MB/min (PASS)
      both  : fix + reproducer        -> growth <  15 MB/min and fix.hits > 0
      fix   : fix only (idle)         -> growth <  15 MB/min
      none  : Fix=0, no reproducer    -> reported as BASELINE only

    The fix artifact is always deployed (with the ini switch per scenario); the
    reproducer is deployed only for repro/both. Both are passed explicitly so
    this repository does not need to contain the implementation.

    Usage:
      powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario repro
      powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario both -MeasureSeconds 30
      powershell -ExecutionPolicy Bypass -File tools\test-tom3-audio.ps1 -Scenario both -AsiPath D:\out\Tom3_Fix.asi

    Exit code: 0 = PASS, 1 = not PASS, 2 = configuration/artifact error.
#>
param(
    [string]$GameDir = $env:TOM3_GAMEDIR,
    [ValidateSet('none', 'repro', 'fix', 'both')]
    [string]$Scenario = 'both',
    [int]$MeasureSeconds = 20,
    [int]$WarmupSeconds = 26,
    [int]$DriveHz = 10,
    [string]$AsiPath,
    [string]$ReproAsiPath,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent

if (-not $AsiPath)      { $AsiPath = 'build\Tom3_Fix.asi' }
if (-not $ReproAsiPath) { $ReproAsiPath = 'build\Tom3AudioLeakRepro.asi' }
if (-not [IO.Path]::IsPathRooted($AsiPath))      { $AsiPath = Join-Path $ProjectRoot $AsiPath }
if (-not [IO.Path]::IsPathRooted($ReproAsiPath)) { $ReproAsiPath = Join-Path $ProjectRoot $ReproAsiPath }
$AsiPath = [IO.Path]::GetFullPath($AsiPath)
$ReproAsiPath = [IO.Path]::GetFullPath($ReproAsiPath)

# --- locate the game folder: -GameDir > TOM3_GAMEDIR > tools\gamepath.txt ---
if (-not $GameDir) {
    $cfg = Join-Path $PSScriptRoot 'gamepath.txt'
    if (Test-Path $cfg) { $GameDir = (Get-Content $cfg -Raw).Trim() }
}
if (-not $GameDir -or -not (Test-Path (Join-Path $GameDir 'TreasuresOfMontezuma3.exe'))) {
    Write-Host ''
    Write-Host 'ERROR: game folder is not configured.'
    Write-Host '  powershell -File tools\set-gamepath.ps1 -GameDir "E:\...\The Treasures of Montezuma 3"'
    Write-Host '  or pass -GameDir <path>, or set the TOM3_GAMEDIR environment variable.'
    exit 2
}
$GameDir = $GameDir.TrimEnd('\')

if (-not (Test-Path -LiteralPath $AsiPath)) {
    Write-Host ('ERROR: fix artifact not found: ' + $AsiPath)
    Write-Host 'Build build\Tom3_Fix.asi first, or pass -AsiPath <path>.'
    exit 2
}
if (($Scenario -in 'repro', 'both') -and -not (Test-Path -LiteralPath $ReproAsiPath)) {
    Write-Host ('ERROR: reproducer artifact not found: ' + $ReproAsiPath)
    Write-Host 'Build build\Tom3AudioLeakRepro.asi first, or pass -ReproAsiPath <path>.'
    exit 2
}

$Exe     = Join-Path $GameDir 'TreasuresOfMontezuma3.exe'
$Ini     = Join-Path $GameDir 'Tom3AudioLeakRepro.ini'
$FixIni  = Join-Path $GameDir 'Tom3_Fix.ini'
$FixAsi  = Join-Path $GameDir 'Tom3_Fix.asi'
$RepAsi  = Join-Path $GameDir 'Tom3AudioLeakRepro.asi'
$FixLog  = Join-Path $GameDir 'Tom3_Fix.log'
$RepLog  = Join-Path $GameDir 'Tom3AudioLeakRepro.log'

function Log($msg) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $msg) }
function Get-Game { Get-Process TreasuresOfMontezuma3 -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Stop-Game { $p = Get-Game; if ($p) { Stop-Process -Id $p.Id -Force; Start-Sleep -Milliseconds 800 } }
function Get-Priv { $p = Get-Game; if (-not $p) { return -1 }; $p.Refresh(); return [double]$p.PrivateMemorySize64 }

function Set-Ini {
    param([int]$Hz, [bool]$Fix)
    @"
[Fix]
AudioMemoryLeakFix=$([int]$Fix)
"@ | Set-Content -Path $FixIni -Encoding ASCII
    @"
[Repro]
Enabled=1
Mode=drive
DriveHz=$Hz
DriveVolumePercent=0
PokeStart=0
WarmupMs=4000
Multiplier=30
"@ | Set-Content -Path $Ini -Encoding ASCII
}

function Deploy-Asi {
    param([bool]$UseRepro)
    foreach ($f in @($FixAsi, $RepAsi)) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    Copy-Item -LiteralPath $AsiPath $FixAsi -Force
    if ($UseRepro) { Copy-Item -LiteralPath $ReproAsiPath $RepAsi -Force }
    foreach ($l in @($FixLog, $RepLog)) { if (Test-Path $l) { Remove-Item $l -Force -ErrorAction SilentlyContinue } }
}

function Restore-Deployment {
    # Leave the install in its normal state: the provided fix only; both ini
    # files are deleted so the module recreates its commented template.
    foreach ($f in @($FixAsi, $RepAsi)) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    Copy-Item -LiteralPath $AsiPath $FixAsi -Force
    foreach ($f in @($FixIni, $Ini)) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    Write-Host 'deployment restored: Tom3_Fix.asi only (Tom3_Fix.ini regenerated on next start)'
}

function Read-Tail($path) {
    if (-not (Test-Path $path)) { return 'no log' }
    try { return (Get-Content $path -Tail 1) } catch { return 'locked' }
}

function Slope($samples) {
    if ($samples.Count -lt 3) { return 0.0 }
    $n = $samples.Count
    $sx = 0.0; $sy = 0.0; $sxy = 0.0; $sxx = 0.0
    foreach ($s in $samples) { $sx += $s.t; $sy += $s.mb; $sxy += $s.t * $s.mb; $sxx += $s.t * $s.t }
    $den = $n * $sxx - $sx * $sx
    if ($den -eq 0) { return 0.0 }
    return ($n * $sxy - $sx * $sy) / $den * 60.0
}

# --------------------------------------------------------------------- main ---
Log "scenario=$Scenario measure=${MeasureSeconds}s warmup=${WarmupSeconds}s driveHz=$DriveHz"
Log "fix=$AsiPath"
Log "repro=$ReproAsiPath"
Stop-Game
Deploy-Asi -UseRepro ($Scenario -in 'repro', 'both')
Set-Ini -Hz $DriveHz -Fix ($Scenario -in 'fix', 'both')

Log 'launching game'
Start-Process -FilePath $Exe -WorkingDirectory $GameDir | Out-Null
$t0 = Get-Date
while (-not (Get-Game) -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 300 }
$p = Get-Game
if (-not $p) { Log 'FAIL: game did not start'; Restore-Deployment; exit 1 }
$t0 = Get-Date
while ($p.MainWindowHandle -eq [IntPtr]::Zero -and ((Get-Date) - $t0).TotalSeconds -lt 60) {
    Start-Sleep -Milliseconds 500; $p.Refresh()
}
if ($p.MainWindowHandle -eq [IntPtr]::Zero) { Log 'FAIL: no window'; Stop-Game; Restore-Deployment; exit 1 }
Log ('window ok pid=' + $p.Id)

Log "warmup ${WarmupSeconds}s (drive thread starts, waits for a sound object)"
Start-Sleep -Seconds $WarmupSeconds
if (-not (Get-Game)) { Log 'FAIL: game died during warmup'; Restore-Deployment; exit 1 }

Log "measuring ${MeasureSeconds}s"
$samples = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$next = 0.0
while ($sw.Elapsed.TotalSeconds -lt $MeasureSeconds) {
    Start-Sleep -Milliseconds 250
    if ($sw.Elapsed.TotalSeconds -ge $next) {
        $v = Get-Priv
        if ($v -lt 0) { Log 'game exited during measurement'; break }
        $samples += [pscustomobject]@{ t = [math]::Round($sw.Elapsed.TotalSeconds, 2); mb = $v / 1MB }
        $next += 1.0
    }
}
$alive = [bool](Get-Game)
$fixStatus = Read-Tail $FixLog
$repStatus = Read-Tail $RepLog
$slope = Slope $samples

if ($samples.Count -gt 0) {
    Log ('samples=' + $samples.Count + '  first=' + [math]::Round($samples[0].mb,1) + 'MB  last=' + [math]::Round($samples[-1].mb,1) + 'MB')
} else {
    Log 'samples=0 (no memory samples collected)'
}
Log ('growth = ' + [math]::Round($slope,1) + ' MB/min')
Log ('fix   : ' + $fixStatus)
Log ('repro : ' + $repStatus)
Log ('alive=' + $alive)

$drives = 0
if ($repStatus -match 'drives=(\d+)') { $drives = [int]$Matches[1] }
$hits = 0
if ($fixStatus -match 'hits=(\d+)') { $hits = [int]$Matches[1] }
$freed = 0
if ($fixStatus -match 'freed=(\d+)') { $freed = [int]$Matches[1] }
$gen = 0
if ($fixStatus -match 'gen=(\d+)') { $gen = [int]$Matches[1] }

if ($hits -gt 0) {
    if ($freed -eq (3 * $hits)) { Log ('INFO: freed == 3*hits OK (' + $freed + ' == 3*' + $hits + ')') }
    else { Log ('INFO: freed != 3*hits (' + $freed + ' vs ' + (3 * $hits) + ') - inspect hook site/counters') }
    if ($gen -eq (768 + 3 * $hits)) { Log ('INFO: gen == 768+3*hits OK (' + $gen + ')') }
    else { Log ('INFO: gen != 768+3*hits (' + $gen + ' vs ' + (768 + 3 * $hits) + ') - hook missed or duplicated a call') }
}

if (-not $KeepRunning) { Stop-Game }
Restore-Deployment

$verdict = 'INCONCLUSIVE'
switch ($Scenario) {
    'repro' {
        if (-not $alive) { $verdict = 'PASS (leak drove the process to OOM/crash: ' + [math]::Round($slope,1) + ' MB/min)' }
        elseif ($slope -ge 60) { $verdict = 'PASS (leak reproduced: ' + [math]::Round($slope,1) + ' MB/min, drives=' + $drives + ')' }
        elseif ($slope -ge 20) { $verdict = 'WEAK (growth ' + [math]::Round($slope,1) + ' MB/min, drives=' + $drives + ')' }
        else { $verdict = 'FAIL (no growth: ' + [math]::Round($slope,1) + ' MB/min, drives=' + $drives + ')' }
    }
    'both' {
        if (-not $alive) { $verdict = 'FAIL (crashed with fix loaded)' }
        elseif ($slope -lt 15 -and $hits -gt 0) { $verdict = 'PASS (fix holds: ' + [math]::Round($slope,1) + ' MB/min, hits=' + $hits + ', freed=' + $freed + ', drive=' + $drives + ')' }
        elseif ($slope -lt 15) { $verdict = 'INCONCLUSIVE (flat but fix hook not exercised: hits=' + $hits + ')' }
        else { $verdict = 'FAIL (still leaking: ' + [math]::Round($slope,1) + ' MB/min)' }
    }
    'fix' {
        if ($alive -and $slope -lt 15) { $verdict = 'PASS (idle baseline flat: ' + [math]::Round($slope,1) + ' MB/min)' }
        elseif (-not $alive) { $verdict = 'FAIL (crashed)' }
        else { $verdict = 'FAIL (leaking without reproducer: ' + [math]::Round($slope,1) + ' MB/min)' }
    }
    'none' { $verdict = 'BASELINE (' + [math]::Round($slope,1) + ' MB/min)' }
}
Log ('VERDICT: ' + $verdict)

if ($samples.Count -gt 0) {
    $csvDir = Join-Path $env:TEMP 'tom3'
    New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
    $samples | ForEach-Object { '{0,6:N1}s {1,8:N1}MB' -f $_.t, $_.mb } |
        Set-Content (Join-Path $csvDir "test-$Scenario.csv")
}
if ($verdict -like 'PASS*') { exit 0 } else { exit 1 }
