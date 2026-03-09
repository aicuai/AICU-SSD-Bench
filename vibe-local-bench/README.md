# Experiment 1: vibe-local / Ollama ベンチマーク

## 概要

`qwen3:8b` モデルを使って、以下の2つを計測します：

1. **モデルロード時間** — ストレージ別のモデル読み込み速度
2. **コード生成時間** — じゃんけんゲーム（HTML）完成までのトータル時間

## 仮説

| ストレージ | 想定ロード時間（5.2GB） | 想定傾向 |
|-----------|----------------------|---------|
| Gen5 NVMe (D:) | ~3〜5秒 | ベースライン（最速） |
| SATA SSD (E:) | ~15〜30秒 | 4〜6倍遅い |
| HDD (F:) | ~60〜120秒 | 20倍以上遅い |
| リムーバブル Gen5 (G:) | ~3〜5秒 | D:と同等のはず |

**仮説**: Gen5 NVMe では体感「即起動」だが、HDD では待機が苦痛になる。  
リムーバブル（G:）は通常の Gen5（D:）と有意差なし。

## 計測項目

```
A. モデルロード時間 (秒)
   - Ollama の初回ロード（キャッシュなし）
   - 2回目ロード（VRAM展開後の再利用）※参考値

B. じゃんけんゲーム生成タスク
   - プロンプト送信〜HTMLファイル生成完了まで（秒）
   - 生成されたHTMLが正常動作するか（pass/fail）
   - 生成行数

C. 補助計測
   - VRAM使用量のピーク (GB)
   - GPU温度 (℃)
```

## 前提条件・セットアップ

```powershell
# Ollama インストール（未インストールの場合）
winget install Ollama.Ollama

# モデルを各ドライブにコピー
# ※ Ollama のデフォルトモデル保存先を変更する方法：
# 環境変数 OLLAMA_MODELS を設定する

# D: に配置
$env:OLLAMA_MODELS = "D:\ollama_models"
ollama pull qwen3:8b

# E: に配置
$env:OLLAMA_MODELS = "E:\ollama_models"
ollama pull qwen3:8b

# F: に配置
$env:OLLAMA_MODELS = "F:\ollama_models"
ollama pull qwen3:8b

# G: に配置
$env:OLLAMA_MODELS = "G:\ollama_models"
ollama pull qwen3:8b
```

## ベンチマークスクリプト

### `bench_load.ps1` — モデルロード時間計測

```powershell
# bench_load.ps1
# 使用方法: .\bench_load.ps1 -Drive D -Runs 3

param(
    [string]$Drive = "D",
    [int]$Runs = 3,
    [string]$Model = "qwen3:8b"
)

$results = @()
$modelsPath = "${Drive}:\ollama_models"

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "=== Run $i / $Runs (Drive: ${Drive}:) ===" -ForegroundColor Cyan

    # Ollama サービス停止 → モデルパス変更 → 再起動（キャッシュクリア）
    $env:OLLAMA_MODELS = $modelsPath
    Stop-Service -Name "Ollama" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service -Name "Ollama" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # ロード時間計測
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" `
        -Method POST `
        -ContentType "application/json" `
        -Body (@{
            model = $Model
            prompt = "hello"
            stream = $false
        } | ConvertTo-Json)
    $stopwatch.Stop()

    $loadTime = $stopwatch.Elapsed.TotalSeconds
    Write-Host "  Load time: ${loadTime}s" -ForegroundColor Green

    $results += [PSCustomObject]@{
        drive     = $Drive
        run       = $i
        model     = $Model
        load_sec  = [math]::Round($loadTime, 2)
        timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }
}

# 結果保存
$outDir = "results"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$results | ConvertTo-Json | Out-File "$outDir\load_${Drive}.json" -Encoding UTF8
$results | Export-Csv "$outDir\load_${Drive}.csv" -NoTypeInformation -Encoding UTF8

