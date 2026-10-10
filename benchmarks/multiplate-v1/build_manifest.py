#!/usr/bin/env python3
"""Freeze the multi-plate benchmark slice into manifest.json.

Selection rules (documented, deterministic, seed-free):

1. Class space: all Open Images boxable classes in the subtree of "Food"
   (/m/02wbm, excluding Food itself) with >= 60 eligible freeform,
   confidence=1 validation boxes. Eligible rows exclude IsGroupOf, IsDepiction,
   and IsInside boxes. Yields 31 classes on the 2018_04 validation snapshot.
2. GT canonicalization: parent-class boxes subsumed by a descendant-class box
   (IoU >= 0.8 against a deeper-in-hierarchy box) are dropped, so a strawberry
   box does not double-count beside the Fruit box covering it. Exact same-class
   boxes with IoU > 0.98 collapse to one.
3. Roles: an image is "multi" if it has >= 2 distinct selected classes among
   canonical boxes; "control" if exactly 1. NOTE: "multi" counts distinct food
   categories, not servings or plates — the manifest records no plate/serving
   ground truth, and no claim in this benchmark treats food boxes as plates.
4. Series groups: 64-bit dHash, groups of hamming distance <= 4 keep their
   first member in image-id order; later members are excluded from the slice
   so no two frozen images are near-duplicates. Every frozen image records its
   (singleton or shared) series group.
5. Selection: role pools in ascending image-id order; first 540 multi + 160
   control that downloaded and decode successfully. Freeze targets are >= 500
   multi and >= 150 control.

Image/license hashes: sha256 of the exact downloaded bytes; license records are
"CC BY 2.0|open-images-dataset|validation/<id>.jpg" (Open Images images are CC
BY 2.0 per the official FAQ) hashed the same way.

Images themselves are NOT committed. acquire.py re-downloads them and
check_manifest.py re-verifies every hash.
"""

from __future__ import annotations

import csv
import hashlib
import json
import sys
from collections import defaultdict
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
RAW_DIR = Path("/home/user/work/multiplate/raw")
POOL_DIR = Path("/home/user/work/bench/multiplate-images")
MANIFEST_PATH = HERE / "manifest.json"

FOOD_ROOT = "/m/02wbm"
MIN_CLASS_BOXES = 60
FREEZE_MULTI = 540
FREEZE_CONTROL = 160
TARGET_MULTI = 500
TARGET_CONTROL = 150
DUP_PARENT_IOU = 0.8
DUP_SAME_CLASS_IOU = 0.98
DHASH_HAMMING_MAX = 4


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_class_space() -> tuple[dict[str, str], dict[str, int], dict[str, list[str]]]:
    """Returns (mid -> name), mid -> eligible box count, mid -> ancestor mids."""
    hierarchy = json.loads((RAW_DIR / "bbox_labels_600_hierarchy.json").read_text())
    names = {
        row[0]: row[1]
        for row in csv.reader((RAW_DIR / "class-descriptions-boxable.csv").read_text().splitlines())
    }

    ancestors: dict[str, list[str]] = {}

    def walk(node, chain):
        lid = node["LabelName"]
        ancestors[lid] = list(chain)
        for child in node.get("Subcategory", []):
            walk(child, chain + [lid])

    walk(hierarchy, [])
    food = {m for m, a in ancestors.items() if FOOD_ROOT in a and m != FOOD_ROOT}

    counts: dict[str, int] = defaultdict(int)
    with (RAW_DIR / "validation-annotations-bbox.csv").open() as f:
        for row in csv.DictReader(f):
            if row["LabelName"] not in food or not eligible_row(row):
                continue
            counts[row["LabelName"]] += 1
    selected = {m: c for m, c in counts.items() if c >= MIN_CLASS_BOXES}
    return names, selected, ancestors


def eligible_row(row) -> bool:
    return (
        row["Source"] == "freeform"
        and row["Confidence"] == "1"
        and row["IsGroupOf"] == "0"
        and row["IsDepiction"] == "0"
        and row["IsInside"] == "0"
    )


def iou(a, b) -> float:
    ax0, ay0, ax1, ay1 = a
    bx0, by0, bx1, by1 = b
    ix0, iy0 = max(ax0, bx0), max(ay0, by0)
    ix1, iy1 = min(ax1, bx1), min(ay1, by1)
    iw, ih = max(0.0, ix1 - ix0), max(0.0, iy1 - iy0)
    inter = iw * ih
    union = (ax1 - ax0) * (ay1 - ay0) + (bx1 - bx0) * (by1 - by0) - inter
    return inter / union if union > 0 else 0.0


