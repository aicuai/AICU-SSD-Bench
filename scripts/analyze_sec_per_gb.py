#!/usr/bin/env python3
"""sec/GB メトリクス分析 — モデルロード実効速度の正規化

results/ 配下の model_load JSON を読み込み、成功した cold-start run のみを対象に
sec/GiB と実効スループット (MB/s) を算出する。
"""

import json
import re
import sys
from pathlib import Path

RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"

# model_weights 文字列 ("4.9 GiB", "1.3 GiB", "333.8 MiB") → bytes
def parse_size_bytes(s: str) -> float:
    m = re.match(r"([\d.]+)\s*(GiB|MiB|GB|MB)", s)
    if not m:
        return 0.0
    val = float(m.group(1))
    unit = m.group(2)
    if unit in ("GiB", "GB"):
        return val * 1024 * 1024 * 1024
    return val * 1024 * 1024


def parse_size_gib(s: str) -> float:
    return parse_size_bytes(s) / (1024 ** 3)


def analyze():
    # Collect all model_load JSONs
    load_files = []
    for pattern_dir in [RESULTS_DIR / "vibe-local-bench", RESULTS_DIR / "run1_backup"]:
        if pattern_dir.exists():
            load_files.extend(pattern_dir.glob("load_*.json"))

    rows = []
    for f in sorted(load_files):
        with open(f, encoding="utf-8-sig") as fp:
            data = json.load(fp)

        if data.get("test") != "model_load":
            continue

        drive = data.get("drive", "?")
        model = data.get("model", "?")
        source = "run1_backup" if "run1_backup" in str(f) else "latest"

        for r in data.get("results", []):
            if not r.get("success"):
                continue
            load_s = r.get("load_time_s", 0)
            internal = r.get("ollama_internal", {})
            weights_str = internal.get("model_weights", "")
            size_gib = parse_size_gib(weights_str)
            if size_gib < 0.1:
                continue  # skip partial loads (e.g. 333.8 MiB cache hits)

            sec_per_gib = load_s / size_gib if size_gib else 0
            throughput_mbs = (size_gib * 1024) / load_s if load_s else 0

            runner_s = internal.get("runner_started_s")
            io_est_s = load_s - runner_s if runner_s else None
            io_throughput = (size_gib * 1024) / io_est_s if io_est_s and io_est_s > 0 else None

            gpu_before = r.get("gpu_before", {})
            gpu_after = r.get("gpu_after", {})

            rows.append({
                "source": source,
                "drive": drive,
                "model": model,
                "run": r.get("run"),
                "load_s": load_s,
                "weights_gib": round(size_gib, 2),
                "sec_per_gib": round(sec_per_gib, 3),
                "throughput_mbs": round(throughput_mbs, 1),
                "runner_s": runner_s,
                "io_est_s": round(io_est_s, 3) if io_est_s else None,
                "io_throughput_mbs": round(io_throughput, 1) if io_throughput else None,
                "temp_before": gpu_before.get("temp_c"),
                "temp_after": gpu_after.get("temp_c"),
                "power_before": gpu_before.get("power_w"),
                "power_after": gpu_after.get("power_w"),
            })

    if not rows:
        print("No successful cold-start model_load data found.")
        return

    # Print table
    print("=" * 110)
    print("sec/GiB Analysis - Model Load Effective Speed Normalization")
    print("=" * 110)
    hdr = f"{'Source':<12} {'Drive':<6} {'Model':<12} {'Run':<4} {'Load(s)':<8} {'Size(GiB)':<10} {'sec/GiB':<9} {'Tput(MB/s)':<11} {'runner(s)':<10} {'IO est(s)':<10} {'IO(MB/s)':<10}"
    print(hdr)
    print("-" * 110)
    for r in rows:
        print(
            f"{r['source']:<12} "
            f"{r['drive']:<6} "
            f"{r['model']:<12} "
            f"{r['run']:<4} "
            f"{r['load_s']:<8.3f} "
            f"{r['weights_gib']:<10} "
            f"{r['sec_per_gib']:<9.3f} "
            f"{r['throughput_mbs']:<11.1f} "
            f"{str(r['runner_s'] or '-'):<10} "
            f"{str(r['io_est_s'] or '-'):<10} "
            f"{str(r['io_throughput_mbs'] or '-'):<10}"
        )

    print()
    print("Key Insights:")
    print("  - sec/GiB: lower = faster effective model loading per unit of data")
    print("  - Tput(MB/s): total effective throughput (includes deserialization + memory alloc)")
    print("  - IO(MB/s): estimated disk I/O throughput (load_time - runner_started overhead)")
    print("  - Compare IO(MB/s) vs raw disk benchmark to quantify non-I/O overhead")

    # Also output JSON for programmatic use
    out_path = RESULTS_DIR / "analysis_sec_per_gib.json"
    with open(out_path, "w", encoding="utf-8") as fp:
        json.dump({"metric": "sec_per_gib", "rows": rows}, fp, indent=2, ensure_ascii=False)
    print(f"\n  JSON saved: {out_path}")


if __name__ == "__main__":
    analyze()
