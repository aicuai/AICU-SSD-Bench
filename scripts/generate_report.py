#!/usr/bin/env python3
"""
結果 JSON → 個別 HTML レポート生成スクリプト

results/ 配下の各 JSON ファイルから、見やすい HTML レポートを生成する。
全体サマリーレポート (report_index.html) と各実験の個別レポートを出力。

Usage:
    python scripts/generate_report.py
    python scripts/generate_report.py --results-dir ./results --output-dir ./results/reports
"""

import argparse
import json
import os
from datetime import datetime
from pathlib import Path

REPORT_CSS = """
<style>
  @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;700;900&display=swap');
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Noto Sans JP', system-ui, sans-serif; background: #fff; color: #1f2328; line-height: 1.8; padding: 40px 24px; max-width: 900px; margin: 0 auto; }
  h1 { font-size: 1.8rem; font-weight: 900; background: linear-gradient(135deg, #1428a0, #00b4d8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text; margin-bottom: 8px; }
  h2 { font-size: 1.3rem; font-weight: 700; margin: 32px 0 16px; padding-bottom: 8px; border-bottom: 2px solid #0969da; }
  h3 { font-size: 1.1rem; margin: 20px 0 12px; }
  .meta { color: #656d76; font-size: 0.9rem; margin-bottom: 24px; }
  .card { background: #fff; border: 1px solid #d0d7de; border-radius: 12px; padding: 20px 24px; margin-bottom: 16px; }
  .card .label { font-size: 0.8rem; color: #656d76; text-transform: uppercase; letter-spacing: .06em; }
  .card .val { font-size: 1.3rem; font-weight: 700; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; }
  table { width: 100%; border-collapse: collapse; margin-top: 8px; }
  th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid #d0d7de; font-size: 0.9rem; }
  th { font-size: 0.8rem; color: #656d76; text-transform: uppercase; letter-spacing: .06em; background: #f6f8fa; }
  .bar-wrap { background: #f0f0f0; border-radius: 6px; overflow: hidden; height: 28px; }
  .bar { height: 28px; border-radius: 6px; display: flex; align-items: center; justify-content: flex-end; padding: 0 10px; }
  .bar span { font-size: 0.78rem; font-weight: 700; color: #fff; text-shadow: 0 1px 2px rgba(0,0,0,0.5); white-space: nowrap; }
  .best { color: #1a7f37; font-weight: 700; }
  .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #d0d7de; color: #656d76; font-size: 0.82rem; text-align: center; }
  a { color: #0969da; text-decoration: none; }
  a:hover { color: #0550ae; }
  .nav { margin-bottom: 24px; }
  .nav a { display: inline-block; margin-right: 16px; font-weight: 700; }
  .tag { display: inline-block; padding: 2px 10px; border: 1px solid #d0d7de; border-radius: 12px; font-size: 0.75rem; color: #656d76; margin-left: 8px; }
</style>
"""

DRIVE_COLORS = {
    "C": "#8250df",
    "D": "#0969da",
    "E": "#bf5700",
    "F": "#cf222e",
    "G": "#1a7f37",
}


def fmt_val(v, decimals=2):
    if v is None:
        return "--"
    if v >= 10000:
        return f"{v:,.0f}"
    if v >= 100:
        return f"{v:.0f}"
    return f"{v:.{decimals}f}"


