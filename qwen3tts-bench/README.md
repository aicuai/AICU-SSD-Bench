# Experiment 3: Qwen3-TTS 音声合成ベンチマーク

## 概要

Qwen3-TTS（`qwen3tts` via Ollama または直接推論）を使って以下を計測：

1. **初動時間（Time-to-First-Audio）** — モデルロードから最初の音声ファイル生成まで
2. **バッチ処理速度** — 複数テキストの MP3 生成スループット（文字数別）

## 仮説

| 計測項目 | ストレージの影響 | 予想 |
|---------|--------------|------|
| 初動（モデルロード） | **大きい** | Gen5: ~5秒 / HDD: ~60秒 |
| 推論中（音声生成） | 小さい | GPU/CPU律速 |
| MP3保存 | やや影響 | 短いファイルなので誤差範囲 |

## テストテキスト定義

```python
TEST_TEXTS = [
    # S: 短文（〜50文字）
    {"id": "S1", "text": "こんにちは。今日はAIストレージのベンチマークを行います。", "chars": 25},
    {"id": "S2", "text": "Samsung 9100 PRO は Gen5 NVMe SSD の最速クラスです。", "chars": 28},
    
    # M: 中文（50〜200文字）
    {"id": "M1", "text": "人工知能の分野では、大規模言語モデルの推論速度だけでなく、モデルのロード時間もワークフロー全体のパフォーマンスに影響します。特にストレージの速度は、モデルファイルを読み込む際のボトルネックになり得ます。", "chars": 100},
    
    # L: 長文（200文字以上）
    {"id": "L1", "text": "AIクリエイターの皆さん、ストレージ速度について考えたことはありますか？画像生成AIや動画生成AIを使う際、モデルファイルのサイズは数GBから数十GBに及びます。このモデルを高速なNVMe SSDに配置するか、それとも従来のHDDに置くかによって、作業開始までの待ち時間が大きく変わります。Gen5対応のSSDを使えば、かつて1分以上かかっていたモデルロードが数秒で完了します。これはクリエイターの集中力と生産性に直結する問題です。", "chars": 200},
]
```

## ベンチマークスクリプト

### `bench_tts.py`

