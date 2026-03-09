<#
.SYNOPSIS
  Ollama qwen3:8b コード生成時間ベンチマーク
.DESCRIPTION
  じゃんけんゲーム (HTML) のコード生成時間を計測。
  モデルロード済み状態で推論速度を計測する。
  既存の Ollama サーバーを壊さないよう、別ポートでベンチ用インスタンスを起動。
.PARAMETER Drive
  テスト対象ドライブレター (任意の大文字1文字)
.PARAMETER Runs
  計測回数 (デフォルト: 3)
.PARAMETER Port
  ベンチ用 Ollama のポート番号 (デフォルト: 11435)
.PARAMETER OutputDir
  結果出力ディレクトリ
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

# テスト対象モデル（大→小。メモリ不足時に小さいモデルにフォールバック）
$ModelNames = @("qwen3:8b", "qwen3:1.7b")

# OutputDir のデフォルト解決（$PSScriptRoot が空の場合に対応）
if (-not $OutputDir) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path) }
    $OutputDir = Join-Path (Split-Path $scriptDir -Parent) "results\vibe-local-bench"
}

$Prompt = @"
じゃんけんゲームを HTML + JavaScript で作成してください。
要件:
- グー、チョキ、パーのボタン
- コンピュータはランダムに手を選ぶ
- 勝敗を表示
- 戦績カウンター付き
- モダンな CSS デザイン
1つの HTML ファイルにまとめてください。
"@

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

function Measure-CodeGen {
    param([int]$RunNumber)

    Write-Host "[$Drive] Run $RunNumber/$Runs - Generating code..." -ForegroundColor Cyan

    $gpuBefore = Get-NvidiaSmi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $body = @{
        model  = $ModelName
        prompt = $Prompt
        stream = $false
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 600
        $sw.Stop()
        $genTime = [math]::Round($sw.Elapsed.TotalSeconds, 3)
        $success = $true
        $responseLen = $response.response.Length
        $tokenCount = if ($response.eval_count) { $response.eval_count } else { 0 }
        $tokensPerSec = if ($response.eval_duration -and $response.eval_duration -gt 0) {
            [math]::Round($response.eval_count / ($response.eval_duration / 1e9), 2)
        } else { 0 }

        # 生成コードを保存
        $codeFile = Join-Path $OutputDir "codegen_${Drive}_run${RunNumber}.html"
        $response.response | Set-Content -Path $codeFile -Encoding UTF8
    } catch {
        $sw.Stop()
        $genTime = [math]::Round($sw.Elapsed.TotalSeconds, 3)
        $success = $false
        $responseLen = 0
        $tokenCount = 0
        $tokensPerSec = 0
        Write-Host "  ERROR: $_" -ForegroundColor Red
    }

    $gpuAfter = Get-NvidiaSmi

    $result = [ordered]@{
        experiment     = "vibe-local-bench"
        test           = "codegen"
        drive          = $Drive
        run            = $RunNumber
        model          = $ModelName
        gen_time_s     = $genTime
        response_chars = $responseLen
        token_count    = $tokenCount
        tokens_per_sec = $tokensPerSec
        success        = $success
        gpu_before     = $gpuBefore
        gpu_after      = $gpuAfter
        timestamp      = (Get-Date -Format "o")
    }

    Write-Host "  Gen time: ${genTime}s | Tokens: $tokenCount | ${tokensPerSec} tok/s" -ForegroundColor $(if ($success) {"Green"} else {"Red"})
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

# メイン
Write-Host "`n=== vibe-local-bench: Code Generation Benchmark ===" -ForegroundColor Yellow
Write-Host "Drive: $Drive | Models: $($ModelNames -join ', ') | Runs: $Runs | Port: $Port`n"

foreach ($ModelName in $ModelNames) {
    $modelTag = $ModelName -replace ':', '_'
    $outFile = Join-Path $OutputDir "codegen_${Drive}_${modelTag}.json"

    # 中断再開: 既存結果があればスキップ
    if (Test-Path $outFile) {
        $existing = Get-Content $outFile -Raw | ConvertFrom-Json
        if ($existing.results.Count -ge $Runs -and ($existing.results | Where-Object { $_.success }).Count -gt 0) {
            Write-Host "SKIP: $outFile already exists with $($existing.results.Count) runs" -ForegroundColor DarkYellow
            continue
        }
    }

    Write-Host "`n--- Model: $ModelName ---" -ForegroundColor Cyan

    try {
        # ベンチ用 Ollama を起動
        Start-BenchOllama

        # モデル事前ロード
        Write-Host "Pre-loading model..." -ForegroundColor Gray
        $body = @{ model = $ModelName; prompt = "test"; stream = $false } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300 | Out-Null
        } catch {
            Write-Host "  Pre-load failed: $_ (skipping model)" -ForegroundColor Red
            continue
        }

        $results = @()
        for ($i = 1; $i -le $Runs; $i++) {
            $result = Measure-CodeGen -RunNumber $i
            $results += $result

            # 途中結果を保存
            $times = $results | Where-Object { $_.success } | ForEach-Object { $_.gen_time_s } | Sort-Object
            $median = if ($times.Count -gt 0) {
                $mid = [math]::Floor($times.Count / 2)
                if ($times.Count % 2 -eq 0) { ($times[$mid - 1] + $times[$mid]) / 2 } else { $times[$mid] }
            } else { $null }

            $summary = [ordered]@{
                experiment = "vibe-local-bench"
                test       = "codegen"
                drive      = $Drive
                model      = $ModelName
                runs       = $i
                runs_total = $Runs
                port       = $Port
                median_s   = $median
                results    = $results
                generated  = (Get-Date -Format "o")
            }
            $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
        }

        Write-Host "`n[$ModelName] Median codegen time: ${median}s" -ForegroundColor Yellow
        Write-Host "Results saved: $outFile"
    } catch {
        Write-Host "ERROR running $ModelName : $_" -ForegroundColor Red
    } finally {
        Stop-BenchOllama
    }
}

Write-Host "`n=== Code Generation Benchmark Complete ===" -ForegroundColor Green
