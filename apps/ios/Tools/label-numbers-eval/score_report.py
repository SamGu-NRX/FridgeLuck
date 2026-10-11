#!/usr/bin/env python3
"""Score committed prediction files against the label-numbers corpus truth.

Two arms are scored from their committed prediction JSONL, each against its
own declared capability (the production whitelist is NOT imposed on the
strict baseline):
  production      the Swift replay of the production NutritionLabelParser.
                  Capability: energy_kcal (per_serving/per_portion),
                  serving_size, servings_per_container. The six other corpus
                  fields are marked unavailable — explicit missing coverage,
                  not an exclusion from the report.
  strict_baseline rigid line-anchored extractor. Capability: all nine fields
                  on the bases its patterns produce (EU per-100g/100ml/
                  portion declarations, US/CA per-serving lines).

Protocol (frozen before evaluation):
  - Development families: us_dual_column, ca_bilingual. Heldout families:
    eu_per100g, eu_per_portion. Per-arm metrics are split by frozen family.
  - Prior exposure is disclosed: all four families were examined during tool
    development (corpus generator, truth tables, production-gap measurements,
    and the strict baseline's patterns were all written after inspecting
    every family's line shapes). The heldout designation is frozen to keep
    future arm changes honest; it is NOT a clean held-out split, and metrics
    on heldout families are confirmatory.
  - Records the production keyword gate rejects are not part of its
    evaluation and are not scored as "untouched" probes: no comparison
    happens on them. They are excluded from every total and disclosed
    separately as gate_rejected_records / gate_rejected_formats.

Per-probe statuses (first match wins):
  unobservable      entry is not observable or has no value — never scored
  unavailable       the arm has no extractor for this field at all
  unavailable_basis the field is supported but this basis is not
  abstention        the arm attempted the record but returned no value for
                    the field (for production, parsed == null means the
                    whole record abstained)
  match / mismatch  value comparison (energy_kcal ±0.5, energy_kj ±2.0,
                    sodium_mg ±10, servings ±0.01, serving_size: normalized
                    whitespace/punctuation string)

Controls (diagnostics per arm, do not change the statuses above):
  unit_errors       mismatch where the predicted number equals the truth
                    under a unit conversion (kcal↔kJ ×4.184, mg↔g ×1000)
  basis_errors      mismatch where the predicted number equals a different
                    observable basis entry of the same field on the record
  false_abstentions abstentions on probes the companion arm matched —
                    values that were extractable from the committed text

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

SCHEMA = "label-numbers-report-v3"

STATUS_ORDER = [
    "match",
    "mismatch",
    "abstention",
    "unavailable_basis",
    "unavailable",
    "unobservable",
]

DEVELOPMENT_FAMILIES = ("us_dual_column", "ca_bilingual")
HELDOUT_FAMILIES = ("eu_per100g", "eu_per_portion")

PRODUCTION_FIELDS = {
    "energy_kcal": {"per_serving", "per_portion"},
    "serving_size": {None},
    "servings_per_container": {None},
}
STRICT_FIELDS = {
    "energy_kcal": {"per_serving", "per_100g", "per_100ml", "per_portion"},
    "energy_kj": {"per_100g", "per_100ml", "per_portion"},
    "fat_g": {"per_100g", "per_100ml", "per_portion"},
    "carbohydrate_g": {"per_100g", "per_100ml", "per_portion"},
    "protein_g": {"per_100g", "per_100ml", "per_portion"},
    "salt_g": {"per_100g", "per_100ml", "per_portion"},
    "sodium_mg": {"per_serving"},
    "serving_size": {None},
    "servings_per_container": {None},
}
ARMS = {"production": PRODUCTION_FIELDS, "strict_baseline": STRICT_FIELDS}

NUMERIC_TOLERANCE = {
    "energy_kcal": 0.5,
    "energy_kj": 2.0,
    "fat_g": 0.05,
    "carbohydrate_g": 0.05,
    "protein_g": 0.05,
    "salt_g": 0.05,
    "sodium_mg": 10.0,
    "servings_per_container": 0.01,
}
# (factor, tolerance): pred*factor ≈ truth or pred/factor ≈ truth counts as a
# unit error. energy_kcal: pred in kJ (×4.184); energy_kj: pred in kcal
# (÷4.184); sodium_mg: pred in g (×0.001) or a mg number off by ×1000.
UNIT_FACTORS = {
    "energy_kcal": (4.184, 0.5),
    "energy_kj": (1 / 4.184, 2.0),
    "sodium_mg": (0.001, 10.0),
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


def parse_truth(value) -> float:
    """Corpus truth strings: US/CA use dot decimals with comma thousands,
    EU tables use comma decimals — same semantics as the strict extractor."""
    token = str(value)
    if re.fullmatch(r"\d{1,3}(,\d{3})+", token):
        return float(token.replace(",", ""))
    if "," in token and "." not in token:
        return float(token.replace(",", "."))
    return float(token.replace(",", ""))


def prediction_value(arm: str, prediction: dict, field: str, basis: str | None):
    if arm == "production":
        if field == "energy_kcal":
            return prediction.get("calories_per_serving")
        if field == "serving_size":
            return prediction.get("serving_size")
        if field == "servings_per_container":
            return prediction.get("servings_per_container")
        return None
    key = f"{field}@{basis}" if basis else field
    return prediction.get("fields", {}).get(key)


def compare_value(field: str, value, truth: float) -> str:
    if field == "serving_size":
        return "match" if normalize_text(str(value)) == normalize_text(str(truth)) else "mismatch"
    tolerance = NUMERIC_TOLERANCE[field]
    return "match" if abs(value - truth) <= tolerance else "mismatch"


def evaluate_arm(arm: str, corpus: list[dict], predictions: list[dict]) -> dict:
    capability = ARMS[arm]
    by_id = {p["record_id"]: p for p in predictions}
    rows: list[dict] = []
    keyword_admitted = 0
    gate_rejected = 0
    gate_rejected_fv: dict[str, int] = {}

    for record in corpus:
        prediction = by_id.get(record["record_id"])
        if prediction is None:
            raise KeyError(f"no prediction for {record['record_id']}")
        family = record["family"]
        variant_kind = record["variant_kind"]
        fv_key = f"{family}|{variant_kind}"
        if arm == "production" and not prediction.get("keyword_positive", False):
            gate_rejected += 1
            gate_rejected_fv[fv_key] = gate_rejected_fv.get(fv_key, 0) + 1
            continue
        keyword_admitted += 1
        for key, entry in sorted(record["fields"].items()):
            field, _, basis = key.partition("@")
            basis = basis or None
            if not entry.get("observable") or entry.get("value") is None:
                status = "unobservable"
                value = None
                truth = None
            else:
                supported_bases = capability.get(field)
                if supported_bases is None:
                    status = "unavailable"
                    value = None
                    truth = entry["value"] if field == "serving_size" else parse_truth(entry["value"])
                elif basis not in supported_bases:
                    status = "unavailable_basis"
                    value = None
                    truth = entry["value"] if field == "serving_size" else parse_truth(entry["value"])
                else:
                    truth = entry["value"] if field == "serving_size" else parse_truth(entry["value"])
                    value = prediction_value(arm, prediction, field, basis)
                    if value is None:
                        status = "abstention"
                    else:
                        status = compare_value(field, value, truth)
            rows.append(
                {
                    "record_id": record["record_id"],
                    "family": family,
                    "variant_kind": variant_kind,
                    "field": field,
                    "basis": basis,
                    "unit": entry.get("unit"),
                    "status": status,
                    "value": value,
                    "truth": truth,
                    "record_fields": record["fields"],
                }
            )
    return {
        "rows": rows,
        "records": len(corpus),
        "keyword_admitted_records": keyword_admitted,
        "gate_rejected_records": gate_rejected,
        "gate_rejected_fv": gate_rejected_fv,
    }


def compute_controls(arm: str, evaluated: dict, other_rows: list[dict]) -> dict:
    other = {}
    for row in other_rows:
        other[(row["record_id"], row["field"], row["basis"])] = row
    unit_errors = 0
    basis_errors = 0
    false_abstentions = 0
    for row in evaluated["rows"]:
        if row["status"] == "abstention":
            counterpart = other.get((row["record_id"], row["field"], row["basis"]))
            if counterpart is not None and counterpart["status"] == "match":
                false_abstentions += 1
        elif row["status"] == "mismatch":
            value = row["value"]
            truth = row["truth"]
            factor, tolerance = UNIT_FACTORS.get(row["field"], (None, None))
            if factor is not None and (
                abs(value * factor - truth) <= tolerance or abs(value / factor - truth) <= tolerance
            ):
                unit_errors += 1
                continue
            record_fields = row["record_fields"]
            basis_error = False
            for key, entry in record_fields.items():
                other_field, _, other_basis = key.partition("@")
                if other_field != row["field"] or (other_basis or None) == row["basis"]:
                    continue
                if not entry.get("observable") or entry.get("value") is None:
                    continue
                if abs(value - parse_truth(entry["value"])) <= NUMERIC_TOLERANCE[row["field"]]:
                    basis_error = True
                    break
            if basis_error:
                basis_errors += 1
    return {"unit_errors": unit_errors, "basis_errors": basis_errors, "false_abstentions": false_abstentions}


def aggregate_rows(rows: list[dict]) -> tuple[dict, dict, dict, dict]:
    totals = blank_totals()
    by_fv: dict[str, dict] = {}
    by_field: dict[str, dict] = {}
    by_split = {"development": {"totals": blank_totals()}, "heldout": {"totals": blank_totals()}}
    for row in rows:
        status = row["status"]
        totals[status] += 1
        fv_key = f"{row['family']}|{row['variant_kind']}"
        fv_slot = by_fv.setdefault(fv_key, {"records": 0, "totals": blank_totals()})
        fv_slot["totals"][status] += 1
        unit = row["unit"] or "none"
        ub_key = f"{unit}|{row['basis'] or 'none'}"
        field_slot = by_field.setdefault(row["field"], {})
        ub_slot = field_slot.setdefault(ub_key, blank_totals())
        ub_slot[status] += 1
        split = "development" if row["family"] in DEVELOPMENT_FAMILIES else "heldout"
        by_split[split]["totals"][status] += 1
    totals["total"] = sum(totals[s] for s in STATUS_ORDER)
    for slot in by_split.values():
        slot["totals"]["total"] = sum(slot["totals"][s] for s in STATUS_ORDER)
    for fv_slot in by_fv.values():
        fv_slot["totals"]["total"] = sum(fv_slot["totals"][s] for s in STATUS_ORDER)
    return totals, by_fv, by_field, by_split


def build_arm_stats(arm: str, corpus: list[dict], predictions: list[dict], other_rows: list[dict]) -> dict:
    evaluated = evaluate_arm(arm, corpus, predictions)
    totals, by_fv, by_field, by_split = aggregate_rows(evaluated["rows"])
    fv_rejected = evaluated["gate_rejected_fv"]
    return {
        "capability_bases": {
            field: sorted(b or "none" for b in bases) for field, bases in ARMS[arm].items()
        },
        "records": evaluated["records"],
        "keyword_admitted_records": evaluated["keyword_admitted_records"],
        "gate_rejected_records": evaluated["gate_rejected_records"],
        "gate_rejected_formats": sorted(fv_rejected),
        "gate_rejected_by_family_variant": {k: fv_rejected[k] for k in sorted(fv_rejected)},
        "totals": totals,
        "by_split": by_split,
        "by_family_variant": {k: v for k, v in sorted(by_fv.items())},
        "by_field": {k: v for k, v in sorted(by_field.items())},
        "controls": compute_controls(arm, evaluated, other_rows),
    }


def build_report(corpus_path: Path, predictions: dict[str, Path]) -> dict:
    corpus = load_jsonl(corpus_path)
    preds_by_arm = {arm: load_jsonl(path) for arm, path in predictions.items()}
    rows_by_arm = {arm: evaluate_arm(arm, corpus, preds)["rows"] for arm, preds in preds_by_arm.items()}
    arms = {}
    prediction_meta = {}
    for arm, preds in preds_by_arm.items():
        other_arm = "strict_baseline" if arm == "production" else "production"
        arms[arm] = build_arm_stats(arm, corpus, preds, rows_by_arm[other_arm])
        prediction_meta[arm] = {
            "file": predictions[arm].name,
            "sha256": sha256_file(predictions[arm]),
            "records": len(preds),
        }
    unsupported = sorted(
        field
        for field in {key.partition("@")[0] for record in corpus for key in record["fields"]}
        if field not in PRODUCTION_FIELDS
    )
    return {
        "schema": SCHEMA,
        "protocol": {
            "frozen_families": {
                "development": list(DEVELOPMENT_FAMILIES),
                "heldout": list(HELDOUT_FAMILIES),
            },
            "prior_exposure": (
                "All four corpus families were examined during tool development "
                "(2026-10-10): the generator, truth tables, production-gap "
                "measurements, and the strict baseline patterns were all written "
                "after inspecting every family's line shapes. The development/"
                "heldout designation is frozen to keep future arm changes honest, "
                "but it is NOT a clean held-out split; metrics on heldout families "
                "are confirmatory, not discovery."
            ),
            "gate_rejected_note": (
                "Records the production keyword gate rejects are excluded from its "
                "evaluation totals and disclosed as gate_rejected_records and "
                "gate_rejected_formats. They are not scored as 'untouched' probes: "
                "no comparison happens on them, and they are not part of the "
                "evaluation pool."
            ),
        },
        "inputs": {
            "corpus": {
                "file": corpus_path.name,
                "sha256": sha256_file(corpus_path),
                "records": len(corpus),
            },
            "predictions": prediction_meta,
        },
        "unsupported_production_fields": unsupported,
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
        controls = report["arms"][arm]["controls"]
        print(
            f"{arm}: {summary} (total={totals['total']}; controls:"
            f" unit={controls['unit_errors']} basis={controls['basis_errors']}"
            f" false_abstention={controls['false_abstentions']})"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
