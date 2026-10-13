"""Presence-aware nutrient selection for USDA FoodData Central records.

The legacy extractor (`fetch_usda_ingredient_nutrition.py::nutrient_value`)
returned ``0.0`` for every nutrient it could not find, which silently turned
"missing measurement" into "genuine zero" (the seven zero-calorie Foundation
rows) and never validated units. This module is the shared, tested replacement:

- selection depends on *presence and validity*, never truthiness;
- a missing nutrient yields ``None`` (status ``missing``), never ``0.0``;
- units are checked before a value is accepted or converted;
- energy has an explicit kcal precedence across the four FDC energy
  variants (including the Atwater factors Foundation Foods publishes);
- the 4P+4C+9F Atwater estimate is a *diagnostic* helper only and is never
  returned as if it were a USDA observation.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Literal, Sequence

KJ_PER_KCAL = 4.184

# FDC energy nutrient variants, best-first. All values are kcal unless the
# unit says otherwise; 1062/268 is the kJ twin of 1008/208.
#   1008 (legacy number 208): "Energy" kcal
#   2048 (legacy number 958): "Energy (Atwater Specific Factors)" kcal
#   2047 (legacy number 957): "Energy (Atwater General Factors)" kcal
#   1062 (legacy number 268): "Energy" kJ
ENERGY_KCAL_PRECEDENCE: tuple[tuple[int, str], ...] = (
    (1008, "208"),
    (2048, "958"),
    (2047, "957"),
)
ENERGY_KJ_IDS: tuple[tuple[int, str], ...] = ((1062, "268"),)

MG_UNITS = {"mg", "milligram", "milligrams"}
G_UNITS = {"g", "gram", "grams"}
KCAL_UNITS = {"kcal", "calorie", "calories"}
KJ_UNITS = {"kj", "kilojoule", "kilojoules"}


@dataclass(frozen=True)
class MacroSpec:
    """Target spec for one canonical macro field."""

    ids: tuple[int, ...]
    unit: str = "g"  # unit the canonical field is stored in
    source_unit: str = "g"  # unit FDC publishes the nutrient in

    @property
    def id_set(self) -> frozenset[int]:
        return frozenset(self.ids)


MACRO_SPECS: dict[str, MacroSpec] = {
    "protein_g": MacroSpec(ids=(1003, 203)),
    "carbs_g": MacroSpec(ids=(1005, 205)),
    "fat_g": MacroSpec(ids=(1004, 204)),
    "fiber_g": MacroSpec(ids=(1079, 291)),
    "sugar_g": MacroSpec(ids=(2000, 269)),
    "sodium_g": MacroSpec(ids=(1093, 307), source_unit="mg"),
}

NutrientStatus = Literal["ok", "missing", "null_value", "unit_mismatch", "invalid_value"]


@dataclass(frozen=True)
class NutrientObservation:
    """One raw nutrient entry from an FDC record."""

    nutrient_id: int | None
    nutrient_number: str | None
    name: str
    unit: str
    amount: float | None
    data_points: int | None = None
    derivation_code: str | None = None


@dataclass(frozen=True)
class NutrientSelection:
    """Outcome of applying the selection policy to one macro field."""

    value: float | None
    unit: str | None  # storage unit when ok (g), else the offending unit
    nutrient_id: int | None
    nutrient_number: str | None
    status: NutrientStatus
    converted_from: str | None = None  # e.g. "kJ" or "mg"
    converted_factor: float | None = None


def collect_observations(food_nutrients: Sequence[Any]) -> list[NutrientObservation]:
    """Normalize the various FDC foodNutrient shapes into observations.

    Handles both the full-detail shape (``{"id": <food_nutrient row id>,
    "nutrient": {"id": 1008, "number": "208", ...}, "amount": ...}``) and the
    abridged shape (``{"nutrientId": 1008, "nutrientNumber": "208", ...}``).
    The top-level ``id`` of the full shape is a food_nutrient *row id*, not a
    nutrient id, and must never be matched against nutrient targets.
    """

    out: list[NutrientObservation] = []
    for entry in food_nutrients or []:
        if not isinstance(entry, dict):
            continue
        nested = entry.get("nutrient") if isinstance(entry.get("nutrient"), dict) else {}
        nutrient_id = _first_int(entry, "nutrientId", "nutrient_id") or _first_int(nested, "id")
        number = (
            _first_str(entry, "nutrientNumber", "nutrient_nbr", "nutrientNbr")
            or _first_str(nested, "number")
        )
        name = _first_str(entry, "nutrientName") or _first_str(nested, "name") or ""
        unit = _first_str(entry, "unitName") or _first_str(nested, "unitName") or ""
        amount = entry.get("amount", entry.get("value"))
        if isinstance(amount, str):
            try:
                amount = float(amount)
            except ValueError:
                amount = None
        if isinstance(amount, bool) or not isinstance(amount, (int, float)):
            amount = None
        data_points = _first_int(entry, "dataPoints", "data_points")
        derivation = _first_str(entry, "derivationCode") or _first_str(
            entry, "foodNutrientDerivation", "derivation"
        )
        out.append(
            NutrientObservation(
                nutrient_id=nutrient_id,
                nutrient_number=number,
                name=name,
                unit=unit.strip(),
                amount=amount,
                data_points=data_points,
                derivation_code=derivation,
            )
        )
    return out


def _first_int(payload: dict[str, Any], *keys: str) -> int | None:
    for key in keys:
        value = payload.get(key)
        if value is None:
            continue
        try:
            return int(value)
        except (TypeError, ValueError):
            continue
    return None


def _first_str(payload: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = payload.get(key)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return None


def _unit_in(unit: str, group: set[str]) -> bool:
    return unit.strip().lower() in group


def select_energy(observations: Sequence[NutrientObservation]) -> NutrientSelection:
    """Select stored energy (kcal) from the available FDC energy observations.

    Precedence (best first): 1008/208 kcal, 2048 Atwater Specific kcal,
    2047 Atwater General kcal, then 1062/268 kJ converted to kcal with an
    explicit recorded factor. A kJ conversion is flagged in the result so no
    caller can mistake it for a directly published kcal figure.
    """

    def _obs_for(ids: tuple[tuple[int, str], ...]) -> NutrientObservation | None:
        # Precedence order wins over payload order: scan candidate ids in
        # declared precedence, and only then the observation list for that id.
        # Scanning observations first would make selection depend on the
        # server's array order (e.g. an Atwater row ahead of 1008 in the
        # payload would silently outrank it).
        for target_id, _target_number in ids:
            for obs in observations:
                if obs.nutrient_id == target_id:
                    return obs
        return None

    for spec_ids in (ENERGY_KCAL_PRECEDENCE, ENERGY_KJ_IDS):
        obs = _obs_for(spec_ids)
        if obs is None:
            continue
        if obs.amount is None:
            return NutrientSelection(
                value=None, unit=obs.unit or None, nutrient_id=obs.nutrient_id,
                nutrient_number=obs.nutrient_number, status="null_value",
            )
        if not _unit_in(obs.unit, KCAL_UNITS | KJ_UNITS):
            return NutrientSelection(
                value=None, unit=obs.unit, nutrient_id=obs.nutrient_id,
                nutrient_number=obs.nutrient_number, status="unit_mismatch",
            )
        if not math.isfinite(obs.amount):
            return NutrientSelection(
                value=None, unit=obs.unit, nutrient_id=obs.nutrient_id,
                nutrient_number=obs.nutrient_number, status="invalid_value",
            )
        value = float(obs.amount)
        converted = None
        factor = None
        if _unit_in(obs.unit, KJ_UNITS):
            converted = "kJ"
            factor = 1.0 / KJ_PER_KCAL
            value = value / KJ_PER_KCAL
        return NutrientSelection(
            value=value, unit="kcal", nutrient_id=obs.nutrient_id,
            nutrient_number=obs.nutrient_number, status="ok",
            converted_from=converted, converted_factor=factor,
        )
    return NutrientSelection(
        value=None, unit=None, nutrient_id=None, nutrient_number=None, status="missing"
    )


def select_macro(field: str, observations: Sequence[NutrientObservation]) -> NutrientSelection:
    """Select one g-basis macro from FDC observations.

    Missing nutrients yield ``status="missing"`` with ``value=None`` — callers
    must not replace that with 0.0 on the storage path. Sodium is published in
    mg and converted to g with an explicit recorded factor.
    """

    spec = MACRO_SPECS[field]
    for obs in observations:
        if obs.nutrient_id not in spec.id_set:
            continue
        if obs.amount is None:
            return NutrientSelection(
                value=None, unit=obs.unit or None, nutrient_id=obs.nutrient_id,
                nutrient_number=obs.nutrient_number, status="null_value",
            )
        expected = G_UNITS if spec.source_unit == "g" else MG_UNITS
        if not _unit_in(obs.unit, expected):
            return NutrientSelection(
                value=None, unit=obs.unit, nutrient_id=obs.nutrient_id,
                nutrient_number=obs.nutrient_number, status="unit_mismatch",
            )
        if not math.isfinite(obs.amount):
            return NutrientSelection(
                value=None, unit=obs.unit, nutrient_id=obs.nutrient_id,
                nutrient_number=obs.nutrient_number, status="invalid_value",
            )
        value = float(obs.amount)
        converted = None
        factor = None
        if spec.source_unit == "mg" and _unit_in(obs.unit, MG_UNITS):
            converted = "mg"
            factor = 1.0 / 1000.0
            value = value / 1000.0
        return NutrientSelection(
            value=value, unit=spec.unit, nutrient_id=obs.nutrient_id,
            nutrient_number=obs.nutrient_number, status="ok",
            converted_from=converted, converted_factor=factor,
        )
    return NutrientSelection(
        value=None, unit=None, nutrient_id=None, nutrient_number=None, status="missing"
    )


def estimate_energy_kcal(protein_g: float, carbs_g: float, fat_g: float) -> float:
    """4P+4C+9F Atwater-general estimate.

    Diagnostic only: this is NOT a USDA observation and must never be written
    into a canonical macro field or shown as a verified figure.
    """

    return 4.0 * float(protein_g) + 4.0 * float(carbs_g) + 9.0 * float(fat_g)
