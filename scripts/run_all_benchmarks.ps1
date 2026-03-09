<#
.SYNOPSIS
  全ベンチマーク一括実行スクリプト（標準ベンチマーク形式）
.DESCRIPTION
  一般的なベンチマークサイトと同じ形式で実行:
  1. テスト開始時のディスク残量チェック
  2. システム情報収集
  3. モデルダウンロード（タイミング計測）
  4. 各実験実行
  5. 巨大ファイル（モデル）を削除
  6. テスト終了時のディスク残量チェック
  7. サマリー JSON 出力（総所要時間、ダウンロード時間、ディスク差分）

  ※ 結果ディレクトリには JSON ログ、生成 HTML/画像/動画/MP3 のみ残る
.PARAMETER Runs
  各実験の計測回数 (デフォルト: 3)
.PARAMETER SkipComfyUI
  ComfyUI ベンチマーク (画像+動画) をスキップ
.PARAMETER SkipTTS
  TTS ベンチマークをスキップ
.PARAMETER SkipDownload
  モデルダウンロードをスキップ（既にモデルが配置済みの場合）
.PARAMETER SkipCleanup
  テスト後のモデル削除をスキップ
#>
param(
    [int]$Runs = 3,
    [switch]$SkipComfyUI,
    [switch]$SkipTTS,
    [switch]$SkipDownload,
    [switch]$SkipCleanup
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path $PSScriptRoot -Parent
$ResultsDir = Join-Path $RootDir "results"
$SuiteStartTime = Get-Date

if (-not (Test-Path $ResultsDir)) {
    New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
}

# ── ヘルパー関数 ──

function Get-DriveSpace {
    <# 指定ドライブの空き容量・総容量を取得 #>
    param([string]$DriveLetter)
    try {
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${DriveLetter}:'"
        if ($vol) {
            return [ordered]@{
                drive       = $DriveLetter
                free_gb     = [math]::Round($vol.FreeSpace / 1GB, 2)
                total_gb    = [math]::Round($vol.Size / 1GB, 2)
                used_gb     = [math]::Round(($vol.Size - $vol.FreeSpace) / 1GB, 2)
                free_pct    = [math]::Round($vol.FreeSpace / $vol.Size * 100, 1)
                timestamp   = (Get-Date -Format "o")
            }
        }
    } catch {}
    return [ordered]@{ drive = $DriveLetter; error = "not available" }
}

function Get-AllTestDriveSpace {
    <# テスト対象全ドライブの空き容量を取得 #>
    param([string[]]$Drives)
    $result = @()
    foreach ($d in $Drives) {
        $space = Get-DriveSpace -DriveLetter $d
        $result += $space
        Write-Host "  $($d): $($space.free_gb) GB free / $($space.total_gb) GB total ($($space.free_pct)%)" -ForegroundColor Gray
    }
    return $result
}

function Get-DirectorySize {
    <# ディレクトリの合計サイズ (MB) #>
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $size = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    return [math]::Round($size / 1MB, 2)
}

function Measure-OllamaPull {
    <# Ollama モデルのダウンロード時間を計測 #>
    param(
        [string]$ModelName,
        [string]$DriveLetter
    )
    $modelsPath = "${DriveLetter}:\ollama\models"
    if (-not (Test-Path (Split-Path $modelsPath -Parent))) {
        New-Item -ItemType Directory -Path (Split-Path $modelsPath -Parent) -Force | Out-Null
    }

    Write-Host "  Pulling $ModelName to ${DriveLetter}: ..." -ForegroundColor Cyan
    $env:OLLAMA_MODELS = $modelsPath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & ollama pull $ModelName 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        $sw.Stop()
        $success = $true
    } catch {
        $sw.Stop()
        $success = $false
        Write-Host "    ERROR: $_" -ForegroundColor Red
    }
    Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue

    $dirSize = Get-DirectorySize -Path $modelsPath
    return [ordered]@{
        model        = $ModelName
        drive        = $DriveLetter
        elapsed_s    = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        success      = $success
        model_dir_mb = $dirSize
        timestamp    = (Get-Date -Format "o")
    }
}

