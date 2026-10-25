#Requires -Version 5.1
<#
    run-acceptance.ps1 - one-shot acceptance for a Tom3_Fix-style submission.

    Steps (criteria are defined by the individual scripts; this wrapper adds none):
      1. check-submission.ps1   compliance + i386 DLL format
      2. verify-tom3fix.ps1     deployment + runtime + log checks
      3. test-tom3-audio.ps1 -Scenario repro   growth >= 60 MB/min
      4. test-tom3-audio.ps1 -Scenario both    growth < 15 MB/min and hits > 0
      5. test-tom3-audio.ps1 -Scenario fix     idle growth < 15 MB/min

    The wrapper deploys the passed fix artifact into the game folder before
    verification and restores "fix only, no test ini" afterwards.

    Usage:
      powershell -ExecutionPolicy Bypass -File tools\run-acceptance.ps1
      powershell -ExecutionPolicy Bypass -File tools\run-acceptance.ps1 -AsiPath D:\out\Tom3_Fix.asi

    Exit code: 0 = every step passed, 1 = at least one step failed, 2 = setup error.
#>
param(
    [string]$GameDir = $env:TOM3_GAMEDIR,
    [string]$AsiPath,
    [string]$ReproAsiPath,
    [int]$DriveHz = 30,
    [int]$ReproSeconds = 10,
    [int]$BothSeconds = 30,
    [int]$FixSeconds = 15,
    [switch]$SkipCompliance
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path $PSScriptRoot -Parent

if (-not $AsiPath)      { $AsiPath = 'build\Tom3_Fix.asi' }
if (-not $ReproAsiPath) { $ReproAsiPath = 'build\Tom3AudioLeakRepro.asi' }
if (-not [IO.Path]::IsPathRooted($AsiPath))      { $AsiPath = Join-Path $ProjectRoot $AsiPath }
if (-not [IO.Path]::IsPathRooted($ReproAsiPath)) { $ReproAsiPath = Join-Path $ProjectRoot $ReproAsiPath }
$AsiPath = [IO.Path]::GetFullPath($AsiPath)
$ReproAsiPath = [IO.Path]::GetFullPath($ReproAsiPath)

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

foreach ($path in @($AsiPath, $ReproAsiPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ('ERROR: artifact not found: ' + $path)
        Write-Host 'Build build\Tom3_Fix.asi and build\Tom3AudioLeakRepro.asi first (see SKILLS.MD).'
        exit 2
    }
}

$FixAsi = Join-Path $GameDir 'Tom3_Fix.asi'
$RepAsi = Join-Path $GameDir 'Tom3AudioLeakRepro.asi'
$FixIni = Join-Path $GameDir 'Tom3_Fix.ini'
$RepIni = Join-Path $GameDir 'Tom3AudioLeakRepro.ini'
$FixLog = Join-Path $GameDir 'Tom3_Fix.log'
$RepLog = Join-Path $GameDir 'Tom3AudioLeakRepro.log'

function Stop-Game {
    Get-Process TreasuresOfMontezuma3 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

function Deploy-Normal {
    Stop-Game
    foreach ($f in @($FixAsi, $RepAsi, $FixIni, $RepIni, $FixLog, $RepLog)) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    Copy-Item -LiteralPath $AsiPath $FixAsi -Force
}

function Restore-Normal {
    Stop-Game
    foreach ($f in @($RepAsi, $FixIni, $RepIni, $RepLog)) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
    Copy-Item -LiteralPath $AsiPath $FixAsi -Force
    Write-Host ''
    Write-Host ('deployment restored: ' + $FixAsi + ' only (test ini files removed)')
}

$script:results = @()
$script:Failed = 0

function Add-Result([string]$name, [int]$code) {
    $script:results += [pscustomobject]@{ Step = $name; Exit = $code }
    if ($code -ne 0) { $script:Failed++ }
    $state = if ($code -eq 0) { 'PASS' } else { 'FAIL' }
    Write-Host ''
    Write-Host ('---- ' + $name + ': ' + $state + ' (exit ' + $code + ') ----')
}

Write-Host '== Tom3_Fix acceptance =='
Write-Host ('game   : ' + $GameDir)
Write-Host ('fix    : ' + $AsiPath)
Write-Host ('repro  : ' + $ReproAsiPath)

$overall = 1
try {
    if (-not $SkipCompliance) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'check-submission.ps1') `
            -Root $ProjectRoot -AsiPath $AsiPath -ReproAsiPath $ReproAsiPath
        Add-Result 'compliance + artifact format' $LASTEXITCODE
    }

    Deploy-Normal
    Write-Host ''
    Write-Host '== deployed fix only; running deployment/runtime verification =='

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-tom3fix.ps1') `
        -GameDir $GameDir -AsiPath $AsiPath -ReproAsiPath $ReproAsiPath
    Add-Result 'deployment + runtime verification' $LASTEXITCODE

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-tom3-audio.ps1') `
        -GameDir $GameDir -AsiPath $AsiPath -ReproAsiPath $ReproAsiPath `
        -Scenario repro -DriveHz $DriveHz -MeasureSeconds $ReproSeconds -WarmupSeconds 26
    Add-Result 'benchmark: repro (leak must reproduce)' $LASTEXITCODE

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-tom3-audio.ps1') `
        -GameDir $GameDir -AsiPath $AsiPath -ReproAsiPath $ReproAsiPath `
        -Scenario both -DriveHz $DriveHz -MeasureSeconds $BothSeconds -WarmupSeconds 26
    Add-Result 'benchmark: both (leak must be fixed)' $LASTEXITCODE

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-tom3-audio.ps1') `
        -GameDir $GameDir -AsiPath $AsiPath -ReproAsiPath $ReproAsiPath `
        -Scenario fix -MeasureSeconds $FixSeconds -WarmupSeconds 25
    Add-Result 'benchmark: fix idle' $LASTEXITCODE

    $overall = if ($script:Failed -eq 0) { 0 } else { 1 }
} finally {
    Restore-Normal
}

Write-Host ''
Write-Host '== acceptance summary =='
foreach ($r in $script:results) {
    Write-Host ('  [{0}] {1} (exit {2})' -f $(if ($r.Exit -eq 0) { 'PASS' } else { 'FAIL' }), $r.Step, $r.Exit)
}
Write-Host ''
if ($overall -eq 0) {
    Write-Host ('ACCEPTANCE: PASS (' + $script:results.Count + ' steps)')
} else {
    Write-Host ('ACCEPTANCE: FAIL (' + $script:Failed + ' of ' + $script:results.Count + ' steps failed)')
}
exit $overall
