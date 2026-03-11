# AGENTS.md — AICU-bench AI Agent Instructions

> **目的**: ストレージ速度（NVMe Gen5 / SATA SSD / HDD）が AI ワークロードに与える影響を定量計測し、オープンに公開する。

---

## 実験環境

| 項目 | 値 |
|------|-----|
| CPU | AMD Ryzen Threadripper PRO 7975WX (32コア/64スレッド) |
| RAM | DDR5-4800 192GB (32GB×6) |
| GPU | NVIDIA RTX PRO 6000 Blackwell MAX-Q (VRAM 96GB GDDR7) |
| OS | Windows 11 PRO |

### ストレージ構成

| ドライブ | デバイス | インターフェース |
|---------|---------|----------------|
| D: | Samsung 9100 PRO 8TB | PCIe Gen5 NVMe |
| E: | Samsung 870 QVO 8TB | SATA SSD |
| F: | HDD 8TB | SATA HDD |
| G: | Samsung 9100 PRO 8TB (ICY DOCK) | PCIe Gen5 NVMe リムーバブル |

---

## 実験インデックス (Ex0–Ex10)

| Ex | スクリプト | 内容 |
|----|-----------|------|
| 0 | `R3_Ex00_disk_speed.ps1` | ダミーファイル シーケンシャル R/W スペックチェック |
| 1 | `R3_Ex01_download.ps1` | ダウンロード速度計測 |
| 2 | `R3_Ex02_ollama_llm.ps1` | Ollama qwen3 コールドスタート & コード生成 |
| 3 | `R3_Ex03_comfyui_sdxl.ps1` | ComfyUI SDXL 画像生成 |
| 4 | `R3_Ex04_comfyui_aicuty.ps1` | AiCuty 複数モデル比較 (SDXL/WAI/AnimagineXL4/Mellow Pencil) |
| 5 | `R3_Ex05_comfyui_wan22.ps1` | Wan 2.2 14B 動画生成 t2v / i2v |
| 6 | `R3_Ex06_comfyui_ltx23.ps1` | LTX 2.3 22B 動画生成 t2v / i2v |
| 7 | `R3_Ex07_comfyui_pipeline.ps1` | 総合: Mellow Pencil → LTX i2v 融合 |
| 8 | `R3_Ex08_qwen3tts.ps1` | Qwen3-TTS 長文音声合成 |
| 9 | `R3_Ex09_moshi.ps1` | llm-jp-moshi 高速音声応答 |
| 10 | `R3_Ex10_summary.ps1` | 全実験の所要時間・ストレージ消費レポート |

---

## エージェントへの指示

1. **結果は `results/*-R3/` に JSON 保存**
2. **各ドライブ×3回以上、中央値を採用**
3. **モデルキャッシュはベンチ前にクリア** (`free_comfyui_memory`, Ollama 再起動)
4. **GPU 情報 (VRAM/温度/電力) を before/after で記録**
5. **スクリプトはべき等** — 再実行しても安全
6. **各 Ex 完了後に自動 `git push`**
7. **プロセス管理を厳密に** — Ex 間で Ollama/ComfyUI/Python を確実に終了

### プロセス管理ルール

```
Ex 開始前: Ensure-Clean (全プロセス終了 + ポート確認)
ComfyUI:   ドライブごとに Start-ComfyUI → ベンチ → Stop-ComfyUI
Ollama:    ドライブごとに Stop-AllOllama → 環境変数設定 → ベンチ → Stop-AllOllama
Ex 完了後: Push-Results → 次の Ex へ
```

---

## ワークフロー構成

| ファイル | 用途 | モデルサイズ |
|---------|------|------------|
| `sdxl.json` | SDXL 基本画像生成 | ~7GB |
| `aicuty_sdxl.json` | AiCuty SDXL + 2LoRA + Upscaler | ~9GB |
| `ltx_2b_t2v_bench.json` | LTX-Video 2B t2v | ~15GB |
| `ltx2_3_t2v.json` | LTX 2.3 22B t2v | ~37GB |
| `wan2_2_14B_t2v_api.json` | Wan 2.2 14B t2v | ~34GB |

---

## 結果 JSON 共通スキーマ

```json
{
  "experiment": "実験名",
  "drive": "D",
  "runs": 3,
  "median_s": 12.345,
  "results": [
    {
      "run": 1,
      "success": true,
      "gpu_before": { "vram_used_mb": 1024, "temp_c": 42, "power_w": 85.5 },
      "gpu_after": { "..." : "..." },
      "timestamp": "2026-03-11T18:00:00+09:00"
    }
  ],
  "generated": "2026-03-11T18:30:00+09:00"
}
```

---

## Claude Code スラッシュコマンド

| コマンド | 用途 |
|---------|------|
| `/preflight` | R3 実行前チェック (プロセス/モデル/スクリプト/GPU/ディスク) |
| `/cleanup` | 実行後プロセス全終了・ポート確認 |

---

## ライセンス

MIT License
