#!/usr/bin/env python3
"""
ComfyUI z-image-turbo 画像生成ベンチマーク

ComfyUI HTTP API 経由で z-image-turbo による画像生成時間を計測。
モデルロード（ストレージ依存）と推論（GPU 依存）を分離して定量化。

Usage:
    python bench_imggen.py --drive D --runs 3
    python bench_imggen.py --all-drives
"""

import argparse
import json
import os
import subprocess
import time
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

COMFYUI_HOST = "http://127.0.0.1:8188"
DRIVES = ["D", "E", "F", "G"]
DEFAULT_RUNS = 3

# z-image-turbo ワークフロー（高速画像生成）
# CheckpointLoaderSimple → CLIP → KSampler (少ステップ) → VAEDecode → SaveImage
WORKFLOW_IMGGEN = {
    "1": {
        "class_type": "CheckpointLoaderSimple",
        "inputs": {
            "ckpt_name": "z-image-turbo.safetensors"
        },
    },
    "2": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "A professional photograph of a mountain landscape at sunset, golden hour lighting, dramatic clouds, 8k ultra detailed",
            "clip": ["1", 1],
        },
    },
    "3": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "blurry, low quality, distorted, watermark, text",
            "clip": ["1", 1],
        },
    },
    "4": {
        "class_type": "EmptyLatentImage",
        "inputs": {
            "width": 1024,
            "height": 1024,
            "batch_size": 1,
        },
    },
    "5": {
        "class_type": "KSampler",
        "inputs": {
            "model": ["1", 0],
            "positive": ["2", 0],
            "negative": ["3", 0],
            "latent_image": ["4", 0],
            "seed": 42,
            "steps": 4,
            "cfg": 1.8,
            "sampler_name": "euler",
            "scheduler": "normal",
            "denoise": 1.0,
        },
    },
    "6": {
        "class_type": "VAEDecode",
        "inputs": {
            "samples": ["5", 0],
            "vae": ["1", 2],
        },
    },
    "7": {
        "class_type": "SaveImage",
        "inputs": {
            "images": ["6", 0],
            "filename_prefix": "bench_imggen",
        },
    },
}

# バッチテスト用プロンプト
TEST_PROMPTS = [
    {
        "id": "landscape",
        "prompt": "A professional photograph of a mountain landscape at sunset, golden hour lighting, dramatic clouds, 8k ultra detailed",
    },
    {
        "id": "portrait",
        "prompt": "A portrait of a young woman in a cafe, natural lighting, bokeh background, professional photography",
    },
    {
        "id": "product",
        "prompt": "A Samsung NVMe SSD product shot on white background, studio lighting, commercial photography, ultra detailed",
    },
    {
        "id": "abstract",
        "prompt": "Abstract digital art, flowing neon colors, cyber aesthetic, high resolution, 4k",
    },
]


def get_nvidia_smi() -> dict:
    """nvidia-smi から GPU 情報を取得"""
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=gpu_name,memory.used,memory.total,temperature.gpu,power.draw",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            return {
                "gpu_name": parts[0],
                "vram_used_mb": int(parts[1]),
                "vram_total_mb": int(parts[2]),
                "temp_c": int(parts[3]),
                "power_w": float(parts[4]),
            }
    except Exception:
        pass
    return {}


def get_comfyui_system_stats() -> dict:
    """ComfyUI /system_stats からシステム情報を取得"""
    try:
        req = urllib.request.Request(f"{COMFYUI_HOST}/system_stats")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return {}