```python
#!/usr/bin/env python3
"""
Qwen3-TTS Storage Benchmark
使用方法: python bench_tts.py --drive D --runs 3

前提: Ollama に qwen3tts モデルがインストール済み
  ollama pull qwen3tts (または該当モデル名)
  
または: pip install transformers torch torchaudio soundfile
"""

import argparse
import json
import time
import subprocess
import os
import sys
from pathlib import Path
from datetime import datetime

# テストテキスト定義
TEST_TEXTS = [
    {
        "id": "S1",
        "label": "短文_挨拶",
        "text": "こんにちは。今日はAIストレージのベンチマークを行います。",
        "expected_chars": 25
    },
    {
        "id": "S2", 
        "label": "短文_技術",
        "text": "Samsung 9100 PRO は Gen5 NVMe SSD の最速クラスです。",
        "expected_chars": 28
    },
    {
        "id": "M1",
        "label": "中文_説明",
        "text": "人工知能の分野では、大規模言語モデルの推論速度だけでなく、モデルのロード時間もワークフロー全体のパフォーマンスに影響します。特にストレージの速度は、モデルファイルを読み込む際のボトルネックになり得ます。",
        "expected_chars": 100
    },
    {
        "id": "L1",
        "label": "長文_解説",
        "text": "AIクリエイターの皆さん、ストレージ速度について考えたことはありますか？画像生成AIや動画生成AIを使う際、モデルファイルのサイズは数GBから数十GBに及びます。このモデルを高速なNVMe SSDに配置するか、それとも従来のHDDに置くかによって、作業開始までの待ち時間が大きく変わります。Gen5対応のSSDを使えば、かつて1分以上かかっていたモデルロードが数秒で完了します。これはクリエイターの集中力と生産性に直結する問題です。",
        "expected_chars": 200
    },
]


def clear_ollama_cache(drive: str):
    """Ollama のモデルキャッシュをクリアしてドライブを切り替える"""
    os.environ["OLLAMA_MODELS"] = f"{drive}:\\ollama_models"
    # サービス再起動
    subprocess.run(["sc", "stop", "Ollama"], capture_output=True)
    time.sleep(2)
    subprocess.run(["sc", "start", "Ollama"], capture_output=True)
    time.sleep(3)


def synthesize_via_ollama(text: str, output_path: Path) -> float:
    """Ollama API 経由で TTS を実行して MP3 を保存"""
    import urllib.request
    
    payload = json.dumps({
        "model": "qwen3tts",
        "input": text,
        "voice": "Chelsie",
        "response_format": "mp3"
    }).encode()
    
    t_start = time.time()
    req = urllib.request.Request(
        "http://localhost:11434/v1/audio/speech",
        data=payload,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as resp:
        audio_data = resp.read()
    t_end = time.time()
    
    output_path.write_bytes(audio_data)
    return round(t_end - t_start, 3)


def run_benchmark(drive: str, runs: int, output_dir: Path) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    audio_dir = output_dir / f"audio_{drive}"
    audio_dir.mkdir(exist_ok=True)
    
    print(f"\n{'='*50}")
    print(f" Qwen3-TTS Benchmark — Drive {drive}:")
    print(f"{'='*50}")
    
    all_results = []
    
    for run_idx in range(1, runs + 1):
        print(f"\n--- Run {run_idx}/{runs} ---")
        
        # キャッシュクリア（初回ロード計測のため）
        clear_ollama_cache(drive)
        
        run_results = {
            "drive": drive,
            "run": run_idx,
            "first_audio_sec": None,  # 初動時間
            "texts": [],
            "timestamp": datetime.now().isoformat()
        }
        
        for idx, item in enumerate(TEST_TEXTS):
            out_path = audio_dir / f"{item['id']}_run{run_idx}.mp3"
            
            print(f"  [{item['id']}] {item['label']} ({item['expected_chars']}字)...", end=" ")
            
            try:
                elapsed = synthesize_via_ollama(item["text"], out_path)
                file_size_kb = round(out_path.stat().st_size / 1024, 1) if out_path.exists() else 0
                
                # 初動時間は最初のテキストで計測
                if idx == 0:
                    run_results["first_audio_sec"] = elapsed
                
                text_result = {
                    "id": item["id"],
                    "label": item["label"],
                    "chars": item["expected_chars"],
                    "elapsed_sec": elapsed,
                    "file_size_kb": file_size_kb,
                    "success": out_path.exists()
                }
                run_results["texts"].append(text_result)
                print(f"✓ {elapsed}s ({file_size_kb}KB)")
                
            except Exception as e:
                print(f"✗ ERROR: {e}")
                run_results["texts"].append({
                    "id": item["id"],
                    "label": item["label"],
                    "chars": item["expected_chars"],
                    "elapsed_sec": None,
                    "success": False,
                    "error": str(e)
                })
            
            time.sleep(1)
        
        # バッチ合計時間
        total_time = sum(
            t["elapsed_sec"] for t in run_results["texts"] 
            if t["elapsed_sec"] is not None
        )
        run_results["batch_total_sec"] = round(total_time, 2)
        all_results.append(run_results)
        
        print(f"  → 初動: {run_results['first_audio_sec']}s | バッチ合計: {total_time:.2f}s")

    # 保存
    json_path = output_dir / f"tts_bench_{drive}.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    
    # サマリー表示
    first_times = [r["first_audio_sec"] for r in all_results if r["first_audio_sec"]]
    batch_times = [r["batch_total_sec"] for r in all_results]
    
    print(f"\n  === Summary Drive {drive}: ===")
    print(f"  初動（中央値）: {sorted(first_times)[len(first_times)//2]}s")
    print(f"  バッチ合計（中央値）: {sorted(batch_times)[len(batch_times)//2]}s")
    
    return all_results


def main():
    parser = argparse.ArgumentParser(description="Qwen3-TTS Storage Benchmark")
    parser.add_argument("--drive", default="D")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--all-drives", action="store_true")
    parser.add_argument("--output", default="results")
    args = parser.parse_args()
    
    output_dir = Path(args.output)
    
    if args.all_drives:
        summary = {}
        for drive in ["D", "E", "F", "G"]:
            results = run_benchmark(drive, args.runs, output_dir)
            first_times = [r["first_audio_sec"] for r in results if r["first_audio_sec"]]
            summary[drive] = {
                "first_audio_median_sec": sorted(first_times)[len(first_times)//2] if first_times else None
            }
        
        print("\n" + "="*50)
        print(" FINAL SUMMARY — 初動時間比較")
        print("="*50)
        for drive, s in summary.items():
            bar = "█" * int((s["first_audio_median_sec"] or 0))
            print(f"  {drive}: {s['first_audio_median_sec']:>8.2f}s  {bar}")
    else:
        run_benchmark(args.drive, args.runs, output_dir)


if __name__ == "__main__":
    main()
```

## 実行方法

```bash
# 単一ドライブ
python bench_tts.py --drive D --runs 3

# 全ドライブ比較
python bench_tts.py --all-drives --runs 3

# 出力されるファイル
# results/tts_bench_D.json
# results/audio_D/S1_run1.mp3 ... など
```

## 期待される出力（JSON）

```json
[
  {
    "drive": "D",
    "run": 1,
    "first_audio_sec": 4.2,
    "batch_total_sec": 18.5,
    "texts": [
      {"id": "S1", "chars": 25, "elapsed_sec": 4.2, "file_size_kb": 32.5, "success": true},
      {"id": "S2", "chars": 28, "elapsed_sec": 3.8, "file_size_kb": 28.1, "success": true},
      {"id": "M1", "chars": 100, "elapsed_sec": 5.1, "file_size_kb": 89.4, "success": true},
      {"id": "L1", "chars": 200, "elapsed_sec": 5.4, "file_size_kb": 156.2, "success": true}
    ],
    "timestamp": "2025-03-10T14:30:00"
  }
]
```
