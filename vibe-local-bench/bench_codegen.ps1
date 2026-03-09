<#
.SYNOPSIS
  Ollama qwen3:8b コード生成時間ベンチマーク
.DESCRIPTION
  じゃんけんゲーム (HTML) のコード生成時間を計測。
  モデルロード済み状態で推論速度を計測する。
.PARAMETER Drive
  テスト対象ドライブレター (D, E, F, G)
.PARAMETER Runs
  計測回数 (デフォルト: 3)
.PARAMETER OutputDir
  結果出力ディレクトリ
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

# メイン
Write-Host "`n=== vibe-local-bench: Code Generation Benchmark ===" -ForegroundColor Yellow
Write-Host "Drive: $Drive | Model: $ModelName | Runs: $Runs`n"

$env:OLLAMA_MODELS = "${Drive}:\ollama\models"

# モデル事前ロード
Write-Host "Pre-loading model..." -ForegroundColor Gray
$body = @{ model = $ModelName; prompt = "test"; stream = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$OllamaHost/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 300 | Out-Null

$results = @()
for ($i = 1; $i -le $Runs; $i++) {
    $result = Measure-CodeGen -RunNumber $i
    $results += $result
}

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
    runs       = $Runs
    median_s   = $median
    results    = $results
    generated  = (Get-Date -Format "o")
}

$outFile = Join-Path $OutputDir "codegen_${Drive}.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding UTF8
Write-Host "`nMedian codegen time: ${median}s" -ForegroundColor Yellow
Write-Host "Results saved: $outFile`n"