def load_boxes_from_rows(
    rows: list[dict],
    selected: set[str],
    names: dict,
    ancestors: dict[str, list[str]],
):
    """Canonicalized selected-class boxes from pre-parsed CSV rows for one image."""
    boxes_rows = []
    for row in rows:
        if row["LabelName"] not in selected or not eligible_row(row):
            continue
        boxes_rows.append(
            {
                "label_mid": row["LabelName"],
                "label_name": names[row["LabelName"]],
                "box": (
                    float(row["XMin"]),
                    float(row["YMin"]),
                    float(row["XMax"]),
                    float(row["YMax"]),
                ),
                "is_occluded": int(row["IsOccluded"]),
                "is_truncated": int(row["IsTruncated"]),
                "depth": len(ancestors[row["LabelName"]]),
            }
        )
    # collapse exact same-class duplicates
    collapsed = []
    for r in sorted(boxes_rows, key=lambda r: (r["label_mid"], -(r["box"][2] - r["box"][0]) * (r["box"][3] - r["box"][1]))):
        if any(
            c["label_mid"] == r["label_mid"] and iou(c["box"], r["box"]) > DUP_SAME_CLASS_IOU
            for c in collapsed
        ):
            continue
        collapsed.append(r)
    # drop parent boxes subsumed by a descendant-class box
    keep = []
    for r in collapsed:
        subsumed = any(
            o["label_mid"] != r["label_mid"]
            and o["depth"] > r["depth"]
            and iou(o["box"], r["box"]) >= DUP_PARENT_IOU
            for o in collapsed
        )
        if not subsumed:
            keep.append(r)
    for r in keep:
        r.pop("depth")
    return keep


def dhash(img: Image.Image) -> int:
    g = img.convert("L").resize((9, 8), Image.LANCZOS)
    px = list(g.getdata())
    bits = 0
    for y in range(8):
        for x in range(8):
            if px[y * 9 + x] < px[y * 9 + x + 1]:
                bits |= 1 << (y * 8 + x)
    return bits


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


