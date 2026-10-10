"""M3 tests: pin verify.build() outputs and the generated artifacts."""

from __future__ import annotations

import json

import verify as V


def test_build_is_deterministic():
    assert V.build() == V.build()


def test_committed_results_json_matches_fresh_build():
    committed = json.loads(V.RESULTS_JSON.read_text(encoding="utf-8"))
    assert committed == V.build()


def test_committed_report_md_matches_fresh_render():
    assert V.REPORT_MD.read_text(encoding="utf-8") == V.render_markdown(V.build())


def test_witness_verification_all_pass():
    doc = V.build()
    assert len(doc["witness_verification"]) == 4
    assert all(r["all_pass"] for r in doc["witness_verification"])


def test_leak_canary_passes():
    canary = V.build()["leak_canary"]
    assert canary["honest_key_clean"] and canary["mutated_key_flagged"]


def test_r4_exhibits_are_wellformed_ambiguities():
    for ex in V.build()["r4_surviving_ambiguities"]:
        assert len(ex["worlds"]) >= 2
        assert len(ex["targets"]) >= 2
        assert ex["worlds"][0]["observed_g"] == ex["worlds"][1]["observed_g"]


def test_sensitivity_rows_cover_declared_resolutions():
    rows = V.build()["resolution_sensitivity_r4"]
    assert [r["resolution_g"] for r in rows] == ["1", "2", "5", "10", "25"]
    for r in rows:
        assert r["keys"] >= r["ambiguous_keys"] >= 0
        assert r["unmeasurable_worlds"] >= 0
