# Experiment 2: ComfyUI LTX-Video 2.3 動画生成ベンチマーク

## 概要

ComfyUI の公式 LTX-Video 2.3 テンプレートを使用して、  
ストレージ速度が **モデルロード時間** と **生成スループット** に与える影響を計測します。

## 仮説

LTX-Video 2.3 のモデルサイズは約 **8〜12GB** と大きいため、  
ストレージ速度差がモデルロードに直結する。  
一方、生成中（推論中）はVRAMで完結するため、ストレージ速度の影響は小さい。

| フェーズ | ストレージの影響 | 予想 |
|---------|--------------|------|
| モデルロード | **大きい** | Gen5: ~5秒 / HDD: ~60秒以上 |
| 動画生成（推論） | ほぼなし | ストレージ依存しない |
| 出力保存 | やや影響 | 動画ファイルの書き込み速度 |

## セットアップ

```bash
# ComfyUI のモデルディレクトリを各ドライブに設定する場合
# ComfyUI の extra_model_paths.yaml を編集

# 例: D: ドライブ用
# checkpoints: D:\comfyui_models\checkpoints\
# video_models: D:\comfyui_models\video_models\
```

### LTX-Video 2.3 モデルの準備

```bash
# 必要なモデルファイル（各ドライブにコピー）
# - ltx-video-2b-v0.9.5.safetensors (~8GB)
# - t5xxl_fp16.safetensors (~9GB) または t5xxl_fp8_e4m3fn.safetensors (~5GB)
```

## ベンチマークスクリプト

### `bench_comfyui.py` — ComfyUI API 経由での自動ベンチ

