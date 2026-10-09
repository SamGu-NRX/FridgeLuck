"""Reference audit: compare the canonical catalog against FDC bulk evidence.

Policies (deliberate, documented):

- Tolerance. Bulk editions publish rounded values (3 significant digits is
  typical); the catalog was hydrated from API detail responses that may carry
  more precision. A catalog value is *verified* when it sits within half a
  publishing step of the reference value. Anything wider is a discrepancy.
- Genuine zero vs missing. A reference ``amount == 0`` verifies a stored zero.
  An absent (or null / wrong-unit / non-finite) reference observation is a
  macro gap: the stored 0.0 is a placeholder and the field is reported as
  unresolved — never silently refilled.
- Energy precedence. Stored energy must be a published USDA kcal observation
  (1008/208, then Atwater Specific 2048, then Atwater General 2047; 1062/268
  kJ converted with an explicit factor). Matching a lower-precedence
  observation is flagged as an alternate, not a discrepancy. The 4P+4C+9F
  estimate is computed for diagnostics only and never proposed as a
  correction.
- Edition hygiene. Every extract record carries its dataset edition; the
  report never blends edition drift with extraction bugs because corrections
  are only proposed against the selected observation of the record's own
  dataset edition.
"""

from __future__ import annotations

import csv
import math
from dataclasses import dataclass, field as dataclass_field
from pathlib import Path
from typing import Any

import orjson

from .nutrients import (
    MacroSpec,
    MACRO_SPECS,
    NutrientObservation,
    NutrientSelection,
    estimate_energy_kcal,
    select_energy,
    select_macro,
)

NUTRIENT_FIELDS: tuple[str, ...] = (
    "calories",
    "protein_g",
    "carbs_g",
    "fat_g",
    "fiber_g",
    "sugar_g",
    "sodium_g",
)

def published_tolerance(value: float, field: str) -> float:
    """Half-ulp of a 3-significant-digit published value, with a floor.

    The floor exists to absorb the catalog's own round(value, 4) storage
    rounding; it must stay far below the smallest 3-sig half-ulp relied on
    for comparisons.
    """

    our_rounding_floor = 5e-5
    if value == 0 or not math.isfinite(value):
        return our_rounding_floor
    exponent = math.floor(math.log10(abs(value)))
    ulp = 10.0 ** (exponent - 2)
    return max(ulp / 2.0, our_rounding_floor)


@dataclass
class NutrientFinding:
    nutrient: str
    catalog_value: float
    reference_value: float | None
    delta: float | None
    tolerance: float
    status: str
    reference_id: int | None = None
    reference_number: str | None = None
    reference_name: str = ""
    reference_unit: str = ""
    converted_from: str | None = None
    estimate_kcal: float | None = None
    note: str = ""

    def to_json(self) -> dict[str, Any]:
        return dict(self.__dict__)


@dataclass
class RecordFinding:
    fdc_id: int
    display_name: str
    catalog_data_type: str
    reference_data_type: str | None
    source_dataset: str | None
    source_edition: str | None
    publication_date: str | None
    description_match: bool | None
    description: str | None
    food_category_match: bool | None
    findings: list[NutrientFinding] = dataclass_field(default_factory=list)
    flags: list[str] = dataclass_field(default_factory=list)
    verdict: str = ""

    def to_json(self) -> dict[str, Any]:
        payload = dict(self.__dict__)
        payload["findings"] = [f.to_json() for f in self.findings]
        return payload


@dataclass
class AuditResult:
    records: list[RecordFinding]
    verdict_counts: dict[str, int]
    missing_reference_ids: list[int]
    per_nutrient_stats: dict[str, dict[str, Any]]
    estimate_stats: dict[str, Any]
    proposals: list[dict[str, Any]]

    def to_json(self) -> dict[str, Any]:
        return {
            "records": [r.to_json() for r in self.records],
            "verdict_counts": self.verdict_counts,
            "missing_reference_ids": self.missing_reference_ids,
            "per_nutrient_stats": self.per_nutrient_stats,
            "estimate_stats": self.estimate_stats,
            "proposals": self.proposals,
        }


