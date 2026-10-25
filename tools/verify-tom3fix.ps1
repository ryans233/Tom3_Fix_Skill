#Requires -Version 5.1
<#
    verify-tom3fix.ps1 - deployment / runtime verification for a Tom3_Fix-style
    add-on.

    Static checks
      * game executable present + LARGEADDRESSAWARE state (optional mitigation)
      * ASI loader (dinput8.dll) present
      * Tom3_Fix.asi deployed and identical to the passed artifact
      * Tom3_Fix.ini present / key value (missing file or key = defaults)
      * HIGHDPIAWARE compatibility layer (known startup-hang suspect) not set
      * reproducer not left in the install directory

    Runtime checks
      * game starts and reaches a window
      * Tom3_Fix.log shows "attached" and (if enabled) "alGenBuffers hooked"
      * no "fix: ERROR" line

    Optional
      * -Benchmark : runs test-tom3-audio.ps1 (fix + reproducer, 10 s) and
        requires its PASS verdict.

    Usage:
      powershell -ExecutionPolicy Bypass -File tools\verify-tom3fix.ps1
      powershell -ExecutionPolicy Bypass -File tools\verify-tom3fix.ps1 -AsiPath D:\out\Tom3_Fix.asi -Benchmark

    Exit code: 0 = all checks PASS, 1 = at least one FAIL, 2 = game folder not configured.
#>
param(
    [string]$GameDir = $env:TOM3_GAMEDIR,
    [string]$AsiPath,
    [string]$ReproAsiPath,
    [switch]$Benchmark,
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

$Exe     = Join-Path $GameDir 'TreasuresOfMontezuma3.exe'
$Loader  = Join-Path $GameDir 'dinput8.dll'
$FixAsi  = Join-Path $GameDir 'Tom3_Fix.asi'
$FixIni  = Join-Path $GameDir 'Tom3_Fix.ini'
$FixLog  = Join-Path $GameDir 'Tom3_Fix.log'
$RepAsi  = Join-Path $GameDir 'Tom3AudioLeakRepro.asi'

$script:Fail = 0
$script:Warn = 0

function Line([string]$level, [string]$text) {
    switch ($level) {
        'PASS' { Write-Host ('  [PASS] ' + $text) }
        'FAIL' { Write-Host ('  [FAIL] ' + $text); $script:Fail++ }
        'WARN' { Write-Host ('  [WARN] ' + $text); $script:Warn++ }
        default { Write-Host ('  [INFO] ' + $text) }
    }
}

function Section([string]$name) { Write-Host ''; Write-Host ('== ' + $name + ' ==') }

function Get-DllCharacteristics([string]$path) {
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $lfanew = $br.ReadInt32()
        $fs.Position = $lfanew + 94      # PE sig(4) + file header(20) + DllCharacteristics offset(70)
        return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}

function Get-Sha256([string]$path) {
    # Get-FileHash is unavailable in some minimal PowerShell hosts; use .NET.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '')
    } finally {
        $fs.Dispose()
        $sha.Dispose()
    }
}

function Get-IniValue([string]$path, [string]$section, [string]$key) {
    if (-not (Test-Path $path)) { return $null }
    $inSection = $false
    foreach ($raw in Get-Content $path) {
        $line = $raw.Trim()
        if ($line -match '^\[(.+)\]$') { $inSection = ($Matches[1] -ieq $section); continue }
        if (-not $inSection) { continue }
        if ($line -match ('^' + [regex]::Escape($key) + '\s*=\s*(.+?)\s*$')) { return $Matches[1] }
    }
    return $null
}

