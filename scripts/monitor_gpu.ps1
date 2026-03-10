<#
.SYNOPSIS
    GPU 温度・電力モニタリング — 10秒間隔でバックグラウンド記録

.DESCRIPTION
    nvidia-smi を定期的にクエリし、温度/電力/VRAM/GPU使用率を
    CSV ファイルに記録する。ベンチマーク中にバックグラウンドで起動し、
    サーマルスロットリングの検出に利用する。

.PARAMETER OutFile
    出力 CSV ファイルパス (デフォルト: results/gpu_monitor.csv)

.PARAMETER Interval
    記録間隔 (秒, デフォルト: 10)

.PARAMETER Duration
    最大記録時間 (秒, 0=無制限, デフォルト: 0)

.EXAMPLE
    # バックグラウンドで起動
    Start-Job -FilePath .\scripts\monitor_gpu.ps1

    # 引数指定
    Start-Job -FilePath .\scripts\monitor_gpu.ps1 -ArgumentList "results\gpu_monitor_exp1.csv", 5, 600

    # フォアグラウンドで起動 (Ctrl+C で停止)
    .\scripts\monitor_gpu.ps1 -Interval 5

    # 30分間だけ記録
    .\scripts\monitor_gpu.ps1 -Duration 1800
#>

param(
    [string]$OutFile = "",
    [int]$Interval = 10,
    [int]$Duration = 0
)

$ErrorActionPreference = "Stop"

# Resolve output path
if (-not $OutFile) {
    $resultsDir = Join-Path $PSScriptRoot "..\results"
    if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutFile = Join-Path $resultsDir "gpu_monitor_$ts.csv"
}

# Verify nvidia-smi
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    Write-Error "nvidia-smi not found. Install NVIDIA drivers."
    exit 1
}

# CSV header
$header = "timestamp,temp_c,power_w,power_limit_w,gpu_util_pct,mem_util_pct,vram_used_mb,vram_total_mb,fan_pct,clock_gpu_mhz,clock_mem_mhz,pstate"
if (-not (Test-Path $OutFile)) {
    $header | Out-File -FilePath $OutFile -Encoding utf8
}

Write-Host "GPU Monitor started"
Write-Host "  Output:   $OutFile"
Write-Host "  Interval: ${Interval}s"
if ($Duration -gt 0) {
    Write-Host "  Duration: ${Duration}s"
}
Write-Host "  Press Ctrl+C to stop"
Write-Host ""

$queryFields = "temperature.gpu,power.draw,power.limit,utilization.gpu,utilization.memory,memory.used,memory.total,fan.speed,clocks.current.graphics,clocks.current.memory,pstate"

$startTime = Get-Date
$count = 0

try {
    while ($true) {
        $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

        # Query nvidia-smi
        $raw = & nvidia-smi --query-gpu=$queryFields --format=csv,noheader,nounits 2>&1
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $values = ($raw -as [string]).Trim()
            $line = "$now,$values"
            $line | Out-File -FilePath $OutFile -Encoding utf8 -Append

            # Parse for console display
            $parts = $values -split ",\s*"
            $temp = $parts[0]
            $power = $parts[1]
            $gpuUtil = $parts[3]
            $vramUsed = $parts[5]

            $count++
            Write-Host ("  [{0:D4}] {1}  Temp:{2}C  Power:{3}W  GPU:{4}%  VRAM:{5}MB" -f $count, $now, $temp, $power, $gpuUtil, $vramUsed)
        } else {
            Write-Warning "nvidia-smi query failed: $raw"
        }

        # Check duration limit
        if ($Duration -gt 0) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -ge $Duration) {
                Write-Host "`nDuration limit reached (${Duration}s). Stopping."
                break
            }
        }

        Start-Sleep -Seconds $Interval
    }
} finally {
    Write-Host "`nGPU Monitor stopped. $count samples recorded."
    Write-Host "Output: $OutFile"
}
