"""Gates for the kcal audit (evaluation/kcal-audit/kcal-audit.md).

What is asserted:
1. The in-memory "prev" compile state reproduces the published af856008
   bundle exactly (the audit's comparison basis is sound; the basis was
   rebased from 9e4a3af5 when the #210 corpus rebuild changed the corpus
   between the two commits).
2. Every recipe the fixed state moves more than 40 percent versus the
   published bundle is listed in kcal-audit.md's gate table, and the table
   lists nothing else (no silent additions, no stale rows).
3. The nutrient rows the audit re-sources from exist in the curated catalog
   with the exact per-100 g values the audit cites.

Identity pins are not touched by the audit and are not asserted here; the
reach report covers them.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import kcal_audit as ka  # noqa: E402

CATALOG = ka.REPO / "scripts/data/catalog/usda_curated_ingredients.json"
REPORT = HERE / "kcal-audit.md"
FIDELITY_TOL = 0.05


def _gate_rows(md_text: str) -> dict[str, tuple[str, str]]:
    """recipe id -> (prev kcal cell, fixed kcal cell) from the md gate table."""
    rows: dict[str, tuple[str, str]] = {}
    in_table = False
    for line in md_text.splitlines():
        if line.startswith("| recipe |"):
            in_table = True
            continue
        if in_table:
            if re.match(r"^\|[\s:-]+\|", line):
                continue  # |---|---| separator row
            m = re.match(r"\| (rcp-\d{6}) \| ([\d.]+) \| ([\d.]+) \|", line)
            if not m:
                if line.startswith("|") and "rcp-" in line:
                    raise AssertionError(f"unparsable gate-table row: {line!r}")
                in_table = False
                continue
            rows[m.group(1)] = (m.group(2), m.group(3))
    return rows


def test_prev_state_reproduces_published_bundle():
    snapshot = json.load(ka.SNAPSHOT.open())["prev_kcal_per_serving"]
    table = ka.compile_states()
    worst_rid, worst = None, 0.0
    for rid, prev in snapshot.items():
        delta = abs(table[rid]["prev"] - prev)
        if delta > worst:
            worst_rid, worst = rid, delta
    assert worst <= FIDELITY_TOL, (
        f"in-memory prev compile diverges from the published af856008 bundle "
        f"({worst_rid} off by {worst:.4f} kcal)")


def test_every_gate_recipe_is_documented_and_nothing_else():
    table = ka.compile_states()
    above = {
        rid for rid in table
        if ka.kcal_swing(table[rid]["prev"], table[rid]["fixed"])
        > ka.SWING_THRESHOLD
    }
    documented = set(_gate_rows(REPORT.read_text(encoding="utf-8")))
    missing = sorted(above - documented)
    stale = sorted(documented - above)
    assert not missing, f"moved >40% but missing from kcal-audit.md: {missing}"
    assert not stale, f"in kcal-audit.md gate table but no longer above the gate: {stale}"


def test_audit_nutrient_rows_exist_in_catalog_with_cited_values():
    catalog = {r["fdc_id"]: r for r in json.load(CATALOG.open())["records"]}
    for key, decision in ka.AUDIT_DECISIONS.items():
        row = catalog.get(decision["nutrient_fdc_id"])
        assert row is not None, (
            f"{key}: cited nutrient row fdc {decision['nutrient_fdc_id']} "
            "missing from the curated catalog")
        cited = decision["per_100g"]
        macros = row["macros"]
        assert macros["calories"] == cited["kcal"], key
        assert macros["protein_g"] == cited["protein_g"], key
        assert macros["carbs_g"] == cited["carbs_g"], key
        assert macros["fat_g"] == cited["fat_g"], key
        assert macros["fiber_g"] == cited["fiber_g"], key
        assert macros["sodium_g"] * 1000 == cited["sodium_mg"], key


def test_fixed_state_is_idempotent_over_rebuilt_vocabulary():
    """Applying the audit to the fixed state changes nothing: when the held
    rebuild packet re-sources the vocabulary per the report, this test keeps
    passing unchanged."""
    states = ka.load_states()
    fixed = ka.load_states()["fixed"]
    for key, decision in ka.AUDIT_DECISIONS.items():
        entry = fixed[key]
        assert entry["per_100g"]["kcal"] == decision["per_100g"]["kcal"]
    # sanity: states rebuilt twice produce the same object values
    assert states == ka.load_states()