```python
#!/usr/bin/env python3
"""
ComfyUI LTX-Video 2.3 Storage Benchmark
使用方法: python bench_comfyui.py --drive D --runs 3
"""

import argparse
import json
import time
import urllib.request
import urllib.parse
import uuid
import os
import sys
from pathlib import Path
from datetime import datetime

COMFYUI_URL = "http://127.0.0.1:8188"

# LTX-Video 2.3 公式テンプレートに準じたワークフロー（最小構成）
LTX_WORKFLOW = {
    "1": {
        "class_type": "LTXVLoader",
        "inputs": {
            "ckpt_name": "ltx-video-2b-v0.9.5.safetensors",
            "dtype": "bfloat16"
        }
    },
    "2": {
        "class_type": "CLIPLoader", 
        "inputs": {
            "clip_name": "t5xxl_fp8_e4m3fn.safetensors",
            "type": "ltxv"
        }
    },
    "3": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "A cat sitting on a chair, looking at the camera, cinematic",
            "clip": ["2", 0]
        }
    },
    "4": {
        "class_type": "CLIPTextEncode",
        "inputs": {
            "text": "blurry, low quality",
            "clip": ["2", 0]
        }
    },
    "5": {
        "class_type": "EmptyLTXVLatentVideo",
        "inputs": {
            "width": 512,
            "height": 288,
            "length": 25,
            "batch_size": 1
        }
    },
    "6": {
        "class_type": "LTXVScheduler",
        "inputs": {
            "steps": 25,
            "max_shift": 2.05,
            "base_shift": 0.95,
            "stretch": True,
            "terminal": 0.1
        }
    },
    "7": {
        "class_type": "KSamplerSelect",
        "inputs": {"sampler_name": "euler"}
    },
    "8": {
        "class_type": "SamplerCustomAdvanced",
        "inputs": {
            "noise": ["9", 0],
            "guider": ["10", 0],
            "sampler": ["7", 0],
            "sigmas": ["6", 0],
            "latent_image": ["5", 0]
        }
    },
    "9": {
        "class_type": "RandomNoise",
        "inputs": {"noise_seed": 42}
    },
    "10": {
        "class_type": "CFGGuider",
        "inputs": {
            "model": ["1", 0],
            "positive": ["3", 0],
            "negative": ["4", 0],
            "cfg": 3.0
        }
    },
    "11": {
        "class_type": "LTXVImgToVideo",
        "inputs": {
            "positive": ["3", 0],
            "negative": ["4", 0],
            "latent": ["8", 0],
            "vae": ["1", 2]
        }
    },
    "12": {
        "class_type": "VHS_VideoCombine",
        "inputs": {
            "images": ["11", 0],
            "frame_rate": 24,
            "loop_count": 0,
            "filename_prefix": "ltx_bench",
            "format": "video/h264-mp4",
            "pingpong": False,
            "save_output": True
        }
    }
}


def queue_prompt(workflow: dict) -> str:
    """ComfyUI にワークフローをキューイングして prompt_id を返す"""
    payload = json.dumps({"prompt": workflow, "client_id": str(uuid.uuid4())}).encode()
    req = urllib.request.Request(
        f"{COMFYUI_URL}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["prompt_id"]


def wait_for_completion(prompt_id: str, timeout: int = 600) -> dict:
    """生成完了を待機してヒストリーを返す"""
    start = time.time()
    while time.time() - start < timeout:
        with urllib.request.urlopen(f"{COMFYUI_URL}/history/{prompt_id}") as resp:
            history = json.loads(resp.read())
        if prompt_id in history:
            return history[prompt_id]
        time.sleep(2)
    raise TimeoutError(f"Prompt {prompt_id} timed out after {timeout}s")


def get_system_stats() -> dict:
    """ComfyUI のシステム統計を取得"""
    try:
        with urllib.request.urlopen(f"{COMFYUI_URL}/system_stats") as resp:
            return json.loads(resp.read())
    except Exception:
        return {}


def run_benchmark(drive: str, runs: int, output_dir: Path) -> list:
    results = []
    output_dir.mkdir(parents=True, exist_ok=True)
    
    print(f"\n{'='*50}")
    print(f" LTX-Video 2.3 Benchmark — Drive {drive}:")
    print(f"{'='*50}")

    for i in range(1, runs + 1):
        print(f"\n--- Run {i}/{runs} ---")
        
        # ComfyUI を再起動してモデルキャッシュをクリア
        # ※ 実際の運用では手動またはAPIで unload_models を呼ぶ
        print("  [INFO] Clearing model cache via ComfyUI API...")
        try:
            req = urllib.request.Request(
                f"{COMFYUI_URL}/free",
                data=json.dumps({"unload_models": True, "free_memory": True}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST"
            )
            urllib.request.urlopen(req)
            time.sleep(3)
        except Exception as e:
            print(f"  [WARN] Cache clear failed: {e}")

        stats_before = get_system_stats()
        
        # ワークフロー送信
        t_start = time.time()
        prompt_id = queue_prompt(LTX_WORKFLOW)
        print(f"  Queued: {prompt_id}")
        
        # 完了待機
        history = wait_for_completion(prompt_id)
        t_end = time.time()
        
        total_sec = round(t_end - t_start, 2)
        stats_after = get_system_stats()
        
        # VRAM使用量取得
        vram_used_gb = 0
        try:
            devices = stats_after.get("devices", [])
            if devices:
                vram_used_gb = round(devices[0].get("vram_used", 0) / 1024**3, 2)
        except Exception:
            pass

        result = {
            "drive": drive,
            "run": i,
            "total_sec": total_sec,
            "vram_used_gb": vram_used_gb,
            "success": "outputs" in history,
            "timestamp": datetime.now().isoformat()
        }
        
        results.append(result)
        print(f"  ✓ Total: {total_sec}s | VRAM: {vram_used_gb}GB")
        
        time.sleep(10)  # インターバル

    # 保存
    json_path = output_dir / f"ltx_bench_{drive}.json"
    csv_path = output_dir / f"ltx_bench_{drive}.csv"
    
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    
    # 簡易CSV
    with open(csv_path, "w", encoding="utf-8") as f:
        f.write("drive,run,total_sec,vram_used_gb,success,timestamp\n")
        for r in results:
            f.write(f"{r['drive']},{r['run']},{r['total_sec']},{r['vram_used_gb']},{r['success']},{r['timestamp']}\n")
    
    median = sorted(results, key=lambda x: x["total_sec"])[len(results)//2]["total_sec"]
    print(f"\n  Median total time: {median}s")
    print(f"  Results saved: {json_path}")
    
    return results


def main():
    parser = argparse.ArgumentParser(description="ComfyUI LTX-Video 2.3 Storage Benchmark")
    parser.add_argument("--drive", default="D", help="Drive letter (D/E/F/G)")
    parser.add_argument("--runs", type=int, default=3, help="Number of runs")
    parser.add_argument("--all-drives", action="store_true", help="Run all drives D/E/F/G")
    parser.add_argument("--output", default="results", help="Output directory")
    args = parser.parse_args()
    
    output_dir = Path(args.output)
    
    if args.all_drives:
        all_results = {}
        for drive in ["D", "E", "F", "G"]:
            all_results[drive] = run_benchmark(drive, args.runs, output_dir)
        
        # 比較サマリー
        print("\n" + "="*60)
        print(" SUMMARY — All Drives")
        print("="*60)
        print(f"{'Drive':<8} {'Median (s)':<12} {'Min (s)':<10} {'Max (s)'}")
        for drive, results in all_results.items():
            times = [r["total_sec"] for r in results]
            median = sorted(times)[len(times)//2]
            print(f"{drive:<8} {median:<12} {min(times):<10} {max(times)}")
    else:
        run_benchmark(args.drive, args.runs, output_dir)


if __name__ == "__main__":
    main()
```

## 実行方法

```bash
# 単一ドライブ
python bench_comfyui.py --drive D --runs 3

# 全ドライブ比較（自動）
python bench_comfyui.py --all-drives --runs 3

# 出力先指定
python bench_comfyui.py --all-drives --runs 3 --output ./results
```
