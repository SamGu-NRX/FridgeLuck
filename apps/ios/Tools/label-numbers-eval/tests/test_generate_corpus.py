"""Tests for the synthetic label-number corpus generator.

The generator must be deterministic, produce the documented family/variant
coverage, and emit internally consistent truth tables: every observable entry
must be justified by its evidence line, and every unobservable entry must carry
a justification that actually holds on the emitted lines.
"""

import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
EVAL_DIR = HERE.parent
sys.path.insert(0, str(EVAL_DIR))

import generate_corpus as gen  # noqa: E402

FAMILIES = gen.FAMILIES
CLEAN_PER_FAMILY = gen.CLEAN_PER_FAMILY


@pytest.fixture(scope="module")
def records():
    return gen.build(20261010)


def _group_pairs(records):
    by_group = {}
    for rec in records:
        by_group.setdefault(rec["group_id"], []).append(rec)
    return by_group


# ---------------------------------------------------------------- determinism


def test_deterministic_same_seed():
    a = gen.build(20261010)
    b = gen.build(20261010)
    assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def test_different_seed_changes_content():
    a = gen.build(11)
    b = gen.build(22)
    assert json.dumps(a, sort_keys=True) != json.dumps(b, sort_keys=True)


# -------------------------------------------------------------------- shape


def test_counts(records):
    assert len(records) == 2 * len(FAMILIES) * CLEAN_PER_FAMILY
    groups = _group_pairs(records)
    assert len(groups) == len(FAMILIES) * CLEAN_PER_FAMILY
    for fam in FAMILIES:
        fam_records = [r for r in records if r["family"] == fam]
        assert len(fam_records) == 2 * CLEAN_PER_FAMILY
        assert sum(1 for r in fam_records if r["variant_kind"] == "clean") == CLEAN_PER_FAMILY
        assert sum(1 for r in fam_records if r["variant_kind"] == "corrupted") == CLEAN_PER_FAMILY


def test_group_is_one_clean_plus_one_corrupted(records):
    for group, recs in _group_pairs(records).items():
        kinds = sorted(r["variant_kind"] for r in recs)
        assert kinds == ["clean", "corrupted"], group
        assert len({r["record_id"] for r in recs}) == 2, group


def test_record_schema(records):
    for rec in records:
        assert rec["record_id"].startswith("LN-")
        assert rec["source"]["kind"] == "synthetic"
        assert rec["source"]["generator"] == f"gen_{rec['family']}"
        assert rec["source"]["reference"]
        assert isinstance(rec["lines"], list) and rec["lines"]
        assert isinstance(rec["fields"], dict) and rec["fields"]


# --------------------------------------------------------- truth invariants

FIELDS_WITH_BASIS = (
    "energy_kj",
    "energy_kcal",
    "fat_g",
    "carbohydrate_g",
    "protein_g",
    "salt_g",
    "sodium_mg",
)


def test_observable_entries_are_justified(records):
    """An observable entry must have a line index, and its value must appear
    on that line (numeric tokens for quantities, substring for serving_size)."""
    for rec in records:
        lines = rec["lines"]
        for key, d in rec["fields"].items():
            if not d["observable"]:
                continue
            fid = key.split("@")[0]
            ev = d["evidence_line"]
            assert ev is not None, (rec["record_id"], key)
            assert 0 <= ev < len(lines), (rec["record_id"], key)
            line, value = lines[ev], d["value"]
            assert value is not None, (rec["record_id"], key)
            if fid == "serving_size":
                assert " ".join(str(value).split()).lower() in " ".join(line.split()).lower(), (
                    rec["record_id"],
                    key,
                )
            else:
                assert gen._value_occurrences(line, str(value)), (rec["record_id"], key)


