#!/usr/bin/env python3
"""Classify Open Images validation+test images into nonfood-rejection strata.

Reads the five annotation/metadata CSVs from the meta cache and emits a
candidates CSV with, for every image that has any relevant evidence:

  image_id, subset, disposition (empty_visible | opaque_unknown |
  food_control | ambiguous | out_of_scope), food_absence_verified,
  label_source (human | machine | human+machine), context_names,
  occluder_names, food_names, food_machine_conf, author, original_size ...

Dispositions (see METHOD.md for full rules):
  food_control   food evidence: human-verified, or machine >= FOOD_POS_T
  empty_visible  kitchen context present, ZERO food evidence (human, or
                 machine >= NEG_FOOD_T), no occluder evidence
  opaque_unknown occluder present (human, or machine >= OCC_MACH_T), zero
                 food evidence. Context optional. Precedence over
                 empty_visible when both apply (contents unknowable).
  ambiguous      kitchen-relevant (context or occluder) and machine food
                 evidence in [AMBIG_LOW, FOOD_POS_T): the evidence is
                 uncertain. Excluded from sampling, counted in stats.
  out_of_scope   no context, no occluder, no food evidence.

classify() is imported by the tests so the disposition rules are pinned.
The frozen manifest records the eligible and ambiguous counts per stratum.
"""
from __future__ import annotations

import csv
import os
from collections import defaultdict
from pathlib import Path

import taxonomy as T

META_DIR = Path(
    os.environ.get("NONFOOD_META_DIR", Path.home() / ".cache" / "fridgeluck-nonfood" / "meta")
)

HUMAN_FILES = (
    "validation-annotations-human-imagelabels.csv",
    "test-annotations-human-imagelabels.csv",
)
MACHINE_FILES = (
    "validation-annotations-machine-imagelabels.csv",
    "test-annotations-machine-imagelabels.csv",
)
SUBSET_OF = {
    "validation-annotations-human-imagelabels.csv": "validation",
    "test-annotations-human-imagelabels.csv": "test",
    "validation-annotations-machine-imagelabels.csv": "validation",
    "test-annotations-machine-imagelabels.csv": "test",
}

FOOD_M = set(T.FOOD)
CTX_M = set(T.CONTEXT)
OCC_M = set(T.OCCLUDER)
ALL_NAMES = {**T.FOOD, **T.CONTEXT, **T.OCCLUDER}


def load_mid_names():
    mid2name = {}
    with open(META_DIR / "class-descriptions-boxable.csv") as f:
        for r in csv.reader(f):
            if len(r) >= 2:
                mid2name[r[0]] = r[1]
    for mid, expected in {**T.FOOD, **T.CONTEXT, **T.OCCLUDER}.items():
        if mid2name.get(mid) != expected:
            raise SystemExit(
                f"taxonomy MID {mid} expected {expected!r}, "
                f"class CSV says {mid2name.get(mid)!r} - refusing to build"
            )
    return mid2name


def load_evidence():
    """Returns (pos_h, neg_h, machine, subset) keyed by image id."""
    pos_h: dict[str, set] = defaultdict(set)
    neg_h: dict[str, set] = defaultdict(set)
    machine: dict[str, dict] = defaultdict(dict)
    subset: dict[str, str] = {}
    for f in HUMAN_FILES:
        with open(META_DIR / f) as fh:
            for r in csv.DictReader(fh):
                img, mid = r["ImageID"], r["LabelName"]
                subset.setdefault(img, SUBSET_OF[f])
                if r["Confidence"] == "1":
                    pos_h[img].add(mid)
                elif r["Confidence"] == "0":
                    neg_h[img].add(mid)
    for f in MACHINE_FILES:
        with open(META_DIR / f) as fh:
            for r in csv.DictReader(fh):
                conf = float(r["Confidence"])
                img, mid = r["ImageID"], r["LabelName"]
                if conf >= T.AMBIG_LOW and conf > machine[img].get(mid, 0.0):
                    machine[img][mid] = conf
    return pos_h, neg_h, machine, subset


