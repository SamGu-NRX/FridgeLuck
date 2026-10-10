"""M2 tests: determinism, committed counts, witness membership, monotonicity."""

from __future__ import annotations

import json

import enumerate as en
import schema


def test_build_is_deterministic():
    a, b = en.build(), en.build()
    assert a == b


def test_committed_enumeration_json_matches_fresh_build():
    committed = json.loads(en.ENUM_JSON.read_text(encoding="utf-8"))
    assert committed == en.build()


def test_family_size_is_the_declared_grid():
    doc = en.build()
    recipes = doc["family"]["recipes"]
    assert doc["family"]["worlds"] == recipes * len(en.COOK_SCALES) * len(en.CONSUMED) * len(en.PORTIONS)
    assert recipes == 166  # bundle-bound; fails loudly if data.json drifts


def test_all_four_hand_witnesses_appear_in_their_regimes():
    checks = en.build()["witness_membership"]
    assert len(checks) == 4
    assert all(c["ok"] for c in checks)


def test_more_evidence_never_increases_ambiguity():
    stats = en.build()["regimes"]
    order = list(en.REGIMES)
    ident = [stats[r]["identifiable_keys"] for r in order]
    ambig = [stats[r]["ambiguous_keys"] for r in order]
    assert all(x <= y for x, y in zip(ident, ident[1:])), f"identifiable {ident}"
    assert all(x >= y for x, y in zip(ambig, ambig[1:])), f"ambiguous {ambig}"


def test_ambiguous_examples_hold_two_or_more_targets():
    for regime, stats in en.build()["regimes"].items():
        for ex in stats["ambiguous_examples"]:
            assert len(ex["targets"]) >= 2, (regime, ex)
            assert ex["members"] >= 2, (regime, ex)
            assert len(ex["sample_worlds"]) >= 2, (regime, ex)


def test_regime_keys_refine_each_other():
    # every pair of worlds sharing an R3 key must share the R2 key: richer
    # evidence strictly refines the partition
    worlds = en.build_family()
    for regime, refined in (("R2_identity_and_declared", "R1_plate_only"), ("R4_plus_portion", "R3_plus_reference")):
        g_course, g_fine = en.group_by_key(worlds, refined), en.group_by_key(worlds, regime)
        course_keys = {schema.observation_key(schema.evidence_from_world(w, **en.REGIMES[refined])) for w in g_fine[0]}
        _ = course_keys  # structural spot check below on sampled classes
        for key, members in list(g_fine.items())[:50]:
            course = {schema.observation_key(schema.evidence_from_world(w, **en.REGIMES[refined])) for w in members}
            assert len(course) == 1, (regime, refined, key)
