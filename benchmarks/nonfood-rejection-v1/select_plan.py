#!/usr/bin/env python3
"""Select which candidates to download (surplus pools per stratum).

Reads candidates.csv from sample.py and writes sample_plan.csv containing
download candidates in priority order. Final 300/300/600 selection happens
in build_manifest.py after fetch results and pHash series grouping are
known; this plan carries a surplus so dead URLs and duplicate series can be
replaced without a second sampling pass.

Priority per stratum:
  1. food_absence_verified (human annotators explicitly verified food absent)
  2. label_source contains "human"
  3. smaller original file first (faster fetch, model input is resized anyway)
  4. image_id ascending (deterministic tie-break)
Author cap: at most 3 images per author per stratum in the plan.
"""
from __future__ import annotations

import csv
import os
from collections import defaultdict
from pathlib import Path

CACHE = Path(
    os.environ.get("NONFOOD_CACHE", Path.home() / ".cache" / "fridgeluck-nonfood")
)

TARGETS = {"empty_visible": (300, 1.4), "opaque_unknown": (300, 1.6), "food_control": (600, 1.3)}
AUTHOR_CAP = 3


def main():
    candidates = list(csv.DictReader(open(CACHE / "candidates.csv")))
    plan = []
    for stratum, (target, margin) in TARGETS.items():
        want = int(target * margin)
        pool = [c for c in candidates if c["disposition"] == stratum]
        pool.sort(
            key=lambda c: (
                -int(c["food_absence_verified"] in ("True", "1", True)),
                0 if "human" in c["label_source"] else 1,
                int(c["original_size"] or 10**9),
                c["image_id"],
            )
        )
        per_author = defaultdict(int)
        taken = 0
        for c in pool:
            if per_author[c["author"]] >= AUTHOR_CAP:
                continue
            per_author[c["author"]] += 1
            plan.append({"image_id": c["image_id"], "subset": c["subset"], "stratum": stratum})
            taken += 1
            if taken >= want:
                break
        print(f"{stratum}: planned {taken} of {len(pool)} candidates (target {target})")

    out = CACHE / "sample_plan.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["image_id", "subset", "stratum"])
        w.writeheader()
        w.writerows(plan)
    print(f"wrote {len(plan)} rows -> {out}")


if __name__ == "__main__":
    main()