def classify(pos_h_img, neg_h_img, machine_img, food_m, ctx_m, occ_m):
    """Disposition + evidence flags for one image. Shared with tests."""
    food_h = pos_h_img & food_m
    ctx_h = pos_h_img & ctx_m
    occ_h = pos_h_img & occ_m
    food_mach = {m: c for m, c in machine_img.items() if m in food_m}
    ctx_mach = {m for m, c in machine_img.items() if m in ctx_m and c >= T.CTX_MACH_T}
    occ_mach = {m for m, c in machine_img.items() if m in occ_m and c >= T.OCC_MACH_T}

    food_conf = max(food_mach.values(), default=0.0)
    food_pos = bool(food_h) or food_conf >= T.FOOD_POS_T
    ctx_pos = bool(ctx_h) or bool(ctx_mach)
    occ_pos = bool(occ_h) or bool(occ_mach)

    out = {
        "disposition": "out_of_scope",
        "food_absence_verified": False,
        "label_source": "",
        "context_names": [],
        "occluder_names": [],
        "food_names": [],
        "food_machine_conf": round(food_conf, 4),
    }
    ctx_ids = ctx_h | ctx_mach
    occ_ids = occ_h | occ_mach
    out["context_names"] = sorted(ALL_NAMES[m] for m in ctx_ids)
    out["occluder_names"] = sorted(ALL_NAMES[m] for m in occ_ids)
    out["food_names"] = sorted(
        ALL_NAMES[m] for m in (food_h | {m for m, c in food_mach.items() if c >= T.AMBIG_LOW})
    )

    if food_pos:
        out["disposition"] = "food_control"
        src = []
        if food_h:
            src.append("human")
        if food_mach:
            src.append("machine")
        out["label_source"] = "+".join(src)
        return out
    if not (ctx_pos or occ_pos):
        return out
    if T.AMBIG_LOW <= food_conf < T.FOOD_POS_T:
        # machine saw possible food at sub-threshold confidence: uncertain
        out["disposition"] = "ambiguous"
        return out
    # zero food evidence at or above NEG_FOOD_T
    out["food_absence_verified"] = bool(neg_h_img & food_m)
    out["disposition"] = "opaque_unknown" if occ_pos else "empty_visible"
    src = []
    if ctx_h or occ_h or out["food_absence_verified"]:
        src.append("human")
    if ctx_mach or occ_mach:
        src.append("machine")
    out["label_source"] = "+".join(src)
    return out


def main():
    load_mid_names()
    pos_h, neg_h, machine, subset = load_evidence()

    meta_rows = {}
    for f in ("validation-images-with-rotation.csv", "test-images-with-rotation.csv"):
        with open(META_DIR / f) as fh:
            for r in csv.DictReader(fh):
                meta_rows[r["ImageID"]] = r

    rows = []
    for img in sorted(set(pos_h) | set(machine)):
        ev = classify(pos_h[img], neg_h[img], machine[img], FOOD_M, CTX_M, OCC_M)
        m = meta_rows.get(img, {})
        rows.append(
            {
                "image_id": img,
                "subset": subset[img],
                "disposition": ev["disposition"],
                "food_absence_verified": ev["food_absence_verified"],
                "label_source": ev["label_source"],
                "context_names": ";".join(ev["context_names"]),
                "occluder_names": ";".join(ev["occluder_names"]),
                "food_names": ";".join(ev["food_names"]),
                "food_machine_conf": ev["food_machine_conf"],
                "author": m.get("Author", ""),
                "author_profile_url": m.get("AuthorProfileURL", ""),
                "license": m.get("License", ""),
                "landing_url": m.get("OriginalLandingURL", ""),
                "original_url": m.get("OriginalURL", ""),
                "original_size": m.get("OriginalSize", ""),
                "title": m.get("Title", ""),
            }
        )

    out = META_DIR.parent / "candidates.csv"
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    counts = defaultdict(int)
    verified = defaultdict(int)
    for r in rows:
        counts[r["disposition"]] += 1
        verified[r["disposition"]] += int(r["food_absence_verified"])
    print(f"wrote {len(rows)} rows -> {out}")
    for k in ("empty_visible", "opaque_unknown", "food_control", "ambiguous", "out_of_scope"):
        print(f"  {k}: {counts[k]} (food_absence_verified: {verified[k]})")


if __name__ == "__main__":
    main()
