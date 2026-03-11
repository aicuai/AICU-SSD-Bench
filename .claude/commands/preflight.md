# R3 ベンチマーク実行前チェック (Preflight)

全実験 (Ex0-Ex10) の実行前に、環境の準備状況を確認するスキル。

## 実行内容

以下を順番にチェックし、結果をテーブルで報告してください。

### 1. プロセスチェック
- `tasklist` で python / ollama / comfyui 関連プロセスを確認
- 残っていたら `taskkill //F` で確実に終了させる
- ポート 8188, 11434-11438 が使われていないことを `netstat` で確認

### 2. 各ドライブのモデル配置 (D, E, F, G)
- `{drive}:\ollama\models\` に blobs/manifests が存在するか
- `{drive}:\ComfyUI\main.py` が存在するか
- `{drive}:\ComfyUI\models\checkpoints\` にある .safetensors を列挙

### 3. スクリプト・ワークフロー確認
- `disk-speed-bench/bench_diskspeed.ps1` (Ex0)
- `scripts/download_models.ps1` (Ex1)
- `vibe-local-bench/bench_load.ps1`, `bench_codegen.ps1` (Ex2)
- `comfyui-imggen-bench/bench_imggen.py` (Ex3/Ex4)
- `comfyui-ltx-bench/bench_comfyui.py` (Ex5/Ex6)
- `workflows/sdxl.json` (Ex3)
- `workflows/aicuty_sdxl.json` (Ex4)
- `workflows/wan2_2_14B_t2v_api.json` (Ex5)
- `workflows/ltx2_3_t2v.json` or `ltx_2b_t2v_bench.json` (Ex6)
- `qwen3tts-bench/bench_tts.py` (Ex8)
- `llm-jp-moshi-bench/bench_moshi.py` (Ex9)
- `scripts/run_R3.ps1` (オーケストレーター)

### 4. GPU / システム確認
- `nvidia-smi` で GPU 名、VRAM 合計/使用量、温度、ドライババージョンを表示
- VRAM 使用量が 1GB 以上ならモデルが残っている可能性を警告

### 5. ディスク空き容量
- D, E, F, G の空き容量を確認
- R3 結果出力先 `results/*-R3/` のディレクトリが既にあれば前回結果の存在を警告

## 出力フォーマット

全チェック結果をまとめたテーブルを表示し、最後に「R3 開始可能」または「要対応項目あり」を判定。
