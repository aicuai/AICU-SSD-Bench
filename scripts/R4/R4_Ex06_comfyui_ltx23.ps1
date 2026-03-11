<#
.SYNOPSIS
  Ex6: LTX 2.3 コールドスタートベンチ (t2v → ia2v)
  各ドライブで ComfyUI を起動し、LTX 2.3 のモデルロード (コールドスタート) を計測

  フロー (各ドライブ):
    1. ComfyUI 起動
    2. LTX 2.3 t2v 実行 (コールドスタート = ディスクからモデルロード)
    3. LTX 2.3 ia2v 実行 (ウォームスタート = モデル VRAM 残存)
    4. ComfyUI 停止
#>
param([int]$Runs = 1, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex6: LTX 2.3 Cold Start Bench (t2v → ia2v) ===" -ForegroundColor Yellow
Ensure-Clean

$wfT2v   = "$benchDir\workflows\video_ltx2_3_t2v_api.json"
$wfIa2v  = "$benchDir\workflows\video_ltx2_3_ia2v_AiCuty.json"

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if (-not $proc) { continue }

    # Step 1: LTX 2.3 t2v (コールドスタート、ディスクからモデルロード)
    Write-Host "  [Step1] LTX 2.3 t2v (cold start)..." -ForegroundColor Cyan
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
        --workflow $wfT2v `
        --drive $drive --runs 1 `
        --host "http://127.0.0.1:${Port}" `
        --output-dir "$benchDir\results\comfyui-swap-bench-R4" `
        --timeout 600

    # Step 2: LTX 2.3 ia2v (ウォームスタート)
    Write-Host "  [Step2] LTX 2.3 ia2v (warm start)..." -ForegroundColor Green
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
        --workflow $wfIa2v `
        --drive $drive --runs 1 `
        --host "http://127.0.0.1:${Port}" `
        --output-dir "$benchDir\results\comfyui-swap-bench-R4" `
        --timeout 300

    Stop-ComfyUI -Proc $proc
}

Push-Results "Ex6" "R4 Ex6: LTX 2.3 cold/warm bench complete"
Write-Host "`n=== Ex6 Complete ===" -ForegroundColor Green