# サマリー表示
$median = ($results | Sort-Object load_sec)[[math]::Floor($Runs / 2)].load_sec
Write-Host "`n=== Summary: Drive ${Drive}: ===" -ForegroundColor Yellow
Write-Host "  Median load time: ${median}s"
```

### `bench_codegen.ps1` — じゃんけんゲーム生成ベンチ

```powershell
# bench_codegen.ps1
# 使用方法: .\bench_codegen.ps1 -Drive D -Runs 3

param(
    [string]$Drive = "D",
    [int]$Runs = 3,
    [string]$Model = "qwen3:8b"
)

$prompt = @"
日本語UIのじゃんけんゲームをHTMLで作ってください。
要件：
- グー・チョキ・パーのボタン
- コンピューターとの勝敗判定
- スコア表示
- 単一HTMLファイルで完結（外部ファイル不要）
HTMLファイルとして保存してください。
"@

$results = @()
$modelsPath = "${Drive}:\ollama_models"
$env:OLLAMA_MODELS = $modelsPath

for ($i = 1; $i -le $Runs; $i++) {
    Write-Host "=== Codegen Run $i / $Runs (Drive: ${Drive}:) ===" -ForegroundColor Cyan

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    # vibe-local 経由でコード生成（ワンショットモード）
    $output = & vibe-local -p $prompt 2>&1
    $stopwatch.Stop()
    
    $genTime = $stopwatch.Elapsed.TotalSeconds
    
    # 生成されたHTMLファイルを検索
    $htmlFile = Get-ChildItem -Filter "janken*.html" | Sort-Object LastWriteTime | Select-Object -Last 1
    $success = $null -ne $htmlFile
    $lineCount = if ($success) { (Get-Content $htmlFile.FullName).Count } else { 0 }
    
    Write-Host "  Gen time: ${genTime}s | Success: $success | Lines: $lineCount" -ForegroundColor Green

    $results += [PSCustomObject]@{
        drive      = $Drive
        run        = $i
        model      = $Model
        gen_sec    = [math]::Round($genTime, 2)
        success    = $success
        line_count = $lineCount
        timestamp  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }
    
    # 生成ファイルをリネームして保存
    if ($success) {
        Move-Item $htmlFile.FullName "results\janken_${Drive}_run${i}.html"
    }
    
    Start-Sleep -Seconds 5
}

$outDir = "results"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$results | ConvertTo-Json | Out-File "$outDir\codegen_${Drive}.json" -Encoding UTF8
$results | Export-Csv "$outDir\codegen_${Drive}.csv" -NoTypeInformation -Encoding UTF8

$successRate = ($results | Where-Object { $_.success }).Count / $Runs * 100
$medianGen = ($results | Sort-Object gen_sec)[[math]::Floor($Runs / 2)].gen_sec
Write-Host "`n=== Summary: Drive ${Drive}: ===" -ForegroundColor Yellow
Write-Host "  Median gen time: ${medianGen}s | Success rate: ${successRate}%"
```

### `run_all.ps1` — 全ドライブ一括実行

```powershell
# run_all.ps1
$drives = @("D", "E", "F", "G")

foreach ($drive in $drives) {
    Write-Host "`n=============================" -ForegroundColor Magenta
    Write-Host " Testing Drive: ${drive}:" -ForegroundColor Magenta
    Write-Host "=============================" -ForegroundColor Magenta
    
    .\bench_load.ps1 -Drive $drive -Runs 3
    Start-Sleep -Seconds 10
    .\bench_codegen.ps1 -Drive $drive -Runs 3
    Start-Sleep -Seconds 10
}

# 結果集計
Write-Host "`n=== ALL RESULTS ===" -ForegroundColor Yellow
$allLoad = $drives | ForEach-Object {
    $f = "results\load_$_.json"
    if (Test-Path $f) { Get-Content $f | ConvertFrom-Json }
}
$allLoad | Format-Table drive, run, load_sec
```

## 期待される結果フォーマット

```json
[
  {
    "drive": "D",
    "run": 1,
    "model": "qwen3:8b",
    "load_sec": 3.82,
    "timestamp": "2025-03-10T14:30:00"
  },
  ...
]
```