# ── テスト対象ドライブの自動検出 ──
$AllDriveLetters = @("C", "D", "E", "F", "G", "H", "I", "J")
$TestDrives = $AllDriveLetters | Where-Object {
    Test-Path "${_}:\ollama\models"
}
if ($TestDrives.Count -eq 0) {
    # ダウンロードモード: ボリュームが存在するドライブを検出
    $TestDrives = $AllDriveLetters | Where-Object {
        (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${_}:'" -ErrorAction SilentlyContinue) -ne $null
    } | Where-Object { $_ -notin @("I", "J") }  # Google Drive 仮想ドライブ除外
}

# Ollama テスト用モデル一覧
$OllamaModels = @("qwen3:8b", "qwen3:1.7b")

Write-Host @"

 =====================================================
   ai-storage-bench - Full Benchmark Suite
 =====================================================
   Runs per experiment: $Runs
   Test drives:         $($TestDrives -join ', ')
   Start:               $($SuiteStartTime.ToString("yyyy-MM-dd HH:mm:ss"))
 =====================================================

"@ -ForegroundColor Yellow

# ══════════════════════════════════════════════════════
# Phase 1: テスト開始時のディスク残量チェック
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 1] Disk space check (BEFORE)" -ForegroundColor Yellow
$diskBefore = Get-AllTestDriveSpace -Drives $TestDrives

# ══════════════════════════════════════════════════════
# Phase 2: システム情報収集
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 2] Collecting system info..." -ForegroundColor Yellow
$sysInfoSw = [System.Diagnostics.Stopwatch]::StartNew()
& "$PSScriptRoot\collect_sysinfo.ps1" -OutputDir $ResultsDir
$sysInfoSw.Stop()
Write-Host "  System info collected in $([math]::Round($sysInfoSw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green

# ══════════════════════════════════════════════════════
# Phase 3: モデルダウンロード（タイミング計測）
# ══════════════════════════════════════════════════════
$downloadResults = @()
if (-not $SkipDownload) {
    Write-Host "`n[Phase 3] Model download (timed)" -ForegroundColor Yellow
    $downloadSw = [System.Diagnostics.Stopwatch]::StartNew()

    # 各テストドライブに Ollama モデルをダウンロード
    $drivesWithModels = $TestDrives | Where-Object { Test-Path "${_}:\ollama\models" }
    if ($drivesWithModels.Count -eq 0) {
        Write-Host "  No drives with ollama\models found. Creating model dirs..." -ForegroundColor DarkYellow
        foreach ($d in $TestDrives) {
            $modelsDir = "${d}:\ollama\models"
            if (-not (Test-Path $modelsDir)) {
                New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
                Write-Host "  Created: $modelsDir" -ForegroundColor Gray
            }
        }
        $drivesWithModels = $TestDrives
    }

    foreach ($d in $drivesWithModels) {
        foreach ($model in $OllamaModels) {
            # モデルが既に存在するかチェック
            $env:OLLAMA_MODELS = "${d}:\ollama\models"
            $alreadyExists = $false
            try {
                $tags = & ollama list 2>$null
                if ($tags -match ($model -replace ':', '\:')) {
                    $alreadyExists = $true
                }
            } catch {}
            Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue

            if ($alreadyExists) {
                Write-Host "  SKIP: $model already exists on ${d}:" -ForegroundColor DarkYellow
                $downloadResults += [ordered]@{
                    model     = $model
                    drive     = $d
                    elapsed_s = 0
                    success   = $true
                    skipped   = $true
                    timestamp = (Get-Date -Format "o")
                }
            } else {
                $dlResult = Measure-OllamaPull -ModelName $model -DriveLetter $d
                $downloadResults += $dlResult
                $speed = if ($dlResult.elapsed_s -gt 0 -and $dlResult.model_dir_mb -gt 0) {
                    [math]::Round($dlResult.model_dir_mb / $dlResult.elapsed_s, 1)
                } else { 0 }
                Write-Host "  $model -> ${d}: $($dlResult.elapsed_s)s ($speed MB/s)" -ForegroundColor $(if ($dlResult.success) {"Green"} else {"Red"})
            }
        }
    }

    $downloadSw.Stop()
    $totalDownloadTime = [math]::Round($downloadSw.Elapsed.TotalSeconds, 2)
    Write-Host "`n  Total download time: ${totalDownloadTime}s" -ForegroundColor Green
} else {
    Write-Host "`n[Phase 3] SKIP: Model download (--SkipDownload)" -ForegroundColor DarkYellow
    $totalDownloadTime = 0
}

# ══════════════════════════════════════════════════════
# Phase 4: ベンチマーク実行
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 4] Running benchmarks..." -ForegroundColor Yellow
$benchSw = [System.Diagnostics.Stopwatch]::StartNew()
$stepTimes = [ordered]@{}

