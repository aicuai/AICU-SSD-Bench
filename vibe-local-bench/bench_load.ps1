<#
.SYNOPSIS
  Ollama qwen3:8b モデルロード時間ベンチマーク
.DESCRIPTION
  指定ドライブに配置した Ollama モデルのロード時間を計測。
  各回の前にモデルキャッシュをクリアし、コールドスタートを再現。
.PARAMETER Drive
  テスト対象ドライブレター (D, E, F, G)
.PARAMETER Runs
  計測回数 (デフォルト: 3)
.PARAMETER OutputDir
  結果出力ディレクトリ (デフォルト: ../results/vibe-local-bench)
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("D","E","F","G")]
    [string]$Drive,

    [int]$Runs = 3,

    [string]$OutputDir = "$PSScriptRoot\..\results\vibe-local-bench"
)

$ErrorActionPreference = "Stop"
$ModelName = "qwen3:8b"
$OllamaHost = "http://localhost:11434"

# 結果ディレクトリ作成
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

function Clear-OllamaCache {
    # アンロード: 全モデルを keep_alive=0 で解放
    try {
        $body = @{ model = $ModelName; keep_alive = 0 } | ConvertTo-Json
        Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
    Start-Sleep -Seconds 2
}

function Get-NvidiaSmi {
    try {
        $smi = & nvidia-smi --query-gpu=gpu_name,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>$null
        if ($smi) {
            $parts = $smi.Split(",") | ForEach-Object { $_.Trim() }
            return @{
                gpu_name      = $parts[0]
                vram_used_mb  = [int]$parts[1]
                vram_total_mb = [int]$parts[2]
                temp_c        = [int]$parts[3]
                power_w       = [double]$parts[4]
            }
        }
    } catch {}
    return @{}
}

function Measure-ModelLoad {
    param([int]$RunNumber)

    Write-Host "[$Drive] Run $RunNumber/$Runs - Clearing cache..." -ForegroundColor Cyan
    Clear-OllamaCache

    # nvidia-smi before
    $gpuBefore = Get-NvidiaSmi

    Write-Host "[$Drive] Run $RunNumber/$Runs - Loading model..." -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # ダミープロンプトでモデルロードを強制
    $body = @{
        model  = $ModelName
        prompt = "hello"
        stream = $false
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300
        $sw.Stop()
        $loadTime = [math]::Round($sw.Elapsed.TotalSeconds, 3)
        $success = $true
    } catch {
        $sw.Stop()
        $loadTime = [math]::Round($sw.Elapsed.TotalSeconds, 3)
        $success = $false
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }

    # nvidia-smi after
    $gpuAfter = Get-NvidiaSmi

    $result = [ordered]@{
        experiment  = "vibe-local-bench"
        test        = "model_load"
        drive       = $Drive
        run         = $RunNumber
        model       = $ModelName
        load_time_s = $loadTime
        success     = $success
        gpu_before  = $gpuBefore
        gpu_after   = $gpuAfter
        timestamp   = (Get-Date -Format "o")
    }

    Write-Host "  Load time: ${loadTime}s (success=$success)" -ForegroundColor $(if ($success) {"Green"} else {"Red"})
    return $result
}

# メイン実行
Write-Host "`n=== vibe-local-bench: Model Load Benchmark ===" -ForegroundColor Yellow
Write-Host "Drive: $Drive | Model: $ModelName | Runs: $Runs`n"

# OLLAMA_MODELS 環境変数を設定
$env:OLLAMA_MODELS = "${Drive}:\ollama\models"
Write-Host "OLLAMA_MODELS = $env:OLLAMA_MODELS"

$results = @()
for ($i = 1; $i -le $Runs; $i++) {
    $result = Measure-ModelLoad -RunNumber $i
    $results += $result
}

# 中央値計算
$times = $results | Where-Object { $_.success } | ForEach-Object { $_.load_time_s } | Sort-Object
$median = if ($times.Count -gt 0) {
    $mid = [math]::Floor($times.Count / 2)
    if ($times.Count % 2 -eq 0) { ($times[$mid - 1] + $times[$mid]) / 2 } else { $times[$mid] }
} else { $null }

$summary = [ordered]@{
    experiment  = "vibe-local-bench"
    test        = "model_load"
    drive       = $Drive
    model       = $ModelName
    runs        = $Runs
    median_s    = $median
    results     = $results
    generated   = (Get-Date -Format "o")
}

$outFile = Join-Path $OutputDir "load_${Drive}.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
Write-Host "`nMedian load time: ${median}s" -ForegroundColor Yellow
Write-Host "Results saved: $outFile`n"
