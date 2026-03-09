<#
.SYNOPSIS
  vibe-local-bench 全ドライブ一括実行
.DESCRIPTION
  D, E, F, G ドライブでモデルロード & コード生成ベンチマークを順次実行
.PARAMETER Runs
  各ドライブの計測回数 (デフォルト: 3)
#>
param(
    [int]$Runs = 3
)

$ErrorActionPreference = "Stop"
$Drives = @("D", "E", "F", "G")
$ScriptDir = $PSScriptRoot

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  vibe-local-bench: Full Benchmark Run" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

foreach ($drive in $Drives) {
    $modelPath = "${drive}:\ollama\models"
    if (-not (Test-Path $modelPath)) {
        Write-Host "SKIP: $modelPath not found" -ForegroundColor DarkYellow
        continue
    }

    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan

    # モデルロードベンチマーク
    & "$ScriptDir\bench_load.ps1" -Drive $drive -Runs $Runs

    # コード生成ベンチマーク
    & "$ScriptDir\bench_codegen.ps1" -Drive $drive -Runs $Runs
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  vibe-local-bench: Complete!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
Write-Host "Results: $(Resolve-Path "$ScriptDir\..\results\vibe-local-bench")"