def free_comfyui_memory():
    """ComfyUI の VRAM キャッシュを解放"""
    try:
        req = urllib.request.Request(
            f"{COMFYUI_HOST}/free",
            data=json.dumps({"unload_models": True, "free_memory": True}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass
    time.sleep(2)


def queue_prompt(workflow: dict) -> str:
    """ワークフローをキューに投入し prompt_id を返す"""
    payload = json.dumps({"prompt": workflow}).encode()
    req = urllib.request.Request(
        f"{COMFYUI_HOST}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.loads(resp.read().decode())
    return result["prompt_id"]


def wait_for_completion(prompt_id: str, timeout: int = 300) -> dict:
    """prompt_id の完了を待ち、history を返す"""
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(f"{COMFYUI_HOST}/history/{prompt_id}")
            with urllib.request.urlopen(req, timeout=10) as resp:
                history = json.loads(resp.read().decode())
            if prompt_id in history:
                status = history[prompt_id].get("status", {})
                if status.get("completed", False) or history[prompt_id].get("outputs"):
                    return history[prompt_id]
                if status.get("status_str") == "error":
                    return {"error": True, **history[prompt_id]}
        except Exception:
            pass
        time.sleep(0.5)
    return {"error": True, "timeout": True}


def make_workflow(prompt_text: str) -> dict:
    """プロンプトを差し替えたワークフローを生成"""
    wf = json.loads(json.dumps(WORKFLOW_IMGGEN))  # deep copy
    wf["2"]["inputs"]["text"] = prompt_text
    return wf


def run_single(prompt_id_label: str, prompt_text: str, is_cold: bool) -> dict:
    """1枚分の画像生成を計測"""
    if is_cold:
        free_comfyui_memory()

    gpu_before = get_nvidia_smi()
    wf = make_workflow(prompt_text)

    start = time.time()
    try:
        pid = queue_prompt(wf)
        result = wait_for_completion(pid, timeout=300)
        elapsed = round(time.time() - start, 3)
        success = "error" not in result
    except Exception as e:
        elapsed = round(time.time() - start, 3)
        success = False
        print(f"    ERROR: {e}")

    gpu_after = get_nvidia_smi()

    return {
        "prompt_id": prompt_id_label,
        "cold_start": is_cold,
        "elapsed_s": elapsed,
        "success": success,
        "gpu_before": gpu_before,
        "gpu_after": gpu_after,
    }


def run_benchmark(drive: str, run_number: int, runs: int) -> dict:
    """1回分のベンチマーク（コールドスタート + バッチ）を実行"""
    print(f"\n[{drive}] Run {run_number}/{runs}")
    results = []

    # コールドスタート（1枚目 = モデルロード込み）
    first = TEST_PROMPTS[0]
    print(f"  [cold] {first['id']}...", end=" ")
    r = run_single(first["id"], first["prompt"], is_cold=True)
    print(f"{r['elapsed_s']}s ({'OK' if r['success'] else 'FAIL'})")
    cold_start_time = r["elapsed_s"] if r["success"] else None
    results.append(r)

    # ウォームスタート（残りのプロンプト）
    for tp in TEST_PROMPTS[1:]:
        print(f"  [warm] {tp['id']}...", end=" ")
        r = run_single(tp["id"], tp["prompt"], is_cold=False)
        print(f"{r['elapsed_s']}s ({'OK' if r['success'] else 'FAIL'})")
        results.append(r)

    # ウォーム時間の合計
    warm_results = [r for r in results[1:] if r["success"]]
    warm_total = round(sum(r["elapsed_s"] for r in warm_results), 3) if warm_results else None

    return {
        "experiment": "comfyui-imggen-bench",
        "test": "z_image_turbo",
        "drive": drive,
        "run": run_number,
        "cold_start_s": cold_start_time,
        "warm_batch_s": warm_total,
        "warm_count": len(warm_results),
        "image_results": results,
        "timestamp": datetime.now().isoformat(),
    }


def main():
    parser = argparse.ArgumentParser(description="ComfyUI z-image-turbo Benchmark")
    parser.add_argument("--drive", choices=DRIVES, help="テスト対象ドライブ")
    parser.add_argument("--all-drives", action="store_true", help="全ドライブで実行")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS, help="計測回数")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results", "comfyui-imggen-bench"),
    )
    parser.add_argument("--host", type=str, default=COMFYUI_HOST, help="ComfyUI ホスト")
    args = parser.parse_args()

    global COMFYUI_HOST
    COMFYUI_HOST = args.host

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    drives = DRIVES if args.all_drives else ([args.drive] if args.drive else DRIVES)

    print("\n=== comfyui-imggen-bench: z-image-turbo Benchmark ===")
    print(f"Drives: {drives} | Runs: {args.runs}")

    # ComfyUI 環境情報
    sys_stats = get_comfyui_system_stats()
    if sys_stats:
        info_file = output_dir / "comfyui_info.json"
        with open(info_file, "w", encoding="utf-8") as f:
            json.dump(sys_stats, f, indent=2, ensure_ascii=False)
        print(f"ComfyUI info saved: {info_file}")

    for drive in drives:
        print(f"\n{'='*40}")
        print(f"  Drive {drive}")
        print(f"{'='*40}")

        all_runs = []
        for i in range(1, args.runs + 1):
            result = run_benchmark(drive, i, args.runs)
            all_runs.append(result)

        # コールドスタート中央値
        cold_times = sorted([r["cold_start_s"] for r in all_runs if r["cold_start_s"] is not None])
        if cold_times:
            mid = len(cold_times) // 2
            cold_median = (cold_times[mid - 1] + cold_times[mid]) / 2 if len(cold_times) % 2 == 0 else cold_times[mid]
        else:
            cold_median = None

        # ウォームバッチ中央値
        warm_times = sorted([r["warm_batch_s"] for r in all_runs if r["warm_batch_s"] is not None])
        if warm_times:
            mid = len(warm_times) // 2
            warm_median = (warm_times[mid - 1] + warm_times[mid]) / 2 if len(warm_times) % 2 == 0 else warm_times[mid]
        else:
            warm_median = None

        summary = {
            "experiment": "comfyui-imggen-bench",
            "test": "z_image_turbo",
            "drive": drive,
            "runs": args.runs,
            "cold_start_median_s": cold_median,
            "warm_batch_median_s": warm_median,
            "prompts": [{"id": p["id"], "prompt": p["prompt"]} for p in TEST_PROMPTS],
            "comfyui_info": sys_stats,
            "results": all_runs,
            "generated": datetime.now().isoformat(),
        }

        out_file = output_dir / f"imggen_{drive}.json"
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2, ensure_ascii=False)

        print(f"\n  Cold start median: {cold_median}s")
        print(f"  Warm batch median: {warm_median}s")
        print(f"  Results saved: {out_file}")

    print("\n=== comfyui-imggen-bench: Complete! ===\n")


if __name__ == "__main__":
    main()
