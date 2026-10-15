"""Parity: the lab engine reproduces the contract checker's recompute()
on the committed coriander-v1 golden fixture — ranking order, per-feature
contributions, and decayed posterior state at canonical 6-decimal precision."""

from __future__ import annotations

import json
import os
import sys

REPO = os.path.pathsep.join(
    [
        os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")),
    ]
)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", ".."))

from taste_lab.engine import TasteResidualEngine, f6  # noqa: E402

FIXTURE = os.path.join(
    REPO,
    "docs",
    "spec",
    "taste",
    "contracts",
    "examples",
    "golden-fixture",
    "coriander-v1.json",
)


def load_fixture():
    with open(FIXTURE) as f:
        return json.load(f)


def eval_at_of(doc):
    """The checker derives the evaluation instant from the last (sorted)
    event; the fixture carries no evalAt of its own."""
    events = sorted(doc["input"]["events"], key=lambda e: (e["at"], e["id"]))
    return events[-1]["at"]


def test_parity_ranking_and_feature_state():
    doc = load_fixture()
    catalog = {c["recipe"]["id"]: c for c in doc["catalog"]["recipes"]}
    rule_scores = {rid: c["ruleScore"] for rid, c in catalog.items()}
    features = {rid: c["features"] for rid, c in catalog.items()}

    engine = TasteResidualEngine(features)
    engine.ingest(doc["input"]["events"], doc["input"]["exposures"])
    eval_at = eval_at_of(doc)

    entries = engine.rank(rule_scores, eval_at)
    got = [e.recipe_id for e in entries]
    expected = [r["recipe"]["id"] for r in doc["expected"]["ranking"]]
    assert got == expected, f"ranking mismatch: {got} != {expected}"

    # Per-feature contributions and learned sums, canonically rounded.
    by_id = {e.recipe_id: e for e in entries}
    for exp_row in doc["expected"]["ranking"]:
        rid = exp_row["recipe"]["id"]
        entry = by_id[rid]
        got_feats = {ft["featureKey"]: f6(ft["contribution"]) for ft in entry.learned_features}
        exp_feats = {ft["featureKey"]: f6(ft["contribution"]) for ft in exp_row["learnedFeatures"]}
        assert got_feats == exp_feats, f"{rid}: {got_feats} != {exp_feats}"
        assert f6(entry.learned_contribution) == f6(exp_row["learnedContribution"])
        assert f6(entry.total_score) == f6(exp_row["totalScore"])

    # Decayed posterior state (alpha, beta, lastEvidenceAt).
    final = engine.final_state(eval_at)
    state_by_key = {s["featureKey"]: s for s in doc["expected"]["featureState"]}
    assert set(final) == set(state_by_key), f"{sorted(final)} != {sorted(state_by_key)}"
    for fk, s in state_by_key.items():
        a, b, last = final[fk]
        assert f6(a) == f6(s["alpha"]), f"{fk}: alpha {f6(a)} != {s['alpha']}"
        assert f6(b) == f6(s["beta"]), f"{fk}: beta {f6(b)} != {s['beta']}"
        assert last.strftime("%Y-%m-%dT%H:%M:%SZ") == s["lastEvidenceAt"]


def test_parity_profile_statement():
    doc = load_fixture()
    catalog = {c["recipe"]["id"]: c for c in doc["catalog"]["recipes"]}
    features = {rid: c["features"] for rid, c in catalog.items()}
    engine = TasteResidualEngine(features, name_of={"ingredient:101": "coriander"})
    engine.ingest(doc["input"]["events"], doc["input"]["exposures"])
    rendered, hidden = engine.profile(eval_at_of(doc))

    got_rendered = [s["featureKey"] for s in rendered if s.get("layer") == "inferred"]
    exp_rendered = [s["featureKey"] for s in doc["expected"]["profileStatements"]]
    assert got_rendered == exp_rendered
    got_hidden = sorted((h["featureKey"], h["reason"]) for h in hidden)
    exp_hidden = sorted((h["featureKey"], h["reason"]) for h in doc["expected"]["hiddenStatements"])
    assert got_hidden == exp_hidden, f"{got_hidden} != {exp_hidden}"

    # The hedged text, byte for byte.
    texts = {s["featureKey"]: s["text"] for s in rendered if s.get("layer") == "inferred"}
    for s in doc["expected"]["profileStatements"]:
        assert texts[s["featureKey"]] == s["text"]
