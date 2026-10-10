"""Tests over the generated sequence histories: counts, determinism,
stream independence, and split controls. Also mutation-tests the checker
itself (a corrupted history must fail)."""

import copy
import json
import subprocess
import sys
from pathlib import Path

import pytest

TOOL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOL))

import check_histories  # noqa: E402
import reference  # noqa: E402
import sequences  # noqa: E402

DATA = TOOL / "data" / "histories.json"


@pytest.fixture(scope="module")
def data():
    if not DATA.exists():
        pytest.skip("histories.json not generated yet; run sequences.py first")
    return json.loads(DATA.read_text())


@pytest.fixture(scope="module")
def fresh():
    return sequences.build_all()


def test_family_and_seed_counts(fresh):
    assert len(fresh["families"]) == 6
    for f in fresh["families"]:
        assert f["seed_count"] == sequences.SEEDS_PER_FAMILY == 50
    assert len(fresh["histories"]) == 300
    kinds = {f["name"]: f["kind"] for f in fresh["families"]}
    assert kinds[sequences.HELDOUT_FAMILY] == "heldout"
    assert all(kinds[n] == "development" for n in sequences.DEVELOPMENT_FAMILIES)


def test_generation_is_deterministic(fresh):
    again = sequences.build_all()
    assert json.dumps(again, sort_keys=True) == json.dumps(fresh, sort_keys=True)


def test_truth_and_feedback_streams_are_independent(fresh):
    # Feedback choices come from their own named stream: across the noisy
    # family the feedback product must both agree and disagree with truth,
    # i.e. it is not a copy of the truth stream.
    noisy = [h for h in fresh["histories"] if h["family"] == "noisy"]
    a_ids = {h["products"]["a"] for h in noisy}
    agreements, disagreements = 0, 0
    for h in noisy:
        a = h["products"]["a"]
        for e in h["events"]:
            if e["type"] == "feedback":
                if e["product"] == a:
                    agreements += 1
                else:
                    disagreements += 1
    assert a_ids
    assert agreements > 0 and disagreements > 0


def test_clean_split_controls(fresh):
    clean = [h for h in fresh["histories"] if h["family"] == "clean"]
    informative = [h for h in clean if h["seed"] < sequences.CONTROL_SEED_OFFSET]
    controls = [h for h in clean if h["seed"] >= sequences.CONTROL_SEED_OFFSET]
    assert len(informative) == 25 and len(controls) == 25
    for h in informative:
        products = {e["product"] for e in h["events"] if e["type"] == "feedback"}
        assert products == {h["products"]["a"]}
    for h in controls:
        products = [e["product"] for e in h["events"] if e["type"] == "feedback"]
        assert any(p != h["products"]["a"] for p in products)


def test_labels_share_one_normalized_key(data):
    for h in data["histories"]:
        keys = {e["label"].strip().lower() for e in h["events"] if e["type"] == "scan"}
        assert len(keys) == 1


def test_reference_policy_units():
    p = reference.CurrentPolicy()
    assert p.auto("tomato") is None
    p.record(" Tomato ", 7, ts=100)
    assert p.suggested("TOMATO") == 7
    assert p.auto("tomato") is None  # threshold: single correction suggests only
    p.record("tomato", 7, ts=200)
    assert p.auto(" tomato ") == 7  # count >= 2 auto-corrects, normalization holds


def test_reference_tie_break_rules():
    p = reference.CurrentPolicy()
    p.record("x", 1, ts=100)
    p.record("x", 2, ts=200)
    # counts tied 1-1: later timestamp wins, threshold blocks anyway
    assert p.suggested("x") == 2
    p.record("x", 1, ts=300)
    # counts 2-1: A wins by count
    assert p.auto("x") == 1
    p.record("x", 2, ts=400)
    # counts tied 2-2: later last_used_at wins
    assert p.auto("x") == 2
    # same-second tie (equal ts): higher rowid (later insert) wins
    q = reference.CurrentPolicy()
    q.record("x", 1, ts=500)
    q.record("x", 2, ts=500)
    assert q.suggested("x") == 2


def test_restart_preserves_decisions():
    import random

    for seed in range(20):
        rng = random.Random(seed)
        p = reference.CurrentPolicy()
        expected_auto, expected_sugg = [], []
        for i in range(40):
            if rng.random() < 0.5:
                p.record("label", rng.choice([1, 2, 3]), ts=1_000_000 + i * 7)
            expected_auto.append(p.auto("label"))
            expected_sugg.append(p.suggested("label"))
            if i % 9 == 8:
                p = p.restarted()
                assert p.auto("label") == expected_auto[-1]
                assert p.suggested("label") == expected_sugg[-1]


def test_checker_passes_on_generated_data():
    result = subprocess.run(
        [sys.executable, str(TOOL / "check_histories.py")],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OK: 6 families x 50 seeds = 300 histories validated" in result.stdout


def test_checker_catches_corrupted_history(data, tmp_path):
    corrupted = copy.deepcopy(data)
    # flip one truth in the changed family: closed-form expectations break
    for h in corrupted["histories"]:
        if h["family"] == "changed":
            for e in h["events"]:
                if e["type"] == "scan" and e["truth"] == h["products"]["b"]:
                    e["truth"] = h["products"]["a"]
                    break
            break
    path = tmp_path / "histories.json"
    path.write_text(json.dumps(corrupted))
    result = subprocess.run(
        [sys.executable, str(TOOL / "check_histories.py"), "--data", str(path), "--expected-out", str(tmp_path / "x.json")],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert "FAILED" in result.stdout
