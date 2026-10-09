"""Controlled application of source-supported macro corrections.

The catalog macro-freeze rejects macro edits during batch review. This module
is the documented exception path for reference-audit corrections:

- every correction is re-derived from the committed reference extract at
  apply time (evidence is checked, not trusted from the audit run);
- a correction is refused when the canonical value drifted since the audit,
  when the extract no longer supports the value, or the fdc_id is unknown;
- corrected and gap rows carry provenance in ``source_meta``
  (``reference_edition``, ``macro_gaps``, ``macro_freeze_exception``);
- nothing here touches the bundled SQLite build step, installed app
  databases, or meal-history snapshots — the SQLite rebuild is a separate,
  explicitly invoked step and the app never re-scores stored history.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Any

import orjson

from .io import load_canonical, save_canonical
from .nutrients import MACRO_SPECS, collect_observations, select_energy, select_macro
from .reference_audit import NUTRIENT_FIELDS, published_tolerance
from .utils import utc_now_iso

GAP_STATUSES = {"missing_in_reference", "reference_null_value", "reference_unit_mismatch", "reference_invalid_value"}


def load_corrections(path: Path) -> list[dict[str, Any]]:
    payload = orjson.loads(path.read_bytes())
    if isinstance(payload, dict):
        payload = payload.get("corrections", [])
    if not isinstance(payload, list):
        raise ValueError("corrections file must be a JSON array (or {corrections: [...]})")
    return payload


def _derive_reference(
    extract_records: list[dict[str, Any]], fdc_id: int, nutrient: str
) -> tuple[str, Any]:
    """Return (status, derived_value|None) for one field from the extract."""

    record = next((r for r in extract_records if int(r["fdc_id"]) == fdc_id), None)
    if record is None:
        return "missing_reference", None
    observations = collect_observations(
        [
            {
                "nutrientId": n.get("id"),
                "nutrientNumber": n.get("number"),
                "nutrientName": n.get("name"),
                "unitName": n.get("unit"),
                "amount": n.get("amount"),
                "dataPoints": n.get("data_points"),
            }
            for n in record.get("nutrients") or []
        ]
    )
    if nutrient == "calories":
        selection = select_energy(observations)
    else:
        selection = select_macro(nutrient, observations)
    if selection.status != "ok":
        return f"evidence_{selection.status}", None
    return "ok", selection.value


def apply_reference_corrections(
    canonical_path: Path,
    extract_path: Path,
    corrections_path: Path,
    *,
    verified_at_utc: str | None = None,
) -> dict[str, Any]:
    catalog = load_canonical(canonical_path)
    extract = orjson.loads(extract_path.read_bytes())
    extract_records = extract.get("records", [])
    corrections = load_corrections(corrections_path)
    stamp_time = verified_at_utc or utc_now_iso()

    rows_by_fdc = {row.fdc_id: row for row in catalog.records}
    applied: list[dict[str, Any]] = []
    refused: list[dict[str, Any]] = []
    touched: set[int] = set()

    for correction in corrections:
        fdc_id = int(correction["fdc_id"])
        nutrient = str(correction["field"])
        new_value = float(correction["new_value"])
        if nutrient not in NUTRIENT_FIELDS:
            refused.append({**correction, "reason": "unknown_field"})
            continue
        row = rows_by_fdc.get(fdc_id)
        if row is None:
            refused.append({**correction, "reason": "unknown_fdc_id"})
            continue
        status, derived = _derive_reference(extract_records, fdc_id, nutrient)
        if status != "ok" or derived is None:
            refused.append({**correction, "reason": status})
            continue
        tolerance = published_tolerance(derived, nutrient)
        if not math.isfinite(new_value) or abs(new_value - derived) > tolerance:
            refused.append(
                {**correction, "reason": "evidence_value_mismatch", "derived_value": derived}
            )
            continue
        current = float(getattr(row.macros, nutrient))
        if abs(current - float(correction.get("old_value", current))) > 1e-9:
            refused.append({**correction, "reason": "canonical_value_drifted", "current_value": current})
            continue

        setattr(row.macros, nutrient, round(new_value, 4))
        touched.add(fdc_id)
        applied.append(
            {
                "fdc_id": fdc_id,
                "field": nutrient,
                "old_value": current,
                "new_value": round(new_value, 4),
                "reference_nutrient_id": correction.get("reference_nutrient_id"),
                "reference_name": correction.get("reference_name"),
                "converted_from": correction.get("converted_from"),
                "edition": correction.get("edition"),
                "note": correction.get("note", ""),
            }
        )

    # Stamp provenance on touched rows plus any row whose extract selection
    # shows a gap or reference problem (informative placeholders).
    extract_by_fdc = {int(r["fdc_id"]): r for r in extract_records}
    for row in catalog.records:
        needs_stamp = row.fdc_id in touched
        gaps: list[str] = []
        reference = extract_by_fdc.get(row.fdc_id)
        if reference is not None:
            observations = collect_observations(
                [
                    {
                        "nutrientId": n.get("id"),
                        "nutrientNumber": n.get("number"),
                        "nutrientName": n.get("name"),
                        "unitName": n.get("unit"),
                        "amount": n.get("amount"),
                        "dataPoints": n.get("data_points"),
                    }
                    for n in reference.get("nutrients") or []
                ]
            )
            for nutrient in NUTRIENT_FIELDS:
                if nutrient == "calories":
                    status, _ = _derive_reference(extract_records, row.fdc_id, nutrient)
                else:
                    selection = select_macro(nutrient, observations)
                    status = "ok" if selection.status == "ok" else f"evidence_{selection.status}"
                if status != "ok" and status != "missing_reference":
                    gaps.append(nutrient)
                if status != "ok":
                    needs_stamp = True
        if not needs_stamp:
            continue
        row.source_meta.reference_edition = (
            str(reference.get("source_edition")) if reference else row.source_meta.reference_edition
        )
        if gaps:
            row.source_meta.macro_gaps = gaps
        if row.fdc_id in touched:
            row.source_meta.macro_freeze_exception = (
                "Reference-audit correction: value re-derived from the committed FDC bulk "
                "extract (see scripts/data/reference/MANIFEST.json); sanctioned macro-freeze exception."
            )
        row.source_meta.verified_at_utc = stamp_time

    save_canonical(canonical_path, catalog)
    return {
        "applied": applied,
        "refused": refused,
        "n_applied": len(applied),
        "n_refused": len(refused),
        "n_rows_stamped": len(touched),
        "applied_at_utc": stamp_time,
    }
