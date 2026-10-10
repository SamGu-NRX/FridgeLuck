"""Census tests: the committed census must verify against source."""

from __future__ import annotations

import json
from pathlib import Path

import census


def test_census_binds_verify_against_source():
    problems = census.verify_census()
    assert problems == [], "\n".join(problems)


def test_committed_census_json_matches_fresh_build():
    committed = json.loads(Path(census.CENSUS_JSON).read_text(encoding="utf-8"))
    fresh = census.build()
    # the committed file was verified when generated
    assert committed["verification"] == "pass"
    # everything except the recorded commit must be identical to a fresh build
    committed.pop("verification")
    fresh.pop("base_commit", None)
    committed.pop("base_commit", None)
    assert committed == fresh


def test_census_covers_the_declared_trace():
    concepts = {e["concept"] for e in census.CENSUS}
    assert "declared recipe servings" in concepts
    assert "consumed servings (confirmation state)" in concepts
    assert "portion multiplier (user-confirmed)" in concepts
    assert "weighed plate total" in concepts


def test_witness_counts_in_census_match_witnesses_module():
    committed = json.loads(Path(census.CENSUS_JSON).read_text(encoding="utf-8"))
    assert committed["witness_counts"] == census.witnesses.witness_counts()