def generate_experiment_report(key: str, exp: dict, sysinfo: dict | None, output_dir: Path) -> str:
    """個別実験の HTML レポートを生成"""
    model = exp.get("model", "")
    drives = exp.get("drives", {})
    drive_order = exp.get("drive_order", sorted(drives.keys()))

    title = key.replace("_", " ").title()
    if model and model != "unknown":
        title += f" ({model})"

    html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{title} - ai-storage-bench Report</title>
{REPORT_CSS}
</head>
<body>
<div class="nav"><a href="report_index.html">&larr; All Results</a> <a href="https://bench.aicu.jp">bench.aicu.jp</a></div>
<h1>{title}</h1>
<p class="meta">ai-storage-bench experiment report</p>
"""

    # System info
    if sysinfo:
        html += "<h2>System</h2><div class='grid'>"
        if sysinfo.get("cpu"):
            html += f"<div class='card'><div class='label'>CPU</div><div class='val'>{sysinfo['cpu'].get('name','')}</div></div>"
        if sysinfo.get("gpu"):
            gpu = sysinfo["gpu"]
            html += f"<div class='card'><div class='label'>GPU</div><div class='val'>{gpu.get('name','')}</div><div class='label'>VRAM {gpu.get('vram_total_mb',0)} MB</div></div>"
        if sysinfo.get("memory"):
            html += f"<div class='card'><div class='label'>RAM</div><div class='val'>{sysinfo['memory'].get('total_gb',0)} GB</div></div>"
        html += "</div>"

    # Main metric bar chart
    html += "<h2>Results</h2>"
    vals = []
    for d in drive_order:
        if d not in drives:
            continue
        v = drives[d].get("median_s")
        if v is not None:
            vals.append((d, v, drives[d]))

    if vals:
        is_disk_speed = "disk_speed" in key
        is_lower_better = not is_disk_speed
        max_val = max(v for _, v, _ in vals)
        min_val = min(v for _, v, _ in vals)
        unit = "MB/s" if is_disk_speed else "s"
        best_val = min_val if is_lower_better else max_val

        html += "<table><thead><tr><th>Drive</th><th>Value</th><th>Bar</th></tr></thead><tbody>"
        for d, v, extra in vals:
            color = DRIVE_COLORS.get(d, "#8b949e")
            pct = (v / max_val * 100) if max_val > 0 else 0
            best_cls = " class='best'" if v == best_val else ""
            disk_info = extra.get("disk_info", {})
            drive_name = disk_info.get("model", d)

            html += f"<tr><td{best_cls}>{d}: {drive_name}</td>"
            html += f"<td{best_cls}>{fmt_val(v)} {unit}</td>"
            html += f"<td><div class='bar-wrap'><div class='bar' style='width:{max(pct,3):.0f}%;background:{color}'>"
            html += f"<span>{fmt_val(v)} {unit}</span></div></div></td></tr>"
        html += "</tbody></table>"

        # Sub-metrics
        # Read/Write for disk-speed
        has_rw = any(ex.get("read_mbs") for _, _, ex in vals)
        if has_rw:
            html += "<h3>Read / Write Speed</h3>"
            html += "<table><thead><tr><th>Drive</th><th>Read (MB/s)</th><th>Write (MB/s)</th></tr></thead><tbody>"
            for d, v, extra in vals:
                read_raw = extra.get("read_mbs")
                write_raw = extra.get("write_mbs")
                read = fmt_val(read_raw) if read_raw is not None else "--"
                write = fmt_val(write_raw) if write_raw is not None else "--"
                html += f"<tr><td>{d}:</td><td>{read}</td><td>{write}</td></tr>"
            html += "</tbody></table>"

        # Warm median for imggen
        has_warm = any(ex.get("warm_median_s") for _, _, ex in vals)
        if has_warm:
            html += "<h3>Warm Start (cached)</h3>"
            html += "<table><thead><tr><th>Drive</th><th>Warm Median (s)</th></tr></thead><tbody>"
            for d, v, extra in vals:
                wm = extra.get("warm_median_s")
                html += f"<tr><td>{d}:</td><td>{fmt_val(wm)}</td></tr>"
            html += "</tbody></table>"

        # Tokens/sec for codegen
        has_tps = any(ex.get("avg_tokens_per_sec") for _, _, ex in vals)
        if has_tps:
            html += "<h3>Token Generation Speed</h3>"
            html += "<table><thead><tr><th>Drive</th><th>Avg tok/s</th></tr></thead><tbody>"
            for d, v, extra in vals:
                tps = extra.get("avg_tokens_per_sec")
                html += f"<tr><td>{d}:</td><td>{fmt_val(tps, 1)}</td></tr>"
            html += "</tbody></table>"

    html += """
<div class="footer">
  <p>Generated by <a href="https://github.com/aicuai/aicu-bench">ai-storage-bench</a></p>
  <p><a href="https://bench.aicu.jp">bench.aicu.jp</a></p>