def main() -> None:
    names, class_counts, ancestors = load_class_space()
    selected = set(class_counts)
    if len(selected) < 10:
        sys.exit("class space collapsed; refusing to freeze")

    # candidate pools in documented order
    raw_rows: dict[str, list[dict]] = defaultdict(list)
    with (RAW_DIR / "validation-annotations-bbox.csv").open() as f:
        for row in csv.DictReader(f):
            if row["LabelName"] in selected and eligible_row(row):
                raw_rows[row["ImageID"]].append(row)

    pool_rows: dict[str, set[str]] = defaultdict(set)
    for image_id, rows in raw_rows.items():
        pool_rows[image_id] = {r["LabelName"] for r in rows}

    multi_pool = sorted(i for i, cs in pool_rows.items() if len(cs & selected) >= 2)
    control_pool = sorted(i for i, cs in pool_rows.items() if len(cs & selected) == 1)
    print(f"eligible pools: {len(multi_pool)} multi, {len(control_pool)} control")

    # Selection on CANONICAL roles: near-dup exclusion + first-N per role in
    # image-id order. Roles may differ from pool-stage counts when a parent
    # box was subsumed by a deeper-class box.
    multi_sel, control_sel = [], []
    seen_dhashes: dict[str, int] = {}
    for image_id in sorted(set(multi_pool) | set(control_pool)):
        if len(multi_sel) >= FREEZE_MULTI and len(control_sel) >= FREEZE_CONTROL:
            break
        path = POOL_DIR / f"{image_id}.jpg"
        if not path.exists():
            continue
        try:
            img = Image.open(path)
            img.load()
        except Exception:  # noqa: BLE001
            continue
        h = dhash(img)
        if any(hamming(h, hv) <= DHASH_HAMMING_MAX for hv in seen_dhashes.values()):
            continue
        boxes = load_boxes_from_rows(raw_rows[image_id], selected, names, ancestors)
        classes = {b["label_mid"] for b in boxes}
        role = "multi" if len(classes) >= 2 else "control"
        quota = FREEZE_MULTI if role == "multi" else FREEZE_CONTROL
        taken = multi_sel if role == "multi" else control_sel
        if len(taken) >= quota:
            continue
        seen_dhashes[image_id] = h
        taken.append((image_id, h, img.size))

    multi_sel = multi_sel[:FREEZE_MULTI]
    control_sel = control_sel[:FREEZE_CONTROL]
    print(f"frozen: {len(multi_sel)} multi, {len(control_sel)} control")
    if len(multi_sel) < TARGET_MULTI or len(control_sel) < TARGET_CONTROL:
        sys.exit(f"freeze targets not met ({len(multi_sel)}/{TARGET_MULTI} multi, "
                 f"{len(control_sel)}/{TARGET_CONTROL} control); run acquire.py first")

    images = []
    for image_id, h, (width, height) in sorted(multi_sel + control_sel):
        boxes = load_boxes_from_rows(raw_rows[image_id], selected, names, ancestors)
        classes = {b["label_mid"] for b in boxes}
        role = "multi" if len(classes) >= 2 else "control"
        license_record = f"CC BY 2.0|open-images-dataset|validation/{image_id}.jpg"
        path = POOL_DIR / f"{image_id}.jpg"
        images.append(
            {
                "image_id": image_id,
                "role": role,
                "series_group": image_id,  # near-dups were excluded; groups are singletons
                "sha256": sha256_hex(path.read_bytes()),
                "license": {"name": "CC BY 2.0", "record": license_record,
                            "record_sha256": sha256_hex(license_record.encode())},
                "source_url": f"https://open-images-dataset.s3.amazonaws.com/validation/{image_id}.jpg",
                "width": width,
                "height": height,
                "dhash": f"{h:016x}",
                "boxes": [
                    {
                        "label_mid": b["label_mid"],
                        "label_name": b["label_name"],
                        "xmin": round(b["box"][0], 6),
                        "ymin": round(b["box"][1], 6),
                        "xmax": round(b["box"][2], 6),
                        "ymax": round(b["box"][3], 6),
                        "is_occluded": b["is_occluded"],
                        "is_truncated": b["is_truncated"],
                    }
                    for b in boxes
                ],
            }
        )

    annotation_hashes = {
        fname: sha256_hex((RAW_DIR / fname).read_bytes())
        for fname in ["validation-annotations-bbox.csv", "class-descriptions-boxable.csv",
                      "bbox_labels_600_hierarchy.json"]
    }
    multi_count = sum(1 for im in images if im["role"] == "multi")
    manifest = {
        "schema_version": "multiplate-v1",
        "created_utc": "2026-10-10",
        "dataset": {
            "name": "Open Images 2018_04 validation, Food-subtree box classes",
            "selection_rule": {
                "class_space": "descendants of /m/02wbm (Food), excluding Food, with >= 60 eligible "
                               "freeform confidence=1 validation boxes (IsGroupOf=IsDepiction=IsInside=0)",
                "roles": "multi = >= 2 distinct selected classes after GT canonicalization; "
                         "control = exactly 1",
                "gt_canonicalization": f"same-class boxes with IoU > {DUP_SAME_CLASS_IOU} collapse; "
                                       f"parent boxes with IoU >= {DUP_PARENT_IOU} against a deeper-class box drop",
                "series_groups": f"64-bit dHash, hamming <= {DHASH_HAMMING_MAX} excluded from co-freeze; "
                                 "groups recorded per image",
                "selection_order": "ascending image_id within role pools",
                "counts_frozen": {"multi": len(multi_sel), "control": len(control_sel)},
            },
            "uecfood256_status": "authoritative download http://www.ivl.disco.unimib.it/media/data/"
                                 "UECFOOD256.zip returned 404 on 2026-10-10 (checked this session); "
                                 "documented Open Images food classes used instead",
            "license_note": "Open Images images are CC BY 2.0 per the official FAQ; images are NOT "
                            "committed — acquire.py re-downloads from the official unsigned S3 mirror "
                            "and check_manifest.py verifies every hash",
            "annotation_files": annotation_hashes,
            "sources": {
                "annotations": "https://storage.googleapis.com/openimages/2018_04/",
                "images": "https://open-images-dataset.s3.amazonaws.com/validation/<image_id>.jpg",
                "downloader_reference": "https://github.com/openimages/dataset (downloader.py, "
                                        "bucket open-images-dataset)",
            },
        },
        "classes": [
            {"mid": m, "name": names[m], "eligible_boxes": class_counts[m]}
            for m in sorted(selected, key=lambda m: -class_counts[m])
        ],
        "counts": {
            "images": len(images),
            "multi": multi_count,
            "control": len(images) - multi_count,
            "gt_boxes": sum(len(im["boxes"]) for im in images),
        },
        "images": images,
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=1))
    print(f"wrote {MANIFEST_PATH}: {manifest['counts']}")


if __name__ == "__main__":
    main()
