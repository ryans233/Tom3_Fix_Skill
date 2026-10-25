#Requires -Version 5.1
<#
    check-submission.ps1 - static compliance and artifact format checks.

    This does NOT start the game and does NOT judge the fix's behavior. It
    checks that the submission contains no game files / dumps / decompiler
    output and that the two .asi artifacts are 32-bit PE DLLs.

    Usage:
      powershell -ExecutionPolicy Bypass -File tools\check-submission.ps1
      powershell -ExecutionPolicy Bypass -File tools\check-submission.ps1 -Root . -AsiPath build\Tom3_Fix.asi

    Exit code: 0 = no failures, 1 = at least one failure.
#>
param(
    [string]$Root,
    [string]$AsiPath,
    [string]$ReproAsiPath,
    [switch]$SkipArtifacts
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host ("ERROR: repository root not found: " + $Root)
    exit 1
}
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')

if (-not $AsiPath)      { $AsiPath = Join-Path $Root 'build\Tom3_Fix.asi' }
if (-not $ReproAsiPath) { $ReproAsiPath = Join-Path $Root 'build\Tom3AudioLeakRepro.asi' }
if (-not [IO.Path]::IsPathRooted($AsiPath))      { $AsiPath = Join-Path $Root $AsiPath }
if (-not [IO.Path]::IsPathRooted($ReproAsiPath)) { $ReproAsiPath = Join-Path $Root $ReproAsiPath }

$script:Fail = 0
$script:Warn = 0
$script:Info = 0

function Line([string]$level, [string]$text) {
    switch ($level) {
        'PASS' { Write-Host ('  [PASS] ' + $text) }
        'FAIL' { Write-Host ('  [FAIL] ' + $text); $script:Fail++ }
        'WARN' { Write-Host ('  [WARN] ' + $text); $script:Warn++ }
        default { Write-Host ('  [INFO] ' + $text); $script:Info++ }
    }
}

function Section([string]$name) { Write-Host ''; Write-Host ('== ' + $name + ' ==') }

function Get-Relative([string]$path) {
    return $path.Substring($Root.Length).TrimStart('\', '/')
}

# ---------------------------------------------------------------- tree scan ---
# Game executables/assets and reverse-engineering by-products must never be
# committed or shipped with a submission.
$forbiddenNames = @(
    'TreasuresOfMontezuma3.exe'
    'TreasuresOfMontezuma3.exe.bak'
    'OpenAL32.dll'
    'wrap_oal.dll'
    'magic.dll'
    'dinput8.dll'
)
$forbiddenExt = @(
    '.dmp', '.mdmp',
    '.id0', '.id1', '.id2', '.idb', '.i64', '.nam', '.til',
    '.hexrays'
)
$decompiledName = [regex]'(?i)\.(decompiled|pseudocode|hexrays)\.'

Section 'submission tree'
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notlike '*\.git\*' -and $_.FullName -notlike '*/.git/*' })

$bad = 0
foreach ($f in $files) {
    $rel = Get-Relative $f.FullName
    $name = $f.Name.ToLowerInvariant()
    $ext = $f.Extension.ToLowerInvariant()

    if ($forbiddenNames -contains $name) {
        Line 'FAIL' ("forbidden game/loader file: " + $rel)
        $bad++
        continue
    }
    if ($forbiddenExt -contains $ext) {
        Line 'FAIL' ("forbidden reverse-engineering artifact: " + $rel)
        $bad++
        continue
    }
    if ($decompiledName.IsMatch($f.Name)) {
        Line 'FAIL' ("decompiled/pseudocode output: " + $rel)
        $bad++
        continue
    }
    if ($ext -eq '.asi' -and $rel -notlike 'build\*' -and $rel -notlike 'build/*') {
        Line 'WARN' ("binary artifact outside build/: " + $rel)
    }
    if ($f.Length -gt 100MB) {
        Line 'WARN' ("large file (>100 MB), verify it is not a dump: " + $rel)
    }
}
if ($bad -eq 0) { Line 'PASS' ("no game files, dumps, IDA databases or decompiled listings (" + $files.Count + " files scanned)") }

# ------------------------------------------------------------- PE artifacts ---
function Test-PeDll([string]$path) {
    $r = [pscustomobject]@{ Ok = $false; Reason = ''; Machine = 0; Characteristics = 0 }
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
    } catch {
        $r.Reason = 'cannot read'
        return $r
    }
    if ($bytes.Length -lt 0x40) { $r.Reason = 'too small'; return $r }
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($pe -lt 0 -or ($pe + 24) -gt $bytes.Length) { $r.Reason = 'bad e_lfanew'; return $r }
    if ([Text.Encoding]::ASCII.GetString($bytes, $pe, 4) -ne "PE`0`0") { $r.Reason = 'bad PE signature'; return $r }
    $r.Machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
    $r.Characteristics = [BitConverter]::ToUInt16($bytes, $pe + 22)
    if ($r.Machine -ne 0x014C) { $r.Reason = ('machine 0x{0:X4}, expected 0x014C (i386)' -f $r.Machine); return $r }
    if (-not ($r.Characteristics -band 0x2000)) { $r.Reason = 'not built as a DLL'; return $r }
    $r.Ok = $true
    return $r
}

if (-not $SkipArtifacts) {
    Section 'artifacts'
    foreach ($item in @(
        @{ Name = 'Tom3_Fix.asi'; Path = $AsiPath },
        @{ Name = 'Tom3AudioLeakRepro.asi'; Path = $ReproAsiPath }
    )) {
        if (-not (Test-Path -LiteralPath $item.Path)) {
            Line 'FAIL' ($item.Name + ' missing: ' + $item.Path)
            continue
        }
        $info = Get-Item -LiteralPath $item.Path
        $pe = Test-PeDll $item.Path
        if ($pe.Ok) {
            Line 'PASS' ('{0}: {1:N0} B, i386 DLL (characteristics=0x{2:X4})' -f $item.Name, $info.Length, $pe.Characteristics)
        } else {
            Line 'FAIL' ('{0}: {1}' -f $item.Name, $pe.Reason)
        }
    }
}

# ------------------------------------------------------------------ summary ---
Write-Host ''
Write-Host ("SUMMARY: failures=$script:Fail warnings=$script:Warn")
if ($script:Fail -eq 0) { Write-Host 'RESULT: PASS'; exit 0 } else { Write-Host 'RESULT: FAIL'; exit 1 }
