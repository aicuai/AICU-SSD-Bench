<#
.SYNOPSIS
  Ollama qwen3:8b モデルロード時間ベンチマーク
.DESCRIPTION
  指定ドライブに配置した Ollama モデルのロード時間を計測。
  各回の前にモデルキャッシュをクリアし、コールドスタートを再現。
  既存の Ollama サーバーを壊さないよう、別ポートでベンチ用インスタンスを起動。
.PARAMETER Drive
  テスト対象ドライブレター (任意の大文字1文字)
.PARAMETER Runs
  計測回数 (デフォルト: 3)
.PARAMETER Port
  ベンチ用 Ollama のポート番号 (デフォルト: 11435)
.PARAMETER OutputDir
  結果出力ディレクトリ (デフォルト: ../results/vibe-local-bench)
#>
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[A-Z]$")]
    [string]$Drive,

    [int]$Runs = 3,

    [int]$Port = 11435,

    [string]$OutputDir
)

$ErrorActionPreference = "Stop"
$OllamaHost = "http://localhost:$Port"
$BenchOllamaPid = $null

# テスト対象モデル（大→小の順。メモリ不足時に小さいモデルにフォールバック）
$ModelNames = @("qwen3:8b", "qwen3:1.7b")

# OutputDir のデフォルト解決（$PSScriptRoot が空の場合に対応）
if (-not $OutputDir) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path) }
    $OutputDir = Join-Path (Split-Path $scriptDir -Parent) "results\vibe-local-bench"
}

# 結果ディレクトリ作成
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

