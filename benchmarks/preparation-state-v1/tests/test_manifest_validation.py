"""Manifest validation tests: the frozen manifest passes, and deliberate
tampering (unit mutation, unknown-state mutation, split drift, over-specific
probes) is caught.

Run: python3 -m pytest benchmarks/preparation-state-v1/tests -q
"""

from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest

BENCH = Path(__file__).resolve().parent.parent
REPO_ROOT = BENCH.parents[1]
sys.path.insert(0, str(BENCH))

import check_manifest  # noqa: E402

MANIFEST_PATH = BENCH / "manifest.json"
CATALOG_PATH = REPO_ROOT / "apps" / "ios" / "Resources" / "usda_ingredient_catalog.sqlite"


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text())


def _check(m: dict) -> list[str]:
    return check_manifest.check(m, CATALOG_PATH)


def test_frozen_manifest_passes(manifest):
    errors = _check(manifest)
    assert errors == [], "\n".join(errors)


def test_group_floor_is_met(manifest):
    assert manifest["counts"]["groups"] >= 150


def test_unit_mutation_detected(manifest):
    """Editing a pinned member name must fail validation."""
    m = copy.deepcopy(manifest)
    m["groups"][0]["members"][0]["name"] += " (Tampered)"
    assert any("name drift" in e for e in _check(m))


def test_unknown_state_mutation_detected(manifest):
    """Giving an unknown-state probe a concrete record target must fail."""
    m = copy.deepcopy(manifest)
    probe = next(p for p in m["probes"] if p["family"] == "unknown_state")
    group = next(g for g in m["groups"] if g["group_id"] == probe["text"].split(" ", 1)[1])
    probe["target"]["record_id"] = group["members"][0]["catalog_id"]
    errors = _check(m)
    assert any("must abstain" in e for e in errors)


def test_out_of_group_label_detected(manifest):
    """A state-probe label pointing outside its group must fail."""
    m = copy.deepcopy(manifest)
    probe = next(p for p in m["probes"] if p["family"] == "state")
    other = next(
        g
        for g in m["groups"]
        if g["group_id"] != probe["text"].split(" ", 1)[1]
    )
    probe["target"]["record_id"] = other["members"][0]["catalog_id"]
    errors = _check(m)
    assert any("outside its group" in e for e in errors)


def test_over_specific_probe_detected(manifest):
    """A probe carrying target-specific wording beyond the surface word must fail."""
    m = copy.deepcopy(manifest)
    probe = next(p for p in m["probes"] if p["family"] == "state")
    probe["text"] = probe["text"].replace(" ", " sulfured ", 1)
    errors = _check(m)
    assert any(
        "not a frozen group" in e for e in errors
    ), "injected descriptor word must break probe validation"


def test_split_drift_detected(manifest):
    """Moving a probe to a split its group does not belong to must fail."""
    m = copy.deepcopy(manifest)
    probe = next(p for p in m["probes"])
    probe["split"] = {"train": "test", "dev": "train", "test": "dev"}[probe["split"]]
    errors = _check(m)
    assert any("does not match" in e for e in errors)


def test_catalog_sha_mismatch_detected(manifest):
    m = copy.deepcopy(manifest)
    m["provenance"]["catalog_sha256"] = "0" * 64
    errors = _check(m)
    assert any("sha256 mismatch" in e for e in errors)


def test_group_floor_violation_detected(manifest):
    m = copy.deepcopy(manifest)
    m["groups"] = m["groups"][:100]
    errors = _check(m)
    assert any("below floor" in e for e in errors)