# ── 4a: vibe-local-bench ──
Write-Host "`n  [4a] vibe-local-bench (Ollama model load & codegen)..." -ForegroundColor Cyan
$sw4a = [System.Diagnostics.Stopwatch]::StartNew()
$vibeScript = Join-Path $RootDir "vibe-local-bench\run_all.ps1"
if (Test-Path $vibeScript) {
    try { & $vibeScript -Runs $Runs } catch { Write-Host "  ERROR: $_" -ForegroundColor Red }
} else {
    Write-Host "  SKIP: $vibeScript not found" -ForegroundColor DarkYellow
}
$sw4a.Stop()
$stepTimes["vibe_local_bench"] = [math]::Round($sw4a.Elapsed.TotalSeconds, 2)

# ── 4b: comfyui-imggen-bench ──
if (-not $SkipComfyUI) {
    Write-Host "`n  [4b] comfyui-imggen-bench (z-image-turbo)..." -ForegroundColor Cyan
    $sw4b = [System.Diagnostics.Stopwatch]::StartNew()
    $imggenScript = Join-Path $RootDir "comfyui-imggen-bench\bench_imggen.py"
    if (Test-Path $imggenScript) {
        try { py $imggenScript --all-drives --runs $Runs } catch { Write-Host "  ERROR: $_" -ForegroundColor Red }
    } else {
        Write-Host "  SKIP: $imggenScript not found" -ForegroundColor DarkYellow
    }
    $sw4b.Stop()
    $stepTimes["comfyui_imggen"] = [math]::Round($sw4b.Elapsed.TotalSeconds, 2)
} else {
    Write-Host "`n  [4b] SKIP: comfyui-imggen-bench (--SkipComfyUI)" -ForegroundColor DarkYellow
}

# ── 4c: comfyui-ltx-bench ──
if (-not $SkipComfyUI) {
    Write-Host "`n  [4c] comfyui-ltx-bench (LTX-Video)..." -ForegroundColor Cyan
    $sw4c = [System.Diagnostics.Stopwatch]::StartNew()
    $comfyScript = Join-Path $RootDir "comfyui-ltx-bench\bench_comfyui.py"
    if (Test-Path $comfyScript) {
        try { py $comfyScript --all-drives --runs $Runs } catch { Write-Host "  ERROR: $_" -ForegroundColor Red }
    } else {
        Write-Host "  SKIP: $comfyScript not found" -ForegroundColor DarkYellow
    }
    $sw4c.Stop()
    $stepTimes["comfyui_ltx"] = [math]::Round($sw4c.Elapsed.TotalSeconds, 2)
} else {
    Write-Host "`n  [4c] SKIP: comfyui-ltx-bench (--SkipComfyUI)" -ForegroundColor DarkYellow
}

# ── 4d: qwen3tts-bench ──
if (-not $SkipTTS) {
    Write-Host "`n  [4d] qwen3tts-bench (Qwen3-TTS)..." -ForegroundColor Cyan
    $sw4d = [System.Diagnostics.Stopwatch]::StartNew()
    $ttsScript = Join-Path $RootDir "qwen3tts-bench\bench_tts.py"
    if (Test-Path $ttsScript) {
        try { py $ttsScript --all-drives --runs $Runs } catch { Write-Host "  ERROR: $_" -ForegroundColor Red }
    } else {
        Write-Host "  SKIP: $ttsScript not found" -ForegroundColor DarkYellow
    }
    $sw4d.Stop()
    $stepTimes["qwen3tts"] = [math]::Round($sw4d.Elapsed.TotalSeconds, 2)
} else {
    Write-Host "`n  [4d] SKIP: qwen3tts-bench (--SkipTTS)" -ForegroundColor DarkYellow
}

$benchSw.Stop()
$totalBenchTime = [math]::Round($benchSw.Elapsed.TotalSeconds, 2)

# ══════════════════════════════════════════════════════
# Phase 5: クリーンアップ（巨大ファイル削除）
# ══════════════════════════════════════════════════════
$cleanupResults = @()
if (-not $SkipCleanup) {
    Write-Host "`n[Phase 5] Cleanup: removing large model files..." -ForegroundColor Yellow

    foreach ($d in $TestDrives) {
        $modelsPath = "${d}:\ollama\models"
        if (Test-Path $modelsPath) {
            $sizeBefore = Get-DirectorySize -Path $modelsPath
            Write-Host "  ${d}:\ollama\models ($sizeBefore MB) -> deleting..." -ForegroundColor Gray
            try {
                Remove-Item -Path $modelsPath -Recurse -Force
                $sizeAfter = 0
                Write-Host "  ${d}:\ollama\models deleted" -ForegroundColor Green
            } catch {
                $sizeAfter = Get-DirectorySize -Path $modelsPath
                Write-Host "  WARNING: partial cleanup: $_" -ForegroundColor DarkYellow
            }
            $cleanupResults += [ordered]@{
                drive     = $d
                path      = $modelsPath
                before_mb = $sizeBefore
                after_mb  = $sizeAfter
                freed_mb  = [math]::Round($sizeBefore - $sizeAfter, 2)
            }
        }
    }

    # 生成 HTML ファイルはログとして残す（削除しない）
    Write-Host "`n  Keeping result files (JSON, HTML, images, video, MP3):" -ForegroundColor Gray
    $keptFiles = Get-ChildItem -Path $ResultsDir -Recurse -File -ErrorAction SilentlyContinue
    $keptByExt = $keptFiles | Group-Object Extension | ForEach-Object {
        $totalSize = ($_.Group | Measure-Object -Property Length -Sum).Sum
        Write-Host "    $($_.Name): $($_.Count) files ($([math]::Round($totalSize / 1MB, 2)) MB)" -ForegroundColor DarkGray
        [ordered]@{
            extension = $_.Name
            count     = $_.Count
            size_mb   = [math]::Round($totalSize / 1MB, 2)
        }
    }
} else {
    Write-Host "`n[Phase 5] SKIP: Cleanup (--SkipCleanup)" -ForegroundColor DarkYellow
}