function Start-BenchOllama {
    <# 既存サーバーを残したまま、別ポートでベンチ用 Ollama を起動 #>
    $modelsPath = "${Drive}:\ollama\models"
    if (-not (Test-Path $modelsPath)) {
        throw "Models path not found: $modelsPath`nRun: `$env:OLLAMA_MODELS='$modelsPath'; ollama pull $ModelName"
    }
    Write-Host "Starting bench Ollama on port $Port (OLLAMA_MODELS=$modelsPath)" -ForegroundColor Gray

    # ベンチ用ポートが既に使われていないか確認
    try {
        Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 2 | Out-Null
        Write-Host "Bench Ollama already running on port $Port" -ForegroundColor Green
        return
    } catch {}

    # 環境変数を設定してベンチ用 Ollama を起動
    $env:OLLAMA_MODELS = $modelsPath
    $env:OLLAMA_HOST = "127.0.0.1:$Port"
    Write-Host "  ENV: OLLAMA_HOST=$env:OLLAMA_HOST OLLAMA_MODELS=$env:OLLAMA_MODELS" -ForegroundColor DarkGray
    $proc = Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -PassThru `
        -RedirectStandardError "$env:TEMP\ollama_bench_${Port}.log"
    $script:BenchOllamaPid = $proc.Id
    Write-Host "  Process started: PID=$($proc.Id)" -ForegroundColor DarkGray
    # 子プロセス起動完了を待ってから環境変数をクリア
    Start-Sleep -Seconds 3
    Remove-Item Env:OLLAMA_HOST -ErrorAction SilentlyContinue
    Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue

    # API 準備待ち (最大60秒)
    $ready = $false
    for ($w = 0; $w -lt 20; $w++) {
        try {
            Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 3 | Out-Null
            $ready = $true
            break
        } catch {
            Write-Host "  Waiting for Ollama (attempt $($w+1)/20)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 3
        }
    }
    if (-not $ready) {
        # エラーログを表示
        $errLog = "$env:TEMP\ollama_bench_${Port}.log"
        if (Test-Path $errLog) {
            Write-Host "  Ollama stderr:" -ForegroundColor Red
            Get-Content $errLog | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        }
        Write-Host "  Process alive: $(-not $proc.HasExited)" -ForegroundColor Red
        Stop-BenchOllama
        throw "Ollama server failed to start on port $Port with OLLAMA_MODELS=$modelsPath"
    }
    Write-Host "Bench Ollama ready (PID=$($proc.Id), port=$Port)" -ForegroundColor Green
}

function Stop-BenchOllama {
    <# ベンチ用 Ollama のみ停止（既存サーバーは残す） #>
    if ($script:BenchOllamaPid) {
        try {
            Stop-Process -Id $script:BenchOllamaPid -Force -ErrorAction SilentlyContinue
            Write-Host "Stopped bench Ollama (PID=$($script:BenchOllamaPid))" -ForegroundColor Gray
        } catch {}
        $script:BenchOllamaPid = $null
    }
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

function Parse-OllamaLog {
    <# Ollama stderr ログからモデルロード内部タイミングを抽出 #>
    $logFile = "$env:TEMP\ollama_bench_${Port}.log"
    $info = [ordered]@{}
    if (-not (Test-Path $logFile)) { return $info }
    $lines = Get-Content $logFile -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ($line -match 'llama runner started in ([\d.]+) seconds') {
            $info["runner_started_s"] = [double]$Matches[1]
        }
        if ($line -match 'model weights.*size="([^"]+)"') {
            $info["model_weights"] = $Matches[1]
        }
        if ($line -match 'offloaded (\d+)/(\d+) layers to GPU') {
            $info["gpu_layers"] = "$($Matches[1])/$($Matches[2])"
        }
        if ($line -match 'total memory.*size="([^"]+)"') {
            $info["total_memory"] = $Matches[1]
        }
    }
    return $info
}

function Measure-ModelLoad {
    param([int]$RunNumber)

    # コールドスタートを確実にするため、ベンチ用 Ollama を毎回再起動
    Write-Host "[$Drive] Run $RunNumber/$Runs - Restarting Ollama for cold start..." -ForegroundColor Cyan
    Stop-BenchOllama
    # メモリ解放を待つ（モデル 5GB+ を RAM から解放する時間が必要）
    Start-Sleep -Seconds 8

    # ログファイルをクリア
    $logFile = "$env:TEMP\ollama_bench_${Port}.log"
    if (Test-Path $logFile) { Remove-Item $logFile -Force }

    Start-BenchOllama

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

    # Ollama 内部ログを解析
    Start-Sleep -Seconds 1
    $ollamaLog = Parse-OllamaLog

    $result = [ordered]@{
        experiment       = "vibe-local-bench"
        test             = "model_load"
        drive            = $Drive
        run              = $RunNumber
        model            = $ModelName
        load_time_s      = $loadTime
        success          = $success
        ollama_internal  = $ollamaLog
        gpu_before       = $gpuBefore
        gpu_after        = $gpuAfter
        timestamp        = (Get-Date -Format "o")
    }

    $runnerInfo = if ($ollamaLog["runner_started_s"]) { " | runner: $($ollamaLog["runner_started_s"])s" } else { "" }
    Write-Host "  Load time: ${loadTime}s${runnerInfo} (success=$success)" -ForegroundColor $(if ($success) {"Green"} else {"Red"})
    return $result
}

# デフォルト Ollama のモデルを解放してメモリを確保
Write-Host "Freeing memory from default Ollama..." -ForegroundColor Gray
foreach ($m in $ModelNames) {
    try {
        $body = @{ model = $m; keep_alive = 0 } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $body -ContentType "application/json" -ErrorAction SilentlyContinue | Out-Null
    } catch {}
}
Start-Sleep -Seconds 3

# メイン実行: 各モデルで順次ベンチマーク
Write-Host "`n=== vibe-local-bench: Model Load Benchmark ===" -ForegroundColor Yellow
Write-Host "Drive: $Drive | Models: $($ModelNames -join ', ') | Runs: $Runs | Port: $Port`n"

foreach ($ModelName in $ModelNames) {
    $modelTag = $ModelName -replace ':', '_'
    $outFile = Join-Path $OutputDir "load_${Drive}_${modelTag}.json"

    # 中断再開: 既に完了済みの結果があればスキップ
    if (Test-Path $outFile) {
        $existing = Get-Content $outFile -Raw | ConvertFrom-Json
        if ($existing.results.Count -ge $Runs -and ($existing.results | Where-Object { $_.success }).Count -gt 0) {
            Write-Host "SKIP: $outFile already exists with $($existing.results.Count) runs" -ForegroundColor DarkYellow
            continue
        }
    }

    Write-Host "`n--- Model: $ModelName ---" -ForegroundColor Cyan

    try {
        $results = @()
        for ($i = 1; $i -le $Runs; $i++) {
            $result = Measure-ModelLoad -RunNumber $i
            $results += $result

            # 途中結果を保存（中断時にも結果が残る）
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
                runs        = $i
                runs_total  = $Runs
                port        = $Port
                median_s    = $median
                results     = $results
                generated   = (Get-Date -Format "o")
            }
            $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
        }

        Write-Host "`n[$ModelName] Median load time: ${median}s" -ForegroundColor Yellow
        Write-Host "Results saved: $outFile"
    } catch {
        Write-Host "ERROR running $ModelName : $_" -ForegroundColor Red
    } finally {
        Stop-BenchOllama
    }
}

Write-Host "`n=== Model Load Benchmark Complete ===" -ForegroundColor Green