def _observations_from_extract(record: dict[str, Any]) -> list[NutrientObservation]:
    out: list[NutrientObservation] = []
    for entry in record.get("nutrients") or []:
        out.append(
            NutrientObservation(
                nutrient_id=entry.get("id"),
                nutrient_number=str(entry.get("number") or "") or None,
                name=str(entry.get("name") or ""),
                unit=str(entry.get("unit") or ""),
                amount=entry.get("amount"),
                data_points=entry.get("data_points"),
                derivation_code=str(entry.get("derivation_code") or "") or None,
            )
        )
    return out


def _normalized_text(value: str) -> str:
    return " ".join(value.strip().lower().split())


def _audit_energy(
    catalog_value: float, observations: list[NutrientObservation]
) -> NutrientFinding:
    selected: NutrientSelection = select_energy(observations)

    estimate = None
    # Alternate-observation match: does the catalog value equal ANY published
    # kcal/kJ energy observation under the same tolerance rules?
    for obs in observations:
        if obs.nutrient_id not in {1008, 208, 2047, 2048, 1062, 268}:
            continue
        if obs.amount is None or not math.isfinite(obs.amount):
            continue
        obs_kcal = obs.amount / 4.184 if obs.unit.strip().lower() in {"kj", "kilojoule", "kilojoules"} else obs.amount
        tolerance = published_tolerance(obs_kcal, "calories")
        if abs(catalog_value - obs_kcal) <= tolerance:
            is_selected = selected.status == "ok" and obs.nutrient_id == selected.nutrient_id
            status = "verified" if is_selected else "verified_alternate_observation"
            return NutrientFinding(
                nutrient="calories",
                catalog_value=catalog_value,
                reference_value=obs_kcal,
                delta=round(catalog_value - obs_kcal, 6),
                tolerance=tolerance,
                status=status,
                reference_id=obs.nutrient_id,
                reference_number=obs.nutrient_number,
                reference_name=obs.name,
                reference_unit=obs.unit,
                converted_from="kJ" if obs.unit.strip().lower() in {"kj", "kilojoule", "kilojoules"} else None,
                note="" if is_selected else "catalog matches a published energy observation with lower selection precedence",
            )

    if selected.status != "ok":
        statuses = {
            "missing": "missing_in_reference",
            "null_value": "reference_null_value",
            "unit_mismatch": "reference_unit_mismatch",
            "invalid_value": "reference_invalid_value",
        }
        return NutrientFinding(
            nutrient="calories",
            catalog_value=catalog_value,
            reference_value=None,
            delta=None,
            tolerance=published_tolerance(0.0, "calories"),
            status=statuses[selected.status],
            reference_id=selected.nutrient_id,
            reference_number=selected.nutrient_number,
            reference_name="",
            reference_unit=selected.unit or "",
            note="no usable published energy observation in the reference edition",
        )

    tolerance = published_tolerance(selected.value or 0.0, "calories")
    delta = catalog_value - (selected.value or 0.0)
    return NutrientFinding(
        nutrient="calories",
        catalog_value=catalog_value,
        reference_value=selected.value,
        delta=round(delta, 6),
        tolerance=tolerance,
        status="discrepancy_correctable" if abs(delta) > tolerance else "verified",
        reference_id=selected.nutrient_id,
        reference_number=selected.nutrient_number,
        reference_name="Energy",
        reference_unit="kcal",
        converted_from=selected.converted_from,
        estimate_kcal=estimate,
    )


