---
name: analyze
description: "ベンチマーク結果を分析し、ドライブ間比較・cold/warm分析・sec/GiB正規化などのレポートを生成する。引数で分析タイプを指定。"
---

# 結果分析スキル

ベンチマーク結果 JSON を読み込み、分析レポートを生成する。

## 引数

```
/analyze [タイプ] [オプション]
例: /analyze compare          # ドライブ間比較
例: /analyze cold-warm Ex6    # cold/warm 分析
例: /analyze sec-gib          # sec/GiB 正規化
例: /analyze all              # 全分析
```

## 分析タイプ

### `compare` — ドライブ間比較
- `results/` 配下の全 JSON を読み込み
- 各実験 × ドライブの中央値をマトリクス表示
- 最速/最遅をハイライト
- D: を基準とした倍率計算

### `cold-warm` — コールド/ウォーム分離分析
- cold start (Run 1) vs warm (Run 2-3) の差分を計算
- 差分 = 純粋なストレージ I/O 時間
- モデルサイズから実効リード速度を推定
- 出力例:
  ```
  Ex6 LTX 2.3 (45GB):
    D: cold=98.4s warm=95.3s → I/O=3.1s → ~13 GB/s
    F: cold=288.1s warm=103.4s → I/O=184.7s → ~246 MB/s
  ```

### `sec-gib` — sec/GiB 正規化メトリクス
- モデルロード時間をモデルサイズ (GiB) で割る
- 異なるサイズのモデル間でロード速度を公平に比較
- `scripts/analyze_sec_per_gb.py` を実行

### `thermal` — サーマル分析
- GPU 温度・電力の before/after を比較
- 長時間負荷によるスロットリングの有無を判定
- ドライブごとの温度推移パターン

### `icy-dock` — ICY DOCK (D vs G) 専用分析
- D: (直接接続) と G: (ICY DOCK リムーバブル) のみに絞った比較
- `docs/analysis-icy-dock-d-vs-g.md` を参照・更新

### `all` — 全分析実行
- 上記全てを順次実行し、統合レポートを生成

## 出力
- ターミナルにマークダウンテーブルで表示
- `--save` オプションで `docs/` にレポート保存
- `--update-lp` オプションで `site/data.json` を更新
