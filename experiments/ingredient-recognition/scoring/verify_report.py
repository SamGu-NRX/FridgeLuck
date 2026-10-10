#!/usr/bin/env python3
"""Byte-stable report verification.

Two checks, both must pass for REPORT.md's numbers to be trusted:

1. Determinism: re-running scoring/score.py on each final observation file
   produces outputs byte-identical to the committed artifacts in scoring/
   (decompressed comparison for .gz, which embeds a wall-clock mtime in its
   header) and byte-identical across two fresh scoring processes.
2. Report agreement: every results-table row in REPORT.md is derived from the
   committed scores.json artifacts and must match them exactly; the frozen
   thresholds in REPORT.md must match the chosen_threshold in the sweep
   artifacts.

Exit code 0 prints VERIFIED; anything else fails loudly.
"""

from __future__ import annotations

import gzip
import json
import subprocess
import sys
import tempfile
from pathlib import Path

EXPERIMENT = Path(__file__).resolve().parent.parent
SCORE = EXPERIMENT / "scoring" / "score.py"
REPORT = EXPERIMENT / "REPORT.md"

# observation stem -> (results-table row label, threshold)
FINAL_RUNS = {
    "validation_curated_absorberson_sixcrop": ("Six-crop, dev-tuned, absorbers on", 0.25),
    "validation_curated_absorberson_wholecrop": ("Whole-image, dev-tuned, absorbers on", 0.005),
    "validation_curated_absorberson": ("Six-crop, app constant, absorbers on", 0.1),
    "validation_curated_absorbersoff": ("Six-crop, app constant, absorbers off", 0.1),
    "validation_curated_usda_absorberson": ("Six-crop, curated+USDA labels, absorbers on", 0.1),
}


def _read_bytes(p: Path) -> bytes:
    if p.suffix == ".gz":
        with gzip.open(p, "rb") as f:
            return f.read()
    return p.read_bytes()


def _fmt_row(label: str, threshold: float, s: dict) -> str:
    r = s["instance_recall"]
    return (
        f"| {label} | {threshold} | {r['all']:.4f} | {r['exact']:.4f} | {r['coarse']:.4f} | "
        f"{r['ambiguous']:.4f} | {s['detection_precision']:.4f} | "
        f"{s['detections_total']:,} | {s['abstain_images_with_mapped_gt']} | "
        f"{s['no_claim_violations']} |"
    ).replace("**", "")


def main() -> None:
    report = REPORT.read_text()
    report_normalized = report.replace("**", "")
    problems: list[str] = []

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        for stem, (label, threshold) in sorted(FINAL_RUNS.items()):
            obs = EXPERIMENT / "observations" / f"openmodel_{stem}.jsonl.gz"
            committed_scores = EXPERIMENT / "scoring" / f"{stem}_scores.json"
            for out_dir in [td / "a", td / "b"]:
                proc = subprocess.run(
                    [sys.executable, str(SCORE), "--observations", str(obs), "--split", "validation",
                     "--out-prefix", stem, "--out-dir", str(out_dir)],
                    capture_output=True, text=True,
                )
                if proc.returncode != 0:
                    problems.append(f"{stem}: score.py failed: {proc.stderr[-300:]}")
                    break
            if problems:
                continue
            # determinism across processes
            for name in [f"{stem}_scores.json", f"{stem}_per_class.csv"]:
                if (td / "a" / name).read_bytes() != (td / "b" / name).read_bytes():
                    problems.append(f"{stem}: {name} not deterministic across runs")
            with gzip.open(td / "a" / f"{stem}_per_image.jsonl.gz", "rt") as fa, \
                 gzip.open(td / "b" / f"{stem}_per_image.jsonl.gz", "rt") as fb:
                if fa.read() != fb.read():
                    problems.append(f"{stem}: per_image records not deterministic")
            # stability vs committed artifacts (the "observations" field
            # records the invocation path, which legitimately differs by cwd
            # — REPORT.md's commands use paths relative to the experiment dir)
            fresh = json.loads((td / "a" / f"{stem}_scores.json").read_text())
            committed = json.loads(committed_scores.read_text())
            fresh.pop("observations", None)
            committed.pop("observations", None)
            if fresh != committed:
                problems.append(f"{stem}: rescored scores.json differs from committed {committed_scores.name}")
            # report agreement
            expected = _fmt_row(label, threshold, committed)
            if expected not in report_normalized:
                problems.append(f"REPORT.md row mismatch for {stem}:\n  expected: {expected}")

        for name, frozen in [("thresholds_sixcrop_dev.json", 0.25),
                             ("thresholds_wholecrop_dev.json", 0.005)]:
            sweep = json.loads((EXPERIMENT / "scoring" / name).read_text())
            actual = sweep.get("frozen_threshold", sweep.get("chosen_threshold"))
            if actual != frozen:
                problems.append(f"{name}: frozen threshold {actual} != {frozen}")
        if "frozen six-crop 0.25" not in report and "**0.25**" not in report:
            problems.append("REPORT.md: frozen six-crop threshold 0.25 not stated")
        if "**0.005**" not in report:
            problems.append("REPORT.md: frozen whole-image threshold 0.005 not stated")

    if problems:
        print("FAILED:")
        for p in problems:
            print(" -", p)
        raise SystemExit(1)
    print("VERIFIED: scoring outputs byte-stable and REPORT.md rows match committed artifacts")


if __name__ == "__main__":
    main()
