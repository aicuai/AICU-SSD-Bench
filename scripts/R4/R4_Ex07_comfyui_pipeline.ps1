<#
.SYNOPSIS
  Ex7: (Ex6 に統合済み — スキップ)
  Wan 2.2 → LTX 2.3 モデルスワップは Ex6 で計測
#>
param([int]$Runs = 1, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex7: Skipped (merged into Ex6 model swap bench) ===" -ForegroundColor DarkYellow

Push-Results "Ex7" "R4 Ex7: Skipped (merged into Ex6)"
Write-Host "`n=== Ex7 Complete (skipped) ===" -ForegroundColor Green
