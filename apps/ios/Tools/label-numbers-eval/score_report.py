#!/usr/bin/env python3
"""Score committed prediction files against the label-numbers corpus truth.

Two arms are scored identically from their committed prediction JSONL:
  production      the Swift replay of the production NutritionLabelParser
                  (reports/replay_predictions.jsonl, dumped by
                  `swift run label-numbers-replay --predictions <file>`)
  strict_baseline the rigid line-anchored extractor (reports/strict_predictions.jsonl,
                  written by strict_baseline.py)

Every truth entry is a probe. A production calorie number is compared against
each observable serving-like basis entry separately (matching per_serving and
missing per_package are two honest outcomes of one number). Status assignment
per entry, first match wins:
  unobservable      entry is not observable or has no value — never scored
  unavailable       the arm has no extractor for this field at all
                    (production supports only energy_kcal, serving_size,
                    servings_per_container; the other six corpus fields are
                    marked unavailable rather than scored as abstentions)
  unavailable_basis the field is supported but this basis is not (e.g.
                    energy_kcal@per_100g: the production parser has no
                    per-100g interpretation)
  untouched         record was keyword-positive-gated out (production keyword
                    gate only; the strict arm has no gate) — no attempt made
  abstention        the arm attempted the record but returned no value for
                    the field (for production, parsed == null means the
                    whole record abstained, including serving size and
                    servings per container)
  match / mismatch  value comparison
                    (energy_kcal tolerance 0.5; servings_per_container 0.01;
                    serving_size: whitespace/punctuation-normalized string)

Writes reports/report.json (canonical JSON: sort_keys, indent 2). All
counters are integers so the committed bytes are stable across runs;
verify_report.py recomputes and byte-compares.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

SCHEMA = "label-numbers-report-v2"

STATUS_ORDER = [
    "match",
    "mismatch",
    "abstention",
    "untouched",
    "unavailable_basis",
    "unavailable",
    "unobservable",
]

PRODUCTION_FIELDS = {
    # field -> bases the arm can produce values for (None = basis-less)
    "energy_kcal": {"per_serving", "per_portion"},
    "serving_size": {None},
    "servings_per_container": {None},
}
STATUS_KEYS = {s: 0 for s in STATUS_ORDER}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize_text(text: str) -> str:
    collapsed = re.sub(r"\s+", " ", text.lower()).strip()
    return collapsed.strip(" :;,.")


def blank_totals() -> dict:
    return dict(STATUS_KEYS)


def load_jsonl(path: Path) -> list[dict]:
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    return rows


def score_entry(arm: str, field: str, basis: str | None, entry: dict, prediction: dict) -> str:
    if not entry.get("observable") or entry.get("value") is None:
        return "unobservable"
    supported_bases = PRODUCTION_FIELDS.get(field)
    if supported_bases is None:
        return "unavailable"
    if basis not in supported_bases:
        return "unavailable_basis"
    if arm == "production" and not prediction.get("keyword_positive", False):
        return "untouched"
    if field == "energy_kcal":
        value = prediction.get("calories_per_serving")
        truth = float(str(entry["value"]).replace(",", ""))
        if value is None:
            return "abstention"
        return "match" if abs(value - truth) <= 0.5 else "mismatch"
    if field == "servings_per_container":
        value = prediction.get("servings_per_container")
        truth = float(str(entry["value"]).replace(",", ""))
        if value is None:
            return "abstention"
        return "match" if abs(value - truth) <= 0.01 else "mismatch"
    if field == "serving_size":
        value = prediction.get("serving_size")
        if value is None:
            return "abstention"
        return "match" if normalize_text(value) == normalize_text(str(entry["value"])) else "mismatch"
    raise AssertionError(f"unreachable field {field}")


def score_arm(arm: str, corpus: list[dict], predictions: list[dict]) -> dict:
    by_id = {p["record_id"]: p for p in predictions}
    totals = blank_totals()
    by_family_variant: dict[str, dict] = {}
    by_field: dict[str, dict] = {}
    untouched_records = 0
    keyword_positive_records = 0

    for record in corpus:
        prediction = by_id.get(record["record_id"])
        if prediction is None:
            raise KeyError(f"no prediction for {record['record_id']}")
        fv_key = f"{record['family']}|{record['variant_kind']}"
        slot = by_family_variant.setdefault(
            fv_key,
            {
                "records": 0,
                "untouched_records": 0,
                "keyword_positive_records": 0,
                "totals": blank_totals(),
            },
        )
        slot["records"] += 1
        if prediction.get("keyword_positive"):
            keyword_positive_records += 1
            slot["keyword_positive_records"] += 1
        else:
            untouched_records += 1
            slot["untouched_records"] += 1

        for key, entry in sorted(record["fields"].items()):
            field, _, basis = key.partition("@")
            status = score_entry(arm, field, basis or None, entry, prediction)
            totals[status] += 1
            slot["totals"][status] += 1
            unit = entry.get("unit") or "none"
            ub_key = f"{unit}|{basis or 'none'}"
            field_slot = by_field.setdefault(field, {})
            ub_slot = field_slot.setdefault(ub_key, blank_totals())
            ub_slot[status] += 1

    totals["total"] = sum(totals[s] for s in STATUS_ORDER)
    arm_stats: dict = {
        "totals": totals,
        "records": len(corpus),
        "untouched_records": untouched_records,
        "by_family_variant": {},
        "by_field": by_field,
    }
    if arm == "production":
        arm_stats["keyword_positive_records"] = keyword_positive_records
    for fv_key, fv_slot in by_family_variant.items():
        fv_slot["totals"]["total"] = sum(fv_slot["totals"][s] for s in STATUS_ORDER)
        arm_stats["by_family_variant"][fv_key] = fv_slot
    return arm_stats


def untouched_formats(corpus: list[dict], predictions: list[dict]) -> list[str]:
    by_id = {p["record_id"]: p for p in predictions}
    counts: dict[str, list[int]] = {}
    for record in corpus:
        prediction = by_id[record["record_id"]]
        key = f"{record['family']}|{record['variant_kind']}"
        slot = counts.setdefault(key, [0, 0])
        slot[1] += 1
        if not prediction.get("keyword_positive", False):
            slot[0] += 1
    return sorted(key for key, (untouched, total) in counts.items() if untouched == total)


def build_report(corpus_path: Path, predictions: dict[str, Path]) -> dict:
    corpus = load_jsonl(corpus_path)
    arms = {}
    prediction_meta = {}
    for arm, path in predictions.items():
        rows = load_jsonl(path)
        arms[arm] = score_arm(arm, corpus, rows)
        prediction_meta[arm] = {
            "file": path.name,
            "sha256": sha256_file(path),
            "records": len(rows),
        }
    unsupported = sorted(
        field
        for field in {key.partition("@")[0] for record in corpus for key in record["fields"]}
        if field not in PRODUCTION_FIELDS
    )
    return {
        "schema": SCHEMA,
        "inputs": {
            "corpus": {
                "file": corpus_path.name,
                "sha256": sha256_file(corpus_path),
                "records": len(corpus),
            },
            "predictions": prediction_meta,
        },
        "unsupported_production_fields": unsupported,
        "untouched_formats_production": untouched_formats(corpus, load_jsonl(predictions["production"])),
        "arms": arms,
    }


def canonical_json(report: dict) -> str:
    return json.dumps(report, sort_keys=True, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--corpus", default="corpus/labels.jsonl")
    ap.add_argument("--production", default="reports/replay_predictions.jsonl")
    ap.add_argument("--strict", default="reports/strict_predictions.jsonl")
    ap.add_argument("--out", default="reports/report.json")
    args = ap.parse_args()

    report = build_report(
        Path(args.corpus),
        {"production": Path(args.production), "strict_baseline": Path(args.strict)},
    )
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(canonical_json(report), encoding="utf-8")
    for arm in ("production", "strict_baseline"):
        totals = report["arms"][arm]["totals"]
        summary = ", ".join(f"{s}={totals[s]}" for s in STATUS_ORDER)
        print(f"{arm}: {summary} (total={totals['total']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