def test_unobservable_entries_carry_a_real_justification(records):
    for rec in records:
        lines = rec["lines"]
        for key, d in rec["fields"].items():
            if d["observable"]:
                assert d["unobservability_reason"] is None, (rec["record_id"], key)
                continue
            reason = d["unobservability_reason"]
            assert reason, (rec["record_id"], key, "no reason")
            fid, basis = key.split("@")[0], d["basis"]
            if reason == "not_declared":
                assert d["value"] is None, (rec["record_id"], key)
            elif reason == "value_not_in_text":
                ev = d["evidence_line"]
                assert ev is not None and 0 <= ev < len(lines), (rec["record_id"], key)
                if d["value"] is not None:
                    fid0 = key.split("@")[0]
                    if fid0 == "serving_size":
                        assert " ".join(str(d["value"]).split()).lower() not in " ".join(
                            lines[ev].split()
                        ).lower(), (rec["record_id"], key)
                    else:
                        assert not gen._value_occurrences(lines[ev], str(d["value"])), (
                            rec["record_id"],
                            key,
                        )
            elif reason == "field_name_missing":
                ev = d["evidence_line"]
                assert ev is not None and 0 <= ev < len(lines), (rec["record_id"], key)
                for alias in gen.FIELD_NAMES.get(fid, [fid]):
                    assert alias.lower() not in lines[ev].lower(), (rec["record_id"], key, alias)
            elif reason == "unit_missing":
                ev = d["evidence_line"]
                assert ev is not None and 0 <= ev < len(lines), (rec["record_id"], key)
                unit = d["unit"]
                assert unit and unit not in lines[ev], (rec["record_id"], key)
            elif reason == "basis_header_missing":
                import re

                markers = gen.BASIS_MARKERS.get(basis)
                present = bool(
                    markers and any(re.search(markers, line) for line in lines)
                )
                assert basis and not present, (rec["record_id"], key)
            else:
                pytest.fail(f"unknown unobservability_reason {reason!r} on {rec['record_id']}/{key}")


def _basis_present(basis, lines):
    import re

    marker = gen.BASIS_MARKERS.get(basis)
    return bool(marker and any(re.search(marker, line) for line in lines))


def test_basis_markers_on_clean_records(records):
    for rec in records:
        if rec["variant_kind"] != "clean":
            continue
        for key, d in rec["fields"].items():
            if d["observable"] and d["basis"] is not None:
                assert _basis_present(d["basis"], rec["lines"]), (rec["record_id"], key)


# ------------------------------------------------------------ arithmetic


def _dec(s):
    return __import__("decimal").Decimal(str(s))


def test_salt_sodium_consistency(records):
    for rec in records:
        f = rec["fields"]
        for b in gen.BASES:
            salt, sod = f.get(f"salt_g@{b}"), f.get(f"sodium_mg@{b}")
            if salt and sod and salt["observable"] and sod["observable"] and salt["value"]:
                from decimal import Decimal

                salt_g = _dec(salt["value"])
                sodium_val = _dec(sod["value"])
                sodium_g = sodium_val / 1000 if (sod["unit"] or "mg") == "mg" else sodium_val
                assert abs(salt_g - sodium_g * Decimal("2.5")) <= Decimal("0.06"), (
                    rec["record_id"],
                    b,
                )


def test_kj_kcal_within_basis(records):
    from decimal import Decimal

    for rec in records:
        f = rec["fields"]
        for b in gen.BASES:
            kj, kcal = f.get(f"energy_kj@{b}"), f.get(f"energy_kcal@{b}")
            if kj and kcal and kj["observable"] and kcal["observable"]:
                diff = abs(_dec(kj["value"]) - _dec(kcal["value"]) * Decimal(str(gen.KJ_PER_KCAL)))
                assert diff <= Decimal("3"), (rec["record_id"], b, diff)


def test_no_duplicate_record_ids(records):
    ids = [r["record_id"] for r in records]
    assert len(ids) == len(set(ids))


def test_corrupted_variants_actually_changed_text(records):
    for group, recs in _group_pairs(records).items():
        clean = next(r for r in recs if r["variant_kind"] == "clean")
        corrupt = next(r for r in recs if r["variant_kind"] == "corrupted")
        assert corrupt["corruption"] is not None, group
        assert corrupt["lines"] != clean["lines"], group
        assert isinstance(corrupt["corruption"]["op"], str) and corrupt["corruption"]["op"], group
        # truth table must still be well-formed after corruption
        for key, d in corrupt["fields"].items():
            assert d["observable"] or d["unobservability_reason"], (group, key)