</div>
</body></html>"""

    filename = f"report_{key}.html"
    filepath = output_dir / filename
    filepath.write_text(html, encoding="utf-8")
    return filename


def generate_index_report(
    experiments: dict, sysinfo: dict | None, summary: dict | None,
    report_files: dict, output_dir: Path, updated: str
):
    """全体サマリーの HTML レポートを生成"""
    html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ai-storage-bench Results Report</title>
{REPORT_CSS}
</head>
<body>
<h1>ai-storage-bench Results</h1>
<p class="meta">Generated: {updated} | <a href="https://bench.aicu.jp">bench.aicu.jp</a></p>
"""

    # System info card
    if sysinfo:
        html += "<h2>System</h2><div class='grid'>"
        if sysinfo.get("cpu"):
            html += f"<div class='card'><div class='label'>CPU</div><div class='val'>{sysinfo['cpu'].get('name','')}</div></div>"
        if sysinfo.get("gpu"):
            gpu = sysinfo["gpu"]
            html += f"<div class='card'><div class='label'>GPU</div><div class='val'>{gpu.get('name','')}</div><div class='label'>VRAM {gpu.get('vram_total_mb',0)} MB</div></div>"
        if sysinfo.get("memory"):
            html += f"<div class='card'><div class='label'>RAM</div><div class='val'>{sysinfo['memory'].get('total_gb',0)} GB</div></div>"
        if sysinfo.get("os"):
            html += f"<div class='card'><div class='label'>OS</div><div class='val'>{sysinfo['os'].get('name','')}</div></div>"
        html += "</div>"

        # Storage info
        if sysinfo.get("storage"):
            html += "<h3>Storage</h3><table><thead><tr><th>Drive</th><th>Model</th><th>Bus</th><th>Size</th></tr></thead><tbody>"
            for s in sysinfo["storage"]:
                letters_raw = s.get("letters", "")
                letters = ", ".join(letters_raw) if isinstance(letters_raw, list) else str(letters_raw)
                html += f"<tr><td>{letters}</td><td>{s.get('model','')}</td><td>{s.get('bus_type','')}</td><td>{s.get('size_gb','')} GB</td></tr>"
            html += "</tbody></table>"

    # Summary
    if summary:
        html += "<h2>Summary</h2><div class='grid'>"
        dur = summary.get("total_duration_hms", "--")
        html += f"<div class='card'><div class='label'>Total Duration</div><div class='val'>{dur}</div></div>"
        errs = len(summary.get("errors", []))
        html += f"<div class='card'><div class='label'>Errors</div><div class='val'>{errs}</div></div>"
        drives = summary.get("test_drives", [])
        html += f"<div class='card'><div class='label'>Test Drives</div><div class='val'>{', '.join(str(d) for d in drives)}</div></div>"
        html += "</div>"

    # Experiment links
    html += "<h2>Experiments</h2>"
    if report_files:
        for key, filename in report_files.items():
            exp = experiments.get(key, {})
            model = exp.get("model", "")
            drive_count = len(exp.get("drives", {}))
            html += f"<div class='card'><a href='{filename}'><strong>{key}</strong></a>"
            if model and model != "unknown":
                html += f" <span class='tag'>{model}</span>"
            html += f" <span class='tag'>{drive_count} drives</span>"

            # Quick summary values
            drives_data = exp.get("drives", {})
            vals = [(d, drives_data[d].get("median_s")) for d in exp.get("drive_order", []) if d in drives_data and drives_data[d].get("median_s") is not None]
            if vals:
                is_disk = "disk_speed" in key
                unit = "MB/s" if is_disk else "s"
                best = max(vals, key=lambda x: x[1]) if is_disk else min(vals, key=lambda x: x[1])
                html += f"<br><span style='color:#656d76;font-size:0.85rem;'>Best: {best[0]}: {fmt_val(best[1])} {unit}</span>"
            html += "</div>"
    else:
        html += "<p style='color:#656d76;'>No experiment results found.</p>"

    html += """
<div class="footer">
  <p>Generated by <a href="https://github.com/aicuai/aicu-bench">ai-storage-bench</a></p>
  <p><a href="https://bench.aicu.jp">bench.aicu.jp</a> | <a href="https://amzn.to/46JRoWE">Samsung 9100 PRO</a></p>
</div>
</body></html>"""

    (output_dir / "report_index.html").write_text(html, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Generate HTML reports from benchmark results")
    parser.add_argument(
        "--results-dir", type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results"),
    )
    parser.add_argument(
        "--output-dir", type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "results", "reports"),
    )
    parser.add_argument(
        "--data-json", type=str,
        default=os.path.join(os.path.dirname(__file__), "..", "site", "data.json"),
    )
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    output_dir = Path(args.output_dir)
    data_json = Path(args.data_json)

    output_dir.mkdir(parents=True, exist_ok=True)

    # data.json を読み込む（update_site.py で生成済み）
    if not data_json.exists():
        print(f"data.json not found: {data_json}")
        print("Run scripts/update_site.py first.")
        return

    with open(data_json, encoding="utf-8") as f:
        data = json.load(f)

    experiments = data.get("experiments", {})
    updated = data.get("updated", datetime.now().isoformat())

    # sysinfo
    sysinfo = None
    sysinfo_path = results_dir / "sysinfo.json"
    if sysinfo_path.exists():
        with open(sysinfo_path, encoding="utf-8-sig") as f:
            sysinfo = json.load(f)

    # bench_summary
    summary = None
    summary_path = results_dir / "bench_summary.json"
    if summary_path.exists():
        with open(summary_path, encoding="utf-8-sig") as f:
            summary = json.load(f)

    # 個別レポート生成
    report_files = {}
    for key, exp in experiments.items():
        filename = generate_experiment_report(key, exp, sysinfo, output_dir)
        report_files[key] = filename
        print(f"  Generated: {filename}")

    # インデックスレポート生成
    generate_index_report(experiments, sysinfo, summary, report_files, output_dir, updated)
    print(f"  Generated: report_index.html")
    print(f"\nReports saved to: {output_dir}")
    print(f"Open: {output_dir / 'report_index.html'}")


if __name__ == "__main__":
    main()
