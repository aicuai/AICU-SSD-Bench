# ベンチマーク後クリーンアップ

ベンチマーク実行後に全プロセスを確実に終了させるスキル。

## 実行内容

### 1. プロセス終了 (順序重要)
以下の順で確認・終了:
1. `python` / `py` プロセス → ComfyUI やベンチスクリプトの残骸
2. `ollama.exe` → Ollama サーバー
3. `ollama app.exe` → Ollama GUI

各プロセスについて:
- `tasklist | grep -i` で存在確認
- 存在すれば `taskkill //F //IM` で終了
- 終了後に再確認

### 2. ポート確認
- `netstat -ano` で 8188 (ComfyUI), 11434-11438 (Ollama) が LISTEN していないことを確認
- 残っていたら PID を特定して終了

### 3. GPU VRAM 確認
- `nvidia-smi` で VRAM 使用量をチェック
- 全プロセス終了後も VRAM が多く使われている場合は警告

### 4. 結果報告
- 終了したプロセス一覧
- 最終的なプロセス状態 (クリーン / 要確認)
- GPU VRAM 状態