def _audit_macro(
    nutrient: str, catalog_value: float, observations: list[NutrientObservation]
) -> NutrientFinding:
    spec: MacroSpec = MACRO_SPECS[nutrient]
    selected = select_macro(nutrient, observations)
    if selected.status != "ok":
        statuses = {
            "missing": "missing_in_reference",
            "null_value": "reference_null_value",
            "unit_mismatch": "reference_unit_mismatch",
            "invalid_value": "reference_invalid_value",
        }
        return NutrientFinding(
            nutrient=nutrient,
            catalog_value=catalog_value,
            reference_value=None,
            delta=None,
            tolerance=published_tolerance(0.0, nutrient),
            status=statuses[selected.status],
            reference_id=selected.nutrient_id,
            reference_number=selected.nutrient_number,
            reference_unit=selected.unit or "",
            note="no usable published observation in the reference edition",
        )

    reference = selected.value or 0.0
    tolerance = published_tolerance(reference, nutrient)
    delta = catalog_value - reference
    if reference == 0.0 and abs(delta) <= tolerance:
        status = "genuine_zero"
    elif abs(delta) <= tolerance:
        status = "verified"
    else:
        status = "discrepancy_correctable"
    return NutrientFinding(
        nutrient=nutrient,
        catalog_value=catalog_value,
        reference_value=reference,
        delta=round(delta, 6),
        tolerance=tolerance,
        status=status,
        reference_id=selected.nutrient_id,
        reference_number=selected.nutrient_number,
        reference_name="",
        reference_unit=selected.unit or "",
        converted_from=selected.converted_from,
    )


def audit_catalog(
    catalog_records: list[dict[str, Any]],
    extract: dict[str, Any],
    *,
    source_archive_sha256: dict[str, str] | None = None,
) -> AuditResult:
    by_fdc: dict[int, dict[str, Any]] = {
        int(r["fdc_id"]): r for r in extract.get("records", [])
    }
    records: list[RecordFinding] = []
    missing_reference_ids: list[int] = []

    for row in catalog_records:
        fdc_id = int(row["fdc_id"])
        macros = row["macros"]
        reference = by_fdc.get(fdc_id)
        finding = RecordFinding(
            fdc_id=fdc_id,
            display_name=row.get("display_name", ""),
            catalog_data_type=row.get("source_meta", {}).get("data_type", ""),
            reference_data_type=None,
            source_dataset=None,
            source_edition=None,
            publication_date=None,
            description_match=None,
            description=None,
            food_category_match=None,
        )
        if reference is None:
            missing_reference_ids.append(fdc_id)
            finding.verdict = "missing_reference"
            finding.flags.append("no_record_in_reference_extracts")
            for nutrient in NUTRIENT_FIELDS:
                finding.findings.append(
                    NutrientFinding(
                        nutrient=nutrient,
                        catalog_value=float(macros.get(nutrient) or 0.0),
                        reference_value=None,
                        delta=None,
                        tolerance=published_tolerance(0.0, nutrient),
                        status="missing_in_reference",
                        note="fdc_id absent from the reference edition extracts",
                    )
                )
            records.append(finding)
            continue

        observations = _observations_from_extract(reference)
        finding.reference_data_type = reference.get("data_type") or None
        finding.source_dataset = reference.get("source_dataset")
        finding.source_edition = reference.get("source_edition")
        finding.publication_date = reference.get("publication_date") or None
        finding.description = reference.get("description") or None

        ref_description = _normalized_text(reference.get("description") or "")
        catalog_description = _normalized_text(row.get("source_description") or "")
        finding.description_match = ref_description == catalog_description
        if not finding.description_match:
            finding.flags.append("identity_description_drift")
        finding.food_category_match = _normalized_text(
            reference.get("food_category") or ""
        ) == _normalized_text(row.get("source_meta", {}).get("food_category") or "")
        if not finding.food_category_match:
            finding.flags.append("food_category_drift")
        if finding.catalog_data_type != (reference.get("data_type") or ""):
            finding.flags.append("data_type_mismatch")

        for nutrient in NUTRIENT_FIELDS:
            catalog_value = float(macros.get(nutrient) or 0.0)
            if nutrient == "calories":
                nf = _audit_energy(catalog_value, observations)
            else:
                nf = _audit_macro(nutrient, catalog_value, observations)
            nf.estimate_kcal = None
            finding.findings.append(nf)

        estimate = estimate_energy_kcal(
            float(macros.get("protein_g") or 0.0),
            float(macros.get("carbs_g") or 0.0),
            float(macros.get("fat_g") or 0.0),
        )
        for nf in finding.findings:
            if nf.nutrient == "calories":
                nf.estimate_kcal = round(estimate, 4)

        statuses = {f.status for f in finding.findings}
        if "discrepancy_correctable" in statuses:
            finding.verdict = "discrepancy"
        elif not finding.description_match:
            # Wrong-row risk outranks incompleteness: an identity mismatch
            # questions every value in the record, while gaps question only
            # the fields the reference edition omits.
            finding.verdict = "identity_drift"
        elif statuses & {"reference_null_value", "reference_unit_mismatch", "reference_invalid_value"}:
            finding.verdict = "unresolved_reference_problem"
        elif "missing_in_reference" in statuses:
            finding.verdict = "verified_with_gaps"
            finding.flags.append("macro_gap:" + ",".join(
                f.nutrient for f in finding.findings if f.status == "missing_in_reference"
            ))
        else:
            finding.verdict = "verified"
        records.append(finding)

    verdict_counts: dict[str, int] = {}
    for r in records:
        verdict_counts[r.verdict] = verdict_counts.get(r.verdict, 0) + 1

    per_nutrient_stats = _per_nutrient_stats(records)
    estimate_stats = _estimate_stats(records)
    proposals = _build_proposals(records, source_archive_sha256 or {})

    return AuditResult(
        records=records,
        verdict_counts=verdict_counts,
        missing_reference_ids=missing_reference_ids,
        per_nutrient_stats=per_nutrient_stats,
        estimate_stats=estimate_stats,
        proposals=proposals,
    )


