#!/usr/bin/env python3
"""Genuine Apple-observation replay adapter.

Converts an observation export from the FridgeLuck iOS app (the device's real
Vision classifier output) into the benchmark observation JSONL schema so the
existing scorer can score it unchanged.

This adapter INVENTS NOTHING. It never generates, simulates, or back-fills
labels, probabilities, or detections. It only converts what a genuine export
contains. A run against it is meaningful only when the export comes from a
real device session; no such run exists in this repository (see REPORT.md).

Expected export contract (JSON, one file per capture session):

    {
      "source": "apple_device",            # optional, must equal this if present
      "classifier": {"name": "...", ...},  # optional device-reported metadata
      "images": [
        {
          "image_id": 123,                 # int; must match the manifest split
          "crops": [
            {
              "id": "full",                # device crop id, preserved verbatim
              "labels": [
                {"name": "Rice", "prob": 0.97}   # name: str, prob: float in [0,1]
              ]
            }
          ]
        }
      ]
    }

Processing mirrors the open-model runner's app-pipeline replay (observe.py),
stopping where the device already did the work:
  - labels at or below the record floor are recorded but never kept
  - labels above the threshold are resolved through the ported app resolution
    (userCorrection -> curated lexicon -> catalog exact), same as the app
  - detections accumulate best-confidence-per-ingredient ACROSS ALL CROPS of
    an image (the app's dedup), ties: first wins
  - detections sort by confidence desc

Outputs (same shapes as observe.py, plus a marker):
  observations JSONL: {"split", "image_id", "crops", "detections"} records
  .meta.json         run metadata with "source": "apple_device" and the
                     device-reported classifier metadata, so downstream
                     scoring can distinguish genuine Apple observations from
                     open-model substitutes
  .failures.jsonl    per-image conversion failures (always empty: schema
                     violations abort the run instead, so a partially
                     converted export never looks like a complete file)

Schema violations abort the whole run with a clear error: a partially
converted export must never look like a complete observation file.
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
import time
from pathlib import Path

EXPERIMENT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(EXPERIMENT_ROOT / "resolution"))
from app_resolution import (  # noqa: E402
    IngredientCatalogResolver,
    IngredientLexicon,
    resolve_label,
)

# Kept in sync with runner/observe.py (which owns the canonical copy; it is
# not imported here to avoid pulling the open-model ML stack into a
# device-data-only path).
ABSORBERS = {
    "a messy kitchen counter",
    "a wooden table",
    "kitchen utensils",
    "a person",
    "a prepared dish on a plate",
}


class ExportError(ValueError):
    """The export violates the observation contract; abort, never guess."""


def _load_export(path: Path) -> dict:
    try:
        export = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise ExportError(f"{path}: not valid JSON: {e}") from e
    if not isinstance(export, dict):
        raise ExportError("export must be a JSON object")
    source = export.get("source")
    if source is not None and source != "apple_device":
        raise ExportError(f"export source must be 'apple_device', got {source!r}")
    images = export.get("images")
    if not isinstance(images, list):
        raise ExportError("export must have an 'images' array")
    return export


def _validate_image(rec: dict, index: int, seen_ids: set[int]) -> tuple[int, list]:
    if not isinstance(rec, dict):
        raise ExportError(f"images[{index}] must be an object")
    image_id = rec.get("image_id")
    if not isinstance(image_id, int) or isinstance(image_id, bool):
        raise ExportError(f"images[{index}].image_id must be an int, got {image_id!r}")
    if image_id in seen_ids:
        raise ExportError(f"duplicate image_id {image_id}")
    seen_ids.add(image_id)
    crops = rec.get("crops")
    if not isinstance(crops, list):
        raise ExportError(f"images[{index}] (id {image_id}): 'crops' must be an array")
    for ci, crop in enumerate(crops):
        if not isinstance(crop, dict) or not isinstance(crop.get("id"), str):
            raise ExportError(f"images[{index}].crops[{ci}]: 'id' must be a string")
        labels = crop.get("labels")
        if not isinstance(labels, list):
            raise ExportError(
                f"images[{index}].crops[{ci}] (id {crop['id']}): 'labels' must be an array"
            )
        for li, label in enumerate(labels):
            if not isinstance(label, dict):
                raise ExportError(f"images[{index}].crops[{ci}].labels[{li}] must be an object")
            name = label.get("name")
            prob = label.get("prob")
            if not isinstance(name, str) or not name:
                raise ExportError(
                    f"images[{index}].crops[{ci}].labels[{li}]: 'name' must be a non-empty string"
                )
            if not isinstance(prob, (int, float)) or isinstance(prob, bool) or not 0.0 <= prob <= 1.0:
                raise ExportError(
                    f"images[{index}].crops[{ci}].labels[{li}] ({name!r}): "
                    f"'prob' must be a number in [0,1], got {prob!r}"
                )
    return image_id, crops


def convert(
    export: dict,
    split: str,
    threshold: float,
    record_floor: float,
    lex: IngredientLexicon,
    catalog: IngredientCatalogResolver,
) -> tuple[list[dict], list[dict]]:
    """Convert validated export records into observation records.

    Returns (observations, failures). failures is always empty for a valid
    export; schema problems raise ExportError instead of degrading silently.
    """
    seen: set[int] = set()
    rows: list[dict] = []
    for index, rec in enumerate(export.get("images", [])):
        image_id, crops = _validate_image(rec, index, seen)
        best: dict[int, tuple[float, str, str]] = {}
        record_labels_out: list[dict] = []
        for crop in crops:
            crop_out: dict = {"id": crop["id"], "labels": []}
            for label in crop["labels"]:
                name, prob = label["name"], float(label["prob"])
                # same gates as the open-model runner: labels at/below the
                # record floor are not recorded at all
                if prob <= record_floor:
                    continue
                resolved = resolve_label(name, lex, catalog)
                entry = {
                    "name": name,
                    "prob": round(prob, 6),
                    "resolved_id": resolved.ingredient_id if resolved else None,
                    "provenance": resolved.provenance if resolved else None,
                    "is_absorber": name in ABSORBERS,
                }
                crop_out["labels"].append(entry)
                if prob > threshold and resolved is not None:
                    ing_id = resolved.ingredient_id
                    prev = best.get(ing_id)
                    if prev is None or prob > prev[0]:  # ties: first wins
                        best[ing_id] = (prob, name, resolved.provenance)
            record_labels_out.append(crop_out)
        rows.append(
            {
                "split": split,
                "image_id": image_id,
                "crops": record_labels_out,
                "detections": sorted(
                    (
                        {
                            "ingredient_id": ing_id,
                            "confidence": round(b[0], 6),
                            "original_label": b[1],
                            "provenance": b[2],
                        }
                        for ing_id, b in best.items()
                    ),
                    key=lambda d: -d["confidence"],
                ),
            }
        )
    rows.sort(key=lambda r: r["image_id"])
    return rows, []


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--export", required=True, help="genuine Apple observation export (JSON)")
    ap.add_argument("--split", required=True, choices=["train", "validation"])
    ap.add_argument("--threshold", type=float, required=True)
    ap.add_argument("--record-floor", type=float, default=0.001)
    ap.add_argument("--out", required=True, help="output observations .jsonl.gz path")
    args = ap.parse_args()

    t0 = time.time()
    export = _load_export(Path(args.export))
    lex = IngredientLexicon()
    catalog = IngredientCatalogResolver()
    rows, failures = convert(export, args.split, args.threshold, args.record_floor, lex, catalog)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(out_path, "wt") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    failures_path = out_path.with_suffix("").with_suffix(".failures.jsonl")
    failures_path.write_text("".join(json.dumps(f) + "\n" for f in failures))
    meta = {
        "split": args.split,
        "source": "apple_device",
        "classifier": export.get("classifier", {"name": "unspecified"}),
        "label_space": "device_export",
        "absorbers": True,
        "crop_schedule": "device_export",
        "detection_threshold": args.threshold,
        "record_floor": args.record_floor,
        "images_observed": len(rows),
        "detections": sum(len(r["detections"]) for r in rows),
        "failures": len(failures),
        "elapsed_seconds": {"total_wall": round(time.time() - t0, 3)},
        "device": "n/a",
        "note": (
            "Converted from a genuine Apple device observation export by "
            "runner/apple_replay.py; no labels, probabilities, or detections "
            "were generated. Crop geometry and classifier behavior belong to "
            "the device; this adapter only applies the record floor, the "
            "ported resolution path, and the cross-crop dedup."
        ),
    }
    (out_path.with_suffix("").with_suffix(".meta.json")).write_text(json.dumps(meta, indent=1) + "\n")
    print(f"wrote {out_path}: {len(rows)} images, {meta['detections']} detections, {len(failures)} failures")


if __name__ == "__main__":
    main()