function Stop-Game {
    Get-Process TreasuresOfMontezuma3 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

# ------------------------------------------------------------------ static ---
Section 'files'
Line ($(if (Test-Path $Exe) { 'PASS' } else { 'FAIL' })) ("game executable: $Exe")
Line ($(if (Test-Path $Loader) { 'PASS' } else { 'FAIL' })) ("ASI loader dinput8.dll: " + $(if (Test-Path $Loader) { "{0:N0} B" -f (Get-Item $Loader).Length } else { 'missing' }))
Line ($(if (Test-Path $FixAsi) { 'PASS' } else { 'FAIL' })) ("Tom3_Fix.asi: " + $(if (Test-Path $FixAsi) { "{0:N0} B" -f (Get-Item $FixAsi).Length } else { 'missing' }))
Line ($(if (Test-Path $AsiPath) { 'PASS' } else { 'FAIL' })) ("build artifact: " + $AsiPath)

if ((Test-Path $FixAsi) -and (Test-Path $AsiPath)) {
    $h1 = Get-Sha256 $FixAsi
    $h2 = Get-Sha256 $AsiPath
    if ($h1 -eq $h2) { Line 'PASS' 'deployed Tom3_Fix.asi matches the passed artifact' }
    else { Line 'WARN' 'deployed Tom3_Fix.asi differs from the passed artifact (stale) - run run-acceptance.ps1 or copy it first' }
}

if (Test-Path $RepAsi) { Line 'WARN' 'Tom3AudioLeakRepro.asi is present in the install (test-only artefact)' }
else { Line 'PASS' 'no reproducer left in the install' }

Section 'executable'
if (Test-Path $Exe) {
    $ch = Get-DllCharacteristics $Exe
    $laa = ($ch -band 0x20) -ne 0
    if ($laa) { Line 'PASS' ("LARGEADDRESSAWARE set (DllCharacteristics=0x{0:X4})" -f $ch) }
    else { Line 'WARN' ("LARGEADDRESSAWARE not set (DllCharacteristics=0x{0:X4}); optional mitigation only" -f $ch) }
}

Section 'configuration'
$iniValue = Get-IniValue $FixIni 'Fix' 'AudioMemoryLeakFix'
if ($null -eq $iniValue) {
    Line 'INFO' 'Tom3_Fix.ini missing or key absent -> defaults apply (AudioMemoryLeakFix=1)'
    $fixEnabled = $true
} else {
    $fixEnabled = ($iniValue -ne '0')
    Line ($(if ($fixEnabled) { 'PASS' } else { 'WARN' })) ("AudioMemoryLeakFix=$iniValue" + $(if ($fixEnabled) { '' } else { ' (fix disabled by config)' }))
}

$layer = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers' `
                           -Name $Exe -ErrorAction SilentlyContinue).$Exe
if ($layer -and ($layer -match 'HIGHDPIAWARE')) {
    Line 'WARN' ("HIGHDPIAWARE compatibility layer is set ('$layer') - unnecessary; remove it if the game fails to start")
} else {
    Line 'PASS' 'no HIGHDPIAWARE compatibility layer'
}

# ----------------------------------------------------------------- runtime ---
Section 'runtime'
Stop-Game
if (Test-Path $FixLog) { Remove-Item $FixLog -Force -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath $Exe -WorkingDirectory $GameDir -PassThru
$t0 = Get-Date
while (-not $p.HasExited -and $p.MainWindowHandle -eq [IntPtr]::Zero -and ((Get-Date) - $t0).TotalSeconds -lt 40) {
    Start-Sleep -Milliseconds 400
    $p.Refresh()
}
if ($p.HasExited) {
    Line 'FAIL' ('game exited during startup (code ' + $p.ExitCode + ')')
} elseif ($p.MainWindowHandle -eq [IntPtr]::Zero) {
    Line 'FAIL' 'no game window after 40 s'
} else {
    Line 'PASS' 'game started and created a window'
    Start-Sleep -Seconds 5
    if (-not (Test-Path $FixLog)) {
        Line 'FAIL' 'Tom3_Fix.log not created -> .asi was not loaded (ASI loader missing or wrong name)'
    } else {
        $log = Get-Content $FixLog -Raw
        if ($log -match 'Tom3_Fix\.asi attached') { Line 'PASS' 'Tom3_Fix.asi loaded' }
        else { Line 'FAIL' 'Tom3_Fix.log has no attach line' }

        if ($fixEnabled) {
            if ($log -match 'fix: alGenBuffers hooked') { Line 'PASS' 'alGenBuffers hook installed' }
            elseif ($log -match 'fix: ERROR') {
                $err = ($log -split "`n" | Where-Object { $_ -match 'fix: ERROR' } | Select-Object -First 1)
                Line 'FAIL' ("hook not installed: " + $err.Trim())
            } else { Line 'FAIL' 'no hook line in log' }
        } else {
            if ($log -match 'fix: alGenBuffers hooked') { Line 'FAIL' 'fix is disabled in ini but a hook was installed' }
            else { Line 'PASS' 'fix disabled as configured (no hook)' }
        }
    }
}

if (-not $KeepRunning) { Stop-Game }

# --------------------------------------------------------------- benchmark ---
if ($Benchmark) {
    Section 'benchmark (fix + reproducer, 10 s)'
    $test = Join-Path $PSScriptRoot 'test-tom3-audio.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $test -GameDir $GameDir `
        -AsiPath $AsiPath -ReproAsiPath $ReproAsiPath `
        -Scenario both -DriveHz 10 -MeasureSeconds 10 -WarmupSeconds 26
    if ($LASTEXITCODE -eq 0) { Line 'PASS' 'leak benchmark passed (see test-tom3-audio.ps1 output above)' }
    else { Line 'FAIL' 'leak benchmark failed (see test-tom3-audio.ps1 output above)' }
}

# ------------------------------------------------------------------ summary --
Write-Host ''
Write-Host ("SUMMARY: failures=$script:Fail warnings=$script:Warn")
if ($script:Fail -eq 0) { Write-Host 'RESULT: PASS'; exit 0 } else { Write-Host 'RESULT: FAIL'; exit 1 }
