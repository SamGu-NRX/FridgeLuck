#!/usr/bin/env python3
"""Build and freeze manifest.json for nonfood-rejection-v1.

Two-phase, mirroring the FoodSeg103 convention (sample -> fetch -> freeze):

  sample.py       evidence classification per image (dispositions)
  select_plan.py  surplus download plan
  acquire.py      fetch + hash-pin image bytes (cache, not repo)
  build_manifest.py (this) -> manifest.json + build_stats.json, committed

This script:
  1. keeps successfully fetched images per stratum (sha256 re-computed from
     the cache file, so the manifest binds to bytes on disk),
  2. groups images by photographer (group_id) and detects near-duplicate
     "series" within a photographer via 8x8 pHash Hamming <= 8,
  3. takes exactly 300 empty_visible + 300 opaque_unknown negatives and 600
     food controls, assigning dev/test so that no photographer group and no
     series spans both splits,
  4. pairs every negative with a food control matched on kitchen context
     (exact context > any context > none), same split,
  5. records eligible/ambiguous/out_of_scope counts per stratum.

Deterministic: same fetch log + cache always produce byte-identical output.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
from collections import defaultdict
from pathlib import Path

import taxonomy as T
from acquire import CACHE
from PIL import Image

HERE = Path(__file__).resolve().parent

TARGETS = {"empty_visible": 300, "opaque_unknown": 300, "food_control": 600}
# Contexts that make a match strongest first (an open fridge beats a shelf).
CONTEXT_PRIORITY = [
    "Refrigerator", "Cupboard", "Cabinetry", "Bathroom cabinet", "Shelf",
    "Countertop", "Kitchen appliance", "Kitchenware", "Bowl", "Mixing bowl",
    "Kitchen & dining room table", "Serving tray", "Cutting board",
    "Kitchen utensil", "Kitchen knife", "Microwave oven", "Slow cooker",
    "Frying pan", "Kettle", "Toaster", "Coffeemaker",
]
SOURCE_NOTE = (
    "Open Images image-level labels (validation + test subsets; human-verified "
    "and machine-generated), frozen S3 image copies; all images CC-BY 2.0 with "
    "per-photographer attribution recorded in the manifest."
)


# ---------------------------------------------------------------- pHash ---
# Same construction as experiments/ingredient-recognition/scoring/build_manifest.py
# (8x8 DCT-II over 32x32 grayscale, median threshold on low frequencies).


def _dct_matrix(n):
    import numpy as np

    k = np.arange(n).reshape(-1, 1)
    r = np.arange(n).reshape(1, -1)
    m = np.cos((2 * r + 1) * k * np.pi / (2 * n))
    m[0, :] *= 1 / np.sqrt(2)
    return m * np.sqrt(2 / n)


_DCT32 = _dct_matrix(32)


def phash(img_bytes: bytes) -> int:
    import numpy as np

    with Image.open(io.BytesIO(img_bytes)) as im:
        gray = im.convert("L").resize((32, 32))
        arr = np.asarray(gray, dtype=float)
    f = _DCT32 @ arr @ _DCT32.T
    block = f[:8, :8].flatten()
    med = np.median(block[1:])
    return int.from_bytes(np.packbits((block > med).astype(np.uint8)).tobytes(), "big")


def hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def match_key_of(cand_row):
    ctx = [c for c in cand_row["context_names"].split(";") if c]
    for c in CONTEXT_PRIORITY:
        if c in ctx:
            return c
    return ctx[0] if ctx else "none"


def main():
    cand = {r["image_id"]: r for r in csv.DictReader(open(CACHE / "candidates.csv"))}
    plan = {r["image_id"]: r for r in csv.DictReader(open(CACHE / "sample_plan.csv"))}
    fetch = {r["image_id"]: r for r in json.load(open(CACHE / "fetch_log.json"))}

    # 1. keep ok fetches whose cache file matches the logged hash
    ok = {}
    hash_mismatch = 0
    for img, rec in fetch.items():
        if rec.get("status") != "ok" or img not in plan:
            continue
        p = CACHE / "images" / rec["subset"] / f"{img}.jpg"
        if not p.exists():
            continue
        if sha256_file(p) != rec["sha256"]:
            hash_mismatch += 1
            continue
        ok[img] = rec
    if hash_mismatch:
        print(f"warning: {hash_mismatch} cache files did not match their fetch log; excluded")

    # 2. pHash series within each photographer
    phashes = {}
    for img, rec in ok.items():
        phashes[img] = phash((CACHE / "images" / rec["subset"] / f"{img}.jpg").read_bytes())

    by_author = defaultdict(list)
    for img in ok:
        by_author[cand[img]["author"]].append(img)

    series_of = {}
    for author, imgs in by_author.items():
        parent = {img: img for img in imgs}

        def find(x):
            while parent[x] != x:
                parent[x] = parent[parent[x]]
                x = parent[x]
            return x

        for i, a in enumerate(imgs):
            for b in imgs[i + 1:]:
                if hamming(phashes[a], phashes[b]) <= 8:
                    parent[find(a)] = find(b)
        roots = {}
        for img in imgs:
            r = find(img)
            roots.setdefault(r, len(roots))
            series_of[img] = f"{author}|series{roots[r]}"

    # 3. exact-count selection in plan (priority) order
    chosen = {"empty_visible": [], "opaque_unknown": [], "food_control": []}
    for img in plan:
        if img not in ok:
            continue
        s = plan[img]["stratum"]
        if len(chosen[s]) < TARGETS[s]:
            chosen[s].append(img)
    for s, imgs in chosen.items():
        if len(imgs) < TARGETS[s]:
            raise SystemExit(
                f"stratum {s}: only {len(imgs)} fetched, need {TARGETS[s]}; re-plan and re-fetch"
            )

    # 4. split assignment for negatives: whole photographer groups stay on one
    # side, and each (split, stratum) hits exactly half the target. Group
    # sizes make a single greedy pass dead-end-prone, so retry with seeded
    # orderings until an exact fit is found.
    neg_order = chosen["empty_visible"] + chosen["opaque_unknown"]
    neg_groups = defaultdict(lambda: defaultdict(list))
    for img in neg_order:
        neg_groups[cand[img]["author"]][plan[img]["stratum"]].append(img)

    import random

    assignment = None
    for seed in range(500):
        rng = random.Random(seed)
        groups = sorted(
            neg_groups.items(),
            key=lambda kv: (-sum(len(v) for v in kv[1].values()), rng.random()),
        )
        rem = {s: {st: TARGETS[st] // 2 for st in TARGETS if st != "food_control"} for s in ("dev", "test")}
        assign = {}
        for author, strata in groups:
            sizes = {st: len(v) for st, v in strata.items()}
            fits = [s for s in ("dev", "test") if all(rem[s][st] >= c for st, c in sizes.items())]
            if not fits:
                break
            split = max(fits, key=lambda s: (sum(rem[s].values()), s))
            for st, imgs in strata.items():
                rem[split][st] -= len(imgs)
                for img in imgs:
                    assign[img] = split
        else:
            if all(v == 0 for s in rem.values() for v in s.values()):
                assignment = assign
                break
    if assignment is None:
        raise SystemExit("could not balance negative splits at 150/150 per stratum with whole-group binding")
    split_of_author = {cand[i]["author"]: assignment[i] for i in neg_order}
    for img in neg_order:
        ok[img]["_split"] = assignment[img]
        ok[img]["_role"] = "negative"

    # 5. controls: first serve (match_key, split) demand from negatives, then
    # leftovers top up each split to its negative total (pairs must share a
    # split). Forced controls (authors shared with negatives) go first.
    demand = defaultdict(int)
    for img in neg_order:
        demand[(match_key_of(cand[img]), ok[img]["_split"])] += 1

    def control_keys(crow):
        ctx = [c for c in crow["context_names"].split(";") if c]
        return [k for k in CONTEXT_PRIORITY if k in ctx] or (["none"] if not ctx else sorted(ctx))

    cap = defaultdict(int)
    for img in neg_order:
        cap[ok[img]["_split"]] += 1
    assigned = defaultdict(int)
    served = defaultdict(int)
    control_author_split = {}
    plan_rank = {img: i for i, img in enumerate(plan)}
    ctrl_order = sorted(
        chosen["food_control"],
        key=lambda i: (
            cand[i]["author"] not in split_of_author and cand[i]["author"] not in control_author_split,
            plan_rank[i],
        ),
    )
    for img in ctrl_order:
        keys = control_keys(cand[img])
        forced = split_of_author.get(cand[img]["author"]) or control_author_split.get(cand[img]["author"])
        if forced:
            split = forced
            key = max(keys, key=lambda k: demand[(k, split)] - served[(k, split)])
        else:
            options = [
                (demand[(k, s)] - served[(k, s)], cap[s] - assigned[s], -ki, s, k)
                for s in ("dev", "test") if assigned[s] < cap[s]
                for ki, k in enumerate(keys)
            ]
            if not options:
                raise SystemExit(f"control {img}: both splits already full")
            options.sort(key=lambda o: (-o[0], -o[1], o[2], o[3]))
            _, _, _, split, key = options[0]
        served[(key, split)] += 1
        assigned[split] += 1
        control_author_split.setdefault(cand[img]["author"], split)
        ctx = set(control_keys(cand[img]))
        ok[img]["_split"] = split
        ok[img]["_role"] = "food_control"
        ok[img]["_match_key"] = key
        ok[img]["_match_quality"] = (
            "exact_context" if key != "none" and key in ctx else
            "any_context" if key != "none" else "none"
        )
    for split in ("dev", "test"):
        if assigned[split] != cap[split]:
            raise SystemExit(f"controls in {split}: {assigned[split]} != negatives {cap[split]}")

    # 6. pair negatives with controls (same match_key + split, greedy)
    free = defaultdict(list)
    for img in chosen["food_control"]:
        free[(ok[img]["_match_key"], ok[img]["_split"])].append(img)
    used = set()
    pair_of = {}
    quality_counts = defaultdict(int)
    for img in neg_order:
        key = match_key_of(cand[img])
        split = ok[img]["_split"]
        match = next((c for c in free[(key, split)] if c not in used), None)
        quality = "exact_context" if key != "none" else "none"
        if match is None and key != "none":
            match = next((c for c in free[("none", split)] if c not in used), None)
            quality = "any_context"
        if match is None:
            remaining = [c for c in chosen["food_control"] if c not in used and ok[c]["_split"] == split]
            match = remaining[0] if remaining else None
            quality = "none"
        if match is None:
            raise SystemExit(f"no control left to pair with negative {img}")
        used.add(match)
        pair_of[img] = match
        quality_counts[quality] += 1
        ok[img]["_pair_quality"] = quality
        ok[match]["_pair_quality"] = quality

    # 7. emit manifest
    images = []
    for img in sorted(neg_order + chosen["food_control"]):
        c = cand[img]
        rec = ok[img]
        row = {
            "image_id": img,
            "subset": rec["subset"],
            "s3_url": rec["url"],
            "role": rec["_role"],
            "stratum": plan[img]["stratum"],
            "split": rec["_split"],
            "match_key": rec.get("_match_key", match_key_of(c)),
            "pair_id": None,
            "match_quality": rec.get("_pair_quality", ""),
            "food_absence_verified": c["food_absence_verified"] == "True",
            "label_source": c["label_source"],
            "context_labels": [x for x in c["context_names"].split(";") if x],
            "occluder_labels": [x for x in c["occluder_names"].split(";") if x],
            "food_labels": [x for x in c["food_names"].split(";") if x],
            "author": c["author"],
            "author_profile_url": c["author_profile_url"],
            "license": c["license"],
            "landing_url": c["landing_url"],
            "original_url": c["original_url"],
            "group_id": f"photographer:{c['author']}",
            "series_id": f"series:{series_of[img]}",
            "sha256": rec["sha256"],
            "bytes": rec["bytes"],
            "width": rec["width"],
            "height": rec["height"],
        }
        images.append(row)
    by_id = {r["image_id"]: r for r in images}
    for seq, (neg_img, ctrl_img) in enumerate(sorted(pair_of.items())):
        pid = f"pair-{seq:04d}"
        by_id[neg_img]["pair_id"] = pid
        by_id[ctrl_img]["pair_id"] = pid

    pool_counts = defaultdict(int)
    for r in csv.DictReader(open(CACHE / "candidates.csv")):
        pool_counts[r["disposition"]] += 1

    stats = {
        "eligible_counts": {
            "empty_visible": TARGETS["empty_visible"],
            "opaque_unknown": TARGETS["opaque_unknown"],
            "food_control": TARGETS["food_control"],
            "total": sum(TARGETS.values()),
        },
        "pool_counts": dict(pool_counts),
        "ambiguity_rule": (
            "ambiguous = kitchen-relevant image whose machine food evidence "
            f"falls in [{T.AMBIG_LOW}, {T.FOOD_POS_T}): neither clean food "
            "evidence nor verified absence; excluded from sampling."
        ),
        "pair_quality": dict(quality_counts),
        "photographer_groups": len({r["group_id"] for r in images}),
        "series_groups": len({r["series_id"] for r in images}),
        "excluded_hash_mismatch": hash_mismatch,
        "per_split": {},
    }
    for r in images:
        k = f"{r['split']}|{r['stratum']}"
        stats["per_split"][k] = stats["per_split"].get(k, 0) + 1

    manifest = {
        "meta": {
            "name": "nonfood-rejection-v1",
            "source": SOURCE_NOTE,
            "source_urls": {
                "image_labels": (
                    "https://storage.googleapis.com/openimages/v5/"
                    "{validation,test}-annotations-{human,machine}-imagelabels.csv"
                ),
                "image_metadata": (
                    "https://storage.googleapis.com/openimages/2018_04/"
                    "{validation,test}/{validation,test}-images-with-rotation.csv"
                ),
                "images": "https://open-images-dataset.s3.amazonaws.com/{subset}/{image_id}.jpg",
                "classes": "https://storage.googleapis.com/openimages/2018_04/class-descriptions-boxable.csv",
            },
            "license_note": (
                "All images CC-BY 2.0 (attribution: author + author_profile_url "
                "recorded per image). Images are NOT committed; acquire.py "
                "re-downloads from the pinned S3 copy and check_manifest.py "
                "verifies sha256 against this manifest."
            ),
            "taxonomy_counts": {
                "food": len(T.FOOD), "context": len(T.CONTEXT), "occluder": len(T.OCCLUDER),
            },
            "sampling_rule": (
                "negatives need kitchen context and zero food evidence "
                f"(human-verified, or machine >= {T.NEG_FOOD_T}); food controls "
                f"need food evidence (human, or machine >= {T.FOOD_POS_T}); "
                "opaque_unknown takes precedence over empty_visible when an "
                "occluder (box/container/bottle/tin can/plastic bag) is present; "
                "author cap 3 per stratum; food_absence_verified preferred."
            ),
            "split_rule": (
                "dev/test 50/50 within each stratum; whole photographer and "
                "series groups bound to one split; controls paired to negatives "
                "on kitchen context within the same split."
            ),
            "eligible_and_ambiguous_counts": {
                "eligible": stats["eligible_counts"],
                "ambiguous_pool": stats["pool_counts"]["ambiguous"],
                "pool_counts": stats["pool_counts"],
                "note": (
                    "eligible = frozen 600 negatives (300 empty_visible + 300 "
                    "opaque_unknown) + 600 food controls; ambiguous counts the "
                    "kitchen-relevant candidates excluded for uncertain food "
                    "evidence; full pool counts are committed alongside."
                ),
            },
        },
        "images": sorted(images, key=lambda r: r["image_id"]),
    }
    out = HERE / "manifest.json"
    out.write_text(json.dumps(manifest, indent=1))
    (HERE / "build_stats.json").write_text(json.dumps(stats, indent=1))
    print(json.dumps(stats, indent=1))
    print(f"wrote {out} ({len(images)} images) and build_stats.json")


if __name__ == "__main__":
    main()
