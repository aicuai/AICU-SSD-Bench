---
name: run-experiment
description: "AICU-SSD-Bench の個別実験を実行する。引数で実験番号(Ex0-Ex10)とドライブ(D/E/F/G)を指定。環境チェック→実行→結果記録→クリーンアップまで自動化。"
---

# 実験実行スキル

指定された実験を単体で実行し、結果を記録する。

## 引数

```
/run-experiment <Ex番号> [ドライブ] [オプション]
例: /run-experiment Ex6 D
例: /run-experiment Ex3 all --runs 3
```

- `Ex番号`: Ex0-Ex10 (必須)
- `ドライブ`: D / E / F / G / all (デフォルト: all)
- `--runs N`: 計測回数 (デフォルト: 3)

## 実行手順

### 1. プリフライトチェック (自動)
- 対象実験に必要なプロセス/モデル/スクリプトの存在確認
- GPU VRAM 状態確認 (1GB 以上使用中なら警告)
- 対象ドライブの空き容量チェック

### 2. 実験マッピング

| Ex | スクリプト | 必要なもの |
|----|-----------|-----------|
| 0 | `disk-speed-bench/bench_diskspeed.ps1` | なし |
| 1 | `scripts/download_models.ps1` | ネットワーク |
| 2 | `vibe-local-bench/bench_load.ps1` + `bench_codegen.ps1` | Ollama |
| 3 | `comfyui-imggen-bench/bench_imggen.py` | ComfyUI + SDXL ckpt |
| 4 | `comfyui-imggen-bench/bench_imggen.py` (aicuty) | ComfyUI + AiCuty WF |
| 5 | `comfyui-ltx-bench/bench_comfyui.py` (wan2.2) | ComfyUI + Wan 2.2 |
| 6 | `comfyui-ltx-bench/bench_comfyui.py` (ltx2.3) | ComfyUI + LTX 2.3 |
| 7 | パイプラインベンチ | ComfyUI + Mellow Pencil + LTX |
| 8 | `qwen3tts-bench/bench_tts.py` | Python + HF モデル |
| 9 | `llm-jp-moshi-bench/bench_moshi.py` | Python + HF モデル |
| 10 | `scripts/R3/R3_Ex10_summary.ps1` | 既存結果 JSON |

### 3. 実行
- 対象ドライブごとにループ
- ComfyUI/Ollama 必要な場合は起動→ベンチ→停止
- GPU 情報を before/after で記録
- 結果を `results/` に JSON 出力

### 4. クリーンアップ (自動)
- ComfyUI / Ollama / Python プロセスを確実に終了
- ポート 8188, 11434-11438 の解放確認
- GPU VRAM 解放確認

### 5. 結果サマリー
- 全ドライブの中央値をテーブルで表示
- 異常値があれば警告
- `git add results/` で結果をステージング（コミットはしない）

## 注意事項
- Windows 11 + PowerShell 環境を前提
- 実験間でキャッシュをクリアするため、ComfyUI は毎回再起動
- `nvidia-smi` が使える状態であること
