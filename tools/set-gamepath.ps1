#Requires -Version 5.1
<#
    set-gamepath.ps1 - remember where The Treasures of Montezuma 3 is installed.

    Writes tools\gamepath.txt (git-ignored). Every acceptance script reads the
    game folder in this order:
      -GameDir parameter  >  TOM3_GAMEDIR environment variable  >  tools\gamepath.txt

    Usage:
      powershell -ExecutionPolicy Bypass -File tools\set-gamepath.ps1 -GameDir "E:\Steam\steamapps\common\The Treasures of Montezuma 3"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDir
)

$ErrorActionPreference = 'Stop'
$GameDir = $GameDir.TrimEnd('\')
$exe = Join-Path $GameDir 'TreasuresOfMontezuma3.exe'
if (-not (Test-Path $exe)) {
    Write-Host ("ERROR: not found: " + $exe)
    exit 1
}

$file = Join-Path $PSScriptRoot 'gamepath.txt'
Set-Content -Path $file -Value $GameDir -Encoding ASCII
Write-Host ("game folder saved to " + $file)
Write-Host ("  " + $GameDir + "   (git-ignored)")
