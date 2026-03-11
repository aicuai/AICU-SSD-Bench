<#
.SYNOPSIS
  Ex6: モデル切り替えベンチ (Wan 2.2 → LTX 2.3 t2v → LTX 2.3 ia2v)
  同一 ComfyUI セッション内でモデルスワップのコールドスタートを計測

  フロー (各ドライブ):
    1. ComfyUI 起動
    2. Wan 2.2 t2v 実行 (VRAM に Wan モデルをロード)
    3. LTX 2.3 t2v 実行 (モデルスワップ = ディスクから再ロード → コールドスタート計測)
    4. LTX 2.3 ia2v 実行 (LTX モデルは VRAM に残っている → ウォームスタート計測)
    5. ComfyUI 停止
#>
param([int]$Runs = 1, [string[]]$Drives = @("D","E","F","G"), [int]$Port = 8188)
. "$PSScriptRoot\_common.ps1"

Write-Host "`n=== Ex6: Model Swap Bench (Wan2.2 → LTX2.3 t2v → ia2v) ===" -ForegroundColor Yellow
Ensure-Clean

$wfWan   = "$benchDir\workflows\wan2_2_14B_t2v_api.json"
$wfT2v   = "$benchDir\workflows\video_ltx2_3_t2v_api.json"
$wfIa2v  = "$benchDir\workflows\video_ltx2_3_ia2v_AiCuty.json"

foreach ($drive in $Drives) {
    Write-Host "`n--- Drive $drive ---" -ForegroundColor Cyan
    $proc = Start-ComfyUI -Drive $drive
    if (-not $proc) { continue }

    # Step 1: Wan 2.2 (VRAM を Wan モデルで埋める)
    Write-Host "  [Step1] Wan 2.2 t2v (warm-up VRAM)..." -ForegroundColor DarkCyan
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
        --workflow $wfWan `
        --drive $drive --runs 1 `
        --host "http://127.0.0.1:${Port}" `
        --output-dir "$benchDir\results\comfyui-swap-bench-R4" `
        --timeout 300

    # Step 2: LTX 2.3 t2v (Wan → LTX モデルスワップ、コールドスタート)
    Write-Host "  [Step2] LTX 2.3 t2v (cold: model swap from Wan)..." -ForegroundColor Cyan
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
        --workflow $wfT2v `
        --drive $drive --runs 1 `
        --host "http://127.0.0.1:${Port}" `
        --output-dir "$benchDir\results\comfyui-swap-bench-R4" `
        --timeout 180

    # Step 3: LTX 2.3 ia2v (LTX モデルは VRAM に残存、ウォーム)
    Write-Host "  [Step3] LTX 2.3 ia2v (warm: LTX already loaded)..." -ForegroundColor Green
    & py "$benchDir\comfyui-ltx-bench\bench_comfyui.py" `
        --workflow $wfIa2v `
        --drive $drive --runs 1 `
        --host "http://127.0.0.1:${Port}" `
        --output-dir "$benchDir\results\comfyui-swap-bench-R4" `
        --timeout 180

    Stop-ComfyUI -Proc $proc
}

Push-Results "Ex6" "R4 Ex6: Model swap bench (Wan2.2->LTX2.3 t2v->ia2v) complete"
Write-Host "`n=== Ex6 Complete ===" -ForegroundColor Green
