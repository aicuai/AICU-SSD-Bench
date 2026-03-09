# ai-storage-bench

**AI ワークロードにおけるストレージ速度影響の定量評価**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> Impress AKIBA PC Hotline! 取材協力ベンチマーク
> Samsung 9100 PRO (Gen5 NVMe) × AI ワークロード
> LP: [bench.aicu.jp](https://bench.aicu.jp)

---

## Claude Code で効率的にセットアップ

トラブルシューティングや初期の実験環境のセットアップを高速に進めるため、**[Claude Code](https://j.aicu.ai/_Claude)** を使って行います。無料で利用できますので、準備いただけますと幸いです。

本リポジトリの `CLAUDE.md` を読み込ませるだけで、環境構築からベンチマーク実行、結果分析まで AI が支援します。

```powershell
# Claude Code を起動してリポジトリを開く
claude  # CLAUDE.md を自動読み込み
```

---

## 概要

ストレージ速度（PCIe Gen5 NVMe / SATA SSD / HDD）が
AI ワークロードのパフォーマンスにどう影響するかを
**再現可能なオープンソーススクリプト**で計測・公開します。

## 実験構成

| # | 実験 | ツール | 計測対象 | 仮説 |
|---|------|--------|---------|------|
| 1 | [vibe-local-bench](./vibe-local-bench/) | Ollama + qwen3:8b | モデルロード時間・コード生成時間 | Gen5: 3-5s / HDD: 60-120s |
| 2 | [comfyui-imggen-bench](./comfyui-imggen-bench/) | ComfyUI + z-image-turbo | 画像生成（コールド/ウォーム） | コールドスタートでストレージ差大 |
| 3 | [comfyui-ltx-bench](./comfyui-ltx-bench/) | ComfyUI + LTX-Video 2.3 | 動画生成トータル時間 | 8-12GB モデルロードで差大 |
| 4 | [qwen3tts-bench](./qwen3tts-bench/) | Qwen3-TTS | 初動時間・MP3バッチ生成速度 | 初動にストレージ速度直結 |

## テスト環境

| 項目 | 値 |
|------|-----|
| CPU | AMD Ryzen Threadripper PRO 7975WX (32コア) |
| RAM | DDR5-4800 192GB (32GB×6) |
| GPU | NVIDIA RTX PRO 6000 Blackwell MAX-Q 96GB |
| OS | Windows 11 PRO |

## テスト対象ストレージ

| ドライブ | 種別 | 代表速度 |
|---------|------|---------|
| D: Samsung 9100 PRO 8TB | PCIe Gen5 NVMe | ~14,500 MB/s |
| E: Samsung 870 QVO 8TB | SATA SSD | ~560 MB/s |
| F: HDD 8TB | SATA HDD | ~180 MB/s |
| G: 9100 PRO 8TB (ICY DOCK) | PCIe Gen5 NVMe リムーバブル | ~14,500 MB/s |

## インストール

### 前提条件
- Windows 11 + PowerShell 5.1 以上
- Python 3.10+ （comfyui-ltx-bench, qwen3tts-bench 用）
- [Ollama](https://ollama.com/) インストール済み
- NVIDIA ドライバ + nvidia-smi パスが通っていること

### セットアップ
```powershell
git clone https://github.com/aicuai/aicu-bench
cd aicu-bench

# Ollama にモデルを準備（各ドライブに配置）
$env:OLLAMA_MODELS = "D:\ollama\models"
ollama pull qwen3:8b

# ComfyUI は別途インストール・起動しておく
# Qwen3-TTS モデルも Ollama で準備
```

## 実験の実行

### 全実験一括（ランスルーテスト）
```powershell
.\scripts\run_all_benchmarks.ps1 -Runs 3
```

### 個別実験
```powershell
# Experiment 1: vibe-local (Ollama)
.\vibe-local-bench\run_all.ps1 -Runs 3

# Experiment 2: 画像生成 (ComfyUI z-image-turbo)
python .\comfyui-imggen-bench\bench_imggen.py --all-drives --runs 3

# Experiment 3: 動画生成 (ComfyUI LTX-Video 2.3)
python .\comfyui-ltx-bench\bench_comfyui.py --all-drives --runs 3

# Experiment 4: 音声合成 (Qwen3-TTS)
python .\qwen3tts-bench\bench_tts.py --all-drives --runs 3
```

### システム情報収集
```powershell
.\scripts\collect_sysinfo.ps1
```

## 結果データ

計測結果は `results/` ディレクトリに JSON で出力されます。

```
results/
├── sysinfo.json              # システム情報 (nvidia-smi 含む)
├── nvidia_smi_full.txt        # nvidia-smi フル出力
├── vibe-local-bench/
│   ├── load_D.json            # モデルロード結果
│   └── codegen_D.json         # コード生成結果
├── comfyui-imggen-bench/
│   ├── comfyui_info.json      # ComfyUI バージョン情報
│   └── imggen_D.json           # 画像生成結果
├── comfyui-ltx-bench/
│   ├── comfyui_info.json      # ComfyUI バージョン情報
│   └── comfyui_D.json         # 動画生成結果
└── qwen3tts-bench/
    └── tts_D.json             # TTS 結果
```

結果 JSON には nvidia-smi の GPU 情報（VRAM使用量・温度・消費電力）が各計測の before/after で記録されます。

## LP (bench.aicu.jp)

`site/` ディレクトリに静的 HTML/CSS の LP を配置。`main` ブランチへの push で GitHub Actions → Cloudflare Pages に自動デプロイ。

## ライセンス

MIT — スクリプト・結果データともにオープン公開。
引用時は本リポジトリへのリンクをお願いします。

## 関連リンク

- [Impress AKIBA PC Hotline!](https://akiba-pc.watch.impress.co.jp/)
- [AICU Inc.](https://aicu.ai)
- [vibe-local (ochyai)](https://github.com/ochyai/vibe-local)
- [Samsung 9100 PRO](https://www.samsung.com/semiconductor/minisite/ssd/product/consumer/9100pro/)
- [ネットワーク不要・サブスク不要！ 落合陽一氏の「vibe-local」でオフラインAIコーディングを体験してみた](https://forest.watch.impress.co.jp/docs/serial/aistream/2090895.html)