def _per_nutrient_stats(records: list[RecordFinding]) -> dict[str, dict[str, Any]]:
    stats: dict[str, dict[str, Any]] = {}
    for r in records:
        data_type = r.catalog_data_type or "unknown"
        for f in r.findings:
            key = f"{data_type}/{f.nutrient}"
            bucket = stats.setdefault(
                key,
                {
                    "data_type": data_type,
                    "nutrient": f.nutrient,
                    "n_records": 0,
                    "n_verified": 0,
                    "n_genuine_zero": 0,
                    "n_alternate_observation": 0,
                    "n_discrepancy": 0,
                    "n_missing_in_reference": 0,
                    "n_reference_problem": 0,
                    "mae_over_compared": 0.0,
                    "max_abs_delta": 0.0,
                    "sum_abs_delta": 0.0,
                },
            )
            bucket["n_records"] += 1
            if f.status == "verified":
                bucket["n_verified"] += 1
            elif f.status == "genuine_zero":
                bucket["n_genuine_zero"] += 1
            elif f.status == "verified_alternate_observation":
                bucket["n_alternate_observation"] += 1
            elif f.status == "discrepancy_correctable":
                bucket["n_discrepancy"] += 1
            elif f.status == "missing_in_reference":
                bucket["n_missing_in_reference"] += 1
            else:
                bucket["n_reference_problem"] += 1
            if f.delta is not None and f.status not in {"missing_in_reference", "reference_null_value", "reference_unit_mismatch", "reference_invalid_value"}:
                bucket["n_compared"] = bucket.get("n_compared", 0) + 1
                bucket["sum_abs_delta"] += abs(f.delta)
                bucket["max_abs_delta"] = max(bucket["max_abs_delta"], abs(f.delta))
    for bucket in stats.values():
        compared = bucket.pop("n_compared", 0) or 1
        bucket["mae_over_compared"] = round(bucket.pop("sum_abs_delta") / compared, 6)
        bucket["max_abs_delta"] = round(bucket["max_abs_delta"], 6)
    return stats


