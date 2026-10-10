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


def test_more_evidence_never_moves_worlds_into_ambiguity():
    # refinement splits classes, so the ambiguous-key COUNT is not monotone
    # (two children of one ambiguous parent may both be ambiguous); what is
    # monotone: identifiable keys never decrease, and the number of worlds
    # living in ambiguous classes never grows as evidence is added
    stats = en.build()["regimes"]
    order = list(en.REGIMES)
    ident = [stats[r]["identifiable_keys"] for r in order]
    amb_worlds = [stats[r]["ambiguous_worlds"] for r in order]
    assert all(x <= y for x, y in zip(ident, ident[1:])), f"identifiable {ident}"
    assert all(x >= y for x, y in zip(amb_worlds, amb_worlds[1:])), f"amb worlds {amb_worlds}"


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
    for fine, coarse in (
        ("R2_identity_and_declared", "R1_plate_only"),
        ("R3_plus_reference", "R2_identity_and_declared"),
        ("R4_plus_portion", "R3_plus_reference"),
    ):
        g_fine = en.group_by_key(worlds, fine)
        for key, members in list(g_fine.items())[:50]:
            parents = {
                schema.observation_key(schema.evidence_from_world(w, **en.REGIMES[coarse]))
                for w in members
            }
            assert len(parents) == 1, (fine, coarse, key)
