#!/usr/bin/env python3
"""Regenerate and verify the grocery-OCR report.

    python3 experiments/grocery-ocr/score.py --results experiments/grocery-ocr/results
    python3 experiments/grocery-ocr/score.py --results experiments/grocery-ocr/results --verify-report

Without --verify-report: recompute scores into the results dir (same as during the run).
With --verify-report: recompute in a scratch dir from the RAW harness outputs and the
frozen manifest, then require an exact match with the stored results/scores.json and
per_product_*.json. Any drift — dropped cases, altered targets, hand-edited metrics —
fails with a diff. Mutations are exercised by tests/experiments/grocery-ocr/tests.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
ACQ = os.path.join(ROOT, "acquisition")


def recompute(manifest, results):
    scratch = tempfile.mkdtemp(prefix="score-verify-")
    cmd = ["python3", os.path.join(ACQ, "score.py"),
           "--manifest", manifest,
           "--targets", os.path.join(results, "harness", "targets_output.jsonl"),
           "--ocr", os.path.join(results, "harness", "ocr_front_output.jsonl"),
           "--reference", os.path.join(results, "harness", "reference_output.jsonl"),
           "--out-dir", scratch]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        return None, f"recompute failed rc={p.returncode}: {p.stderr[-2000:]}"
    with open(os.path.join(scratch, "scores.json"), encoding="utf-8") as f:
        scores = json.load(f)
    per = {}
    for arm in ("reference", "ocr"):
        path = os.path.join(scratch, f"per_product_{arm}.json")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                per[arm] = json.load(f)
    return (scores, per), None


def deep_diff(a, b, path=""):
    diffs = []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                diffs.append(f"{path}.{k}: only in recomputed")
            elif k not in b:
                diffs.append(f"{path}.{k}: missing from recomputed (dropped case?)")
            else:
                diffs.extend(deep_diff(a[k], b[k], f"{path}.{k}"))
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            diffs.append(f"{path}: list length {len(b)} stored vs {len(a)} recomputed")
        for i, (x, y) in enumerate(zip(a, b)):
            diffs.extend(deep_diff(x, y, f"{path}[{i}]"))
    elif a != b:
        diffs.append(f"{path}: stored {b!r} vs recomputed {a!r}")
    return diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True)
    ap.add_argument("--manifest", default=os.path.join(ROOT, "manifest.json"))
    ap.add_argument("--verify-report", action="store_true")
    args = ap.parse_args()

    recomputed, err = recompute(args.manifest, args.results)
    if err:
        print("VERIFY FAIL:", err)
        return 1
    scores, per = recomputed

    if not args.verify_report:
        out_scores = os.path.join(args.results, "scores.json")
        with open(out_scores, "w", encoding="utf-8") as f:
            json.dump(scores, f, ensure_ascii=False, indent=2)
        for arm, rows in per.items():
            with open(os.path.join(args.results, f"per_product_{arm}.json"), "w", encoding="utf-8") as f:
                json.dump(rows, f, ensure_ascii=False, indent=1)
        print("scores written to", out_scores)
        return 0

    problems = []
    stored_path = os.path.join(args.results, "scores.json")
    if not os.path.exists(stored_path):
        problems.append("scores.json missing from results")
    else:
        with open(stored_path, encoding="utf-8") as f:
            stored = json.load(f)
        problems.extend(deep_diff(scores, stored, "scores"))
    for arm, rows in per.items():
        path = os.path.join(args.results, f"per_product_{arm}.json")
        if not os.path.exists(path):
            problems.append(f"per_product_{arm}.json missing")
            continue
        with open(path, encoding="utf-8") as f:
            stored_rows = json.load(f)
        if len(stored_rows) != len(rows):
            problems.append(f"per_product_{arm}: {len(stored_rows)} stored vs {len(rows)} recomputed cases")
        else:
            problems.extend(deep_diff(rows, stored_rows, f"per_product_{arm}"))
        for i, row in enumerate(stored_rows if isinstance(stored_rows, list) else []):
            if "code" not in row or "detection_ids" not in row:
                problems.append(f"per_product_{arm}[{i}]: missing code/detection_ids")
                break

    if problems:
        print(f"VERIFY FAIL: {len(problems)} mismatch(es)")
        for p_ in problems[:40]:
            print(" -", p_)
        return 1
    print("VERIFY OK: stored report matches recomputation from raw outputs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