def _estimate_stats(records: list[RecordFinding]) -> dict[str, Any]:
    diffs: list[float] = []
    over_ten_pct = 0
    for r in records:
        for f in r.findings:
            if f.nutrient != "calories" or f.estimate_kcal is None:
                continue
            if f.status not in {"verified", "verified_alternate_observation", "genuine_zero", "discrepancy_correctable"}:
                continue
            reference = f.reference_value
            if reference is None:
                continue
            diff = abs(f.estimate_kcal - reference)
            diffs.append(diff)
            if reference > 0 and diff / max(reference, 1.0) > 0.10:
                over_ten_pct += 1
    if not diffs:
        return {"n_compared": 0}
    return {
        "n_compared": len(diffs),
        "mean_abs_estimate_vs_usda_kcal": round(sum(diffs) / len(diffs), 3),
        "max_abs_estimate_vs_usda_kcal": round(max(diffs), 3),
        "pct_estimate_off_by_more_than_10pct": round(100.0 * over_ten_pct / len(diffs), 2),
        "note": "4P+4C+9F estimate used as a diagnostic only; never stored as calories",
    }


def _build_proposals(
    records: list[RecordFinding], archive_hashes: dict[str, str]
) -> list[dict[str, Any]]:
    proposals: list[dict[str, Any]] = []
    for r in records:
        if r.verdict != "discrepancy":
            continue
        for f in r.findings:
            if f.status != "discrepancy_correctable":
                continue
            dataset = r.source_dataset or ""
            proposals.append(
                {
                    "fdc_id": r.fdc_id,
                    "display_name": r.display_name,
                    "field": f.nutrient,
                    "old_value": f.catalog_value,
                    "new_value": f.reference_value,
                    "reference_nutrient_id": f.reference_id,
                    "reference_nutrient_number": f.reference_number,
                    "reference_name": f.reference_name,
                    "reference_unit": f.reference_unit,
                    "converted_from": f.converted_from,
                    "edition": r.source_edition,
                    "archive_sha256": archive_hashes.get(dataset, ""),
                    "publication_date": r.publication_date,
                    "basis": "per_100g",
                }
            )
    return proposals


def write_audit_csv(records: list[RecordFinding], path: Path) -> None:
    header = [
        "fdc_id", "display_name", "data_type", "reference_dataset", "reference_edition",
        "publication_date", "identity_description_match", "food_category_match",
    ]
    for nutrient in NUTRIENT_FIELDS:
        header += [
            f"{nutrient}_catalog", f"{nutrient}_reference", f"{nutrient}_delta",
            f"{nutrient}_tolerance", f"{nutrient}_status", f"{nutrient}_ref_nutrient_id",
            f"{nutrient}_ref_unit", f"{nutrient}_converted_from", f"{nutrient}_estimate_kcal",
        ]
    header += ["energy_estimate_kcal", "verdict", "flags"]

    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL, lineterminator="\r\n")
        writer.writerow(header)
        for r in records:
            row: list[Any] = [
                r.fdc_id, r.display_name, r.catalog_data_type, r.source_dataset or "",
                r.source_edition or "", r.publication_date or "",
                "" if r.description_match is None else r.description_match,
                "" if r.food_category_match is None else r.food_category_match,
            ]
            energy_estimate = ""
            for f in r.findings:
                if f.nutrient == "calories" and f.estimate_kcal is not None:
                    energy_estimate = f.estimate_kcal
                row += [
                    f.catalog_value,
                    "" if f.reference_value is None else f.reference_value,
                    "" if f.delta is None else f.delta,
                    f.tolerance,
                    f.status,
                    "" if f.reference_id is None else f.reference_id,
                    f.reference_unit,
                    f.converted_from or "",
                    "" if f.estimate_kcal is None else f.estimate_kcal,
                ]
            row += [energy_estimate, r.verdict, ";".join(r.flags)]
            writer.writerow(row)


def load_audit(path: Path) -> dict[str, Any]:
    return orjson.loads(path.read_bytes())