# ══════════════════════════════════════════════════════
# Phase 6: テスト終了時のディスク残量チェック
# ══════════════════════════════════════════════════════
Write-Host "`n[Phase 6] Disk space check (AFTER)" -ForegroundColor Yellow
$diskAfter = Get-AllTestDriveSpace -Drives $TestDrives

# ディスク使用量の差分表示
Write-Host "`n  Disk space delta:" -ForegroundColor Cyan
for ($i = 0; $i -lt $TestDrives.Count; $i++) {
    $before = $diskBefore | Where-Object { $_.drive -eq $TestDrives[$i] }
    $after  = $diskAfter  | Where-Object { $_.drive -eq $TestDrives[$i] }
    if ($before -and $after -and $before.free_gb -and $after.free_gb) {
        $delta = [math]::Round($after.free_gb - $before.free_gb, 2)
        $sign = if ($delta -ge 0) { "+" } else { "" }
        Write-Host "    $($TestDrives[$i]): $($before.free_gb) GB -> $($after.free_gb) GB (${sign}${delta} GB)" -ForegroundColor $(if ($delta -ge 0) {"Green"} else {"DarkYellow"})
    }
}

# ══════════════════════════════════════════════════════
# Phase 7: サマリー出力
# ══════════════════════════════════════════════════════
$SuiteEndTime = Get-Date
$TotalDuration = $SuiteEndTime - $SuiteStartTime

$summary = [ordered]@{
    suite           = "ai-storage-bench"
    version         = "2.0"
    hostname        = $env:COMPUTERNAME
    start_time      = $SuiteStartTime.ToString("o")
    end_time        = $SuiteEndTime.ToString("o")
    total_duration_s = [math]::Round($TotalDuration.TotalSeconds, 2)
    total_duration_hms = $TotalDuration.ToString("hh\:mm\:ss")
    runs_per_experiment = $Runs
    test_drives     = $TestDrives
    disk_before     = $diskBefore
    disk_after      = $diskAfter
    download        = [ordered]@{
        total_s = $totalDownloadTime
        skipped = [bool]$SkipDownload
        details = $downloadResults
    }
    benchmark       = [ordered]@{
        total_s    = $totalBenchTime
        step_times = $stepTimes
    }
    cleanup         = [ordered]@{
        skipped = [bool]$SkipCleanup
        details = $cleanupResults
        kept_files = $keptByExt
    }
    generated       = (Get-Date -Format "o")
}

$summaryFile = Join-Path $ResultsDir "bench_summary.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryFile -Encoding UTF8

Write-Host @"

 =====================================================
   COMPLETE
 =====================================================
   Total time:    $($TotalDuration.ToString("hh\:mm\:ss"))
   Download:      ${totalDownloadTime}s
   Benchmarks:    ${totalBenchTime}s
   Results:       $ResultsDir
   Summary:       $summaryFile
 =====================================================

"@ -ForegroundColor Green

# 結果ファイル一覧
Write-Host "Generated files:" -ForegroundColor Cyan
Get-ChildItem -Path $ResultsDir -Recurse -File | ForEach-Object {
    $sizeKB = [math]::Round($_.Length / 1KB, 1)
    Write-Host "  $($_.FullName) ($sizeKB KB)"
}

# ステップ別所要時間
Write-Host "`nStep breakdown:" -ForegroundColor Cyan
foreach ($key in $stepTimes.Keys) {
    $t = $stepTimes[$key]
    $mins = [math]::Floor($t / 60)
    $secs = [math]::Round($t % 60, 1)
    Write-Host "  $key : ${mins}m ${secs}s"
}
