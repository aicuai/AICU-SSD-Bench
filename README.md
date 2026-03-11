# AICU-bench

**AI ワークロードにおけるストレージ速度影響の定量評価**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> Impress AKIBA PC Hotline! 取材協力ベンチマーク
> Samsung 9100 PRO (Gen5 NVMe) × AI ワークロード
> LP: [bench.aicu.jp](https://bench.aicu.jp)

---

## Claude Code で効率的にセットアップ

**[Claude Code](https://j.aicu.ai/_Claude)** を使って環境構築からベンチマーク実行、結果分析まで AI が支援します。

```powershell
claude  # CLAUDE.md を自動読み込み
```

---

## 概要

ストレージ速度（PCIe Gen5 NVMe / SATA SSD / HDD）が AI ワークロードに与える影響を **再現可能なオープンソーススクリプト** で計測・公開します。

## 実験構成 (Ex0–Ex10)

| Ex | 実験名 | ツール | 計測対象 |
|----|--------|--------|---------|
| 0 | disk-speed-bench | PowerShell FileStream | シーケンシャル R/W スペックチェック |
| 1 | download-bench | HuggingFace / Ollama | ダウンロード速度 (ネットワーク+ストレージ) |
| 2 | vibe-local-bench | Ollama qwen3:8b/1.7b | LLM モデルロード & コード生成 |
| 3 | comfyui-imggen-bench (SDXL) | ComfyUI + Animagine XL 4.0 | 画像生成コールドスタート |
| 4 | comfyui-imggen-bench (AiCuty) | ComfyUI + AiCuty WF | 複数モデル比較 (SDXL/WAI/AnimagineXL4/Mellow Pencil) |
| 5 | comfyui-video-bench (Wan 2.2) | ComfyUI + Wan 2.2 14B | 動画生成 t2v / i2v |
| 6 | comfyui-video-bench (LTX 2.3) | ComfyUI + LTX 2.3 22B | 動画生成 t2v / i2v |
| 7 | comfyui-pipeline-bench | ComfyUI 総合 | Mellow Pencil → LTX i2v 融合パイプライン |
| 8 | qwen3tts-bench | Qwen3-TTS | 長文音声合成 |
| 9 | llm-jp-moshi-bench | llm-jp-moshi | 高速音声応答 |
| 10 | total-summary | 集計 | 全実験の所要時間・ストレージ消費 |

## テスト環境

| 項目 | 値 |
|------|-----|
| CPU | AMD Ryzen Threadripper PRO 7975WX (32コア/64スレッド) |
| RAM | DDR5-4800 192GB (32GB×6) |
| GPU | NVIDIA RTX PRO 6000 Blackwell MAX-Q (VRAM 96GB GDDR7) |
| OS | Windows 11 PRO |

## テスト対象ストレージ

| ドライブ | デバイス | インターフェース | 代表速度 |
|---------|---------|----------------|---------|
| D: | Samsung 9100 PRO 8TB | PCIe Gen5 NVMe | ~14,800 MB/s |
| E: | Samsung 870 QVO 8TB | SATA SSD | ~560 MB/s |
| F: | HDD 8TB | SATA HDD | ~180 MB/s |
| G: | Samsung 9100 PRO 8TB (ICY DOCK) | PCIe Gen5 NVMe リムーバブル | ~14,800 MB/s |

## クイックスタート

```powershell
git clone https://github.com/aicuai/aicu-bench
cd aicu-bench

# R3 全実験を一気通貫で実行
.\scripts\R3\R3_run_all.ps1

# Ex3 から再開
.\scripts\R3\R3_run_all.ps1 -StartFrom 3

# 個別の Ex を実行
.\scripts\R3\R3_Ex03_comfyui_sdxl.ps1
```

### 前提条件
- Windows 11 + PowerShell 5.1+
- Python 3.10+
- [Ollama](https://ollama.com/) インストール済み
- NVIDIA ドライバ + nvidia-smi
- ComfyUI を各ドライブにインストール済み

## スクリプト構成

```
scripts/R3/
├── _common.ps1               # 共通関数 (ComfyUI/Ollama管理, Push, Cleanup)
├── R3_run_all.ps1             # マスター: 全Ex一括実行 (非対話)
├── R3_Ex00_disk_speed.ps1     # Ex0:  ディスク速度スペックチェック
├── R3_Ex01_download.ps1       # Ex1:  ダウンロード速度計測
├── R3_Ex02_ollama_llm.ps1     # Ex2:  Ollama LLM コールドスタート+コード生成
├── R3_Ex03_comfyui_sdxl.ps1   # Ex3:  ComfyUI SDXL 画像生成
├── R3_Ex04_comfyui_aicuty.ps1 # Ex4:  AiCuty 複数モデル比較
├── R3_Ex05_comfyui_wan22.ps1  # Ex5:  Wan 2.2 動画生成
├── R3_Ex06_comfyui_ltx23.ps1  # Ex6:  LTX 2.3 動画生成
├── R3_Ex07_comfyui_pipeline.ps1 # Ex7: 総合パイプライン
├── R3_Ex08_qwen3tts.ps1       # Ex8:  Qwen3-TTS 長文TTS
├── R3_Ex09_moshi.ps1          # Ex9:  llm-jp-moshi 音声応答
└── R3_Ex10_summary.ps1        # Ex10: 総合レポート
```

## 結果データ

計測結果は `results/*-R3/` に JSON 出力。`python scripts/update_site.py` で `site/data.json` に変換し、LP に自動反映。

## LP (bench.aicu.jp)

`site/` の静的 HTML/CSS。`main` に push → Cloudflare Pages に自動デプロイ。

## ライセンス

MIT — スクリプト・結果データともにオープン公開。引用時は本リポジトリへのリンクをお願いします。

## 関連リンク

- [Impress AKIBA PC Hotline!](https://akiba-pc.watch.impress.co.jp/)
- [AICU Inc.](https://aicu.ai)
- [Samsung 9100 PRO](https://semiconductor.samsung.com/jp/consumer-storage/internal-ssd/9100-pro/)
- [vibe-local (ochyai)](https://github.com/ochyai/vibe-local)
