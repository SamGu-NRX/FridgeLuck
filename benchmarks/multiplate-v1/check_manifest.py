#!/usr/bin/env python3
"""Verify benchmarks/multiplate-v1/manifest.json against the acquired data.

Checks (all must pass, exit 0):
  A. Structure: schema_version, class table, per-image records with all fields.
  B. Counts: >= 500 multi-food images and >= 150 single-food controls.
  C. Roles consistent with the frozen boxes (multi = >= 2 distinct classes,
     control = exactly 1).
  D. Hashes: every image's sha256 matches the bytes in the local pool;
     license record_sha256 recomputes; annotation file hashes match the local
     copies.
  E. Series: dHash hamming between any two frozen images > 4 (no near
     duplicates co-frozen); every image carries a series_group.
  F. Boxes: coordinates in [0,1], xmin<xmax, ymin<ymax; label names match the
     class table; GT canonicalization holds (no same-class pair with IoU >
     0.98).

Run from the repo root:
  python3 benchmarks/multiplate-v1/check_manifest.py
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from build_manifest import (  # noqa: E402
    DHASH_HAMMING_MAX,
    DUP_SAME_CLASS_IOU,
    POOL_DIR,
    RAW_DIR,
    TARGET_CONTROL,
    TARGET_MULTI,
    dhash,
    hamming,
    iou,
)
from PIL import Image  # noqa: E402

MANIFEST_PATH = HERE / "manifest.json"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def main() -> None:
    if not MANIFEST_PATH.exists():
        fail(f"{MANIFEST_PATH} missing; run build_manifest.py first")
    manifest = json.loads(MANIFEST_PATH.read_text())

    # A. structure
    if manifest.get("schema_version") != "multiplate-v1":
        fail("schema_version mismatch")
    class_mids = {c["mid"] for c in manifest["classes"]}
    class_by_mid = {c["mid"]: c for c in manifest["classes"]}
    if len(class_mids) != len(manifest["classes"]):
        fail("duplicate class mids")

    # D. annotation hashes
    for fname, pinned in manifest["dataset"]["annotation_files"].items():
        local = RAW_DIR / fname
        if not local.exists():
            fail(f"annotation file {fname} not acquired")
        got = hashlib.sha256(local.read_bytes()).hexdigest()
        if got != pinned:
            fail(f"annotation hash drift for {fname}")

    # B/C/D/E/F per image
    counts = {"multi": 0, "control": 0}
    seen_dhashes: list[tuple[str, int]] = []
    for im in manifest["images"]:
        iid = im["image_id"]
        for field in ["role", "series_group", "sha256", "license", "width", "height", "boxes", "dhash"]:
            if field not in im:
                fail(f"{iid}: missing field {field}")
        path = POOL_DIR / f"{iid}.jpg"
        if not path.exists():
            fail(f"{iid}: image not in local pool (run acquire.py)")
        data = path.read_bytes()
        got = hashlib.sha256(data).hexdigest()
        if got != im["sha256"]:
            fail(f"{iid}: image sha256 mismatch")
        lic = im["license"]
        want = hashlib.sha256(lic["record"].encode()).hexdigest()
        if want != lic["record_sha256"]:
            fail(f"{iid}: license record hash mismatch")

        with Image.open(path) as img:
            if img.size != (im["width"], im["height"]):
                fail(f"{iid}: decoded size mismatch")

        counts[im["role"]] += 1
        mids = {b["label_mid"] for b in im["boxes"]}
        expected_role = "multi" if len(mids) >= 2 else "control"
        if im["role"] != expected_role:
            fail(f"{iid}: role {im['role']} but {len(mids)} distinct classes")
        for b in im["boxes"]:
            if b["label_mid"] not in class_mids:
                fail(f"{iid}: box class {b['label_mid']} not in class table")
            if b["label_name"] != class_by_mid[b["label_mid"]]["name"]:
                fail(f"{iid}: label name mismatch for {b['label_mid']}")
            if not (0 <= b["xmin"] < b["xmax"] <= 1 and 0 <= b["ymin"] < b["ymax"] <= 1):
                fail(f"{iid}: box coordinates out of range")

        h = int(im["dhash"], 16)
        if hamming(h, dhash(Image.open(path))) > 2:
            fail(f"{iid}: stored dhash does not match image")
        for other_id, other_h in seen_dhashes:
            if hamming(h, other_h) <= DHASH_HAMMING_MAX:
                fail(f"{iid}: near-duplicate of {other_id} (hamming <= {DHASH_HAMMING_MAX})")
        seen_dhashes.append((iid, h))

        # F. canonicalization invariants within the image
        boxes = [(b["label_mid"], (b["xmin"], b["ymin"], b["xmax"], b["ymax"])) for b in im["boxes"]]
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                if boxes[i][0] == boxes[j][0] and iou(boxes[i][1], boxes[j][1]) > DUP_SAME_CLASS_IOU:
                    fail(f"{iid}: uncollapsed same-class duplicate boxes")

    if counts["multi"] < TARGET_MULTI:
        fail(f"multi count {counts['multi']} < {TARGET_MULTI}")
    if counts["control"] < TARGET_CONTROL:
        fail(f"control count {counts['control']} < {TARGET_CONTROL}")

    print("manifest OK:", json.dumps({
        "images": len(manifest["images"]),
        "multi": counts["multi"],
        "control": counts["control"],
        "classes": len(manifest["classes"]),
        "gt_boxes": manifest["counts"]["gt_boxes"],
    }))


if __name__ == "__main__":
    main()
