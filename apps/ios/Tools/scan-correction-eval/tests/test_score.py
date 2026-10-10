"""Milestone-3 scorer tests: selection rule, bootstrap determinism, verify.

All tests run on synthetic data in tmp dirs — the committed replay results
are only read by the reference-matching tests in SwiftReplay.
"""

import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location(
    "score", Path(__file__).resolve().parents[1] / "score.py")
score = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score)


def seed_row(family, seed, arm, outcomes):
    """outcomes: list of (truth, decision) pairs."""
    return {
        "family": family,
        "seed": seed,
        "arm": arm,
        "decisions": [
            {"i": i, "label": f"L{i}", "truth": t, "decision": d}
            for i, (t, d) in enumerate(outcomes)
        ],
    }


def make_data():
    """Three dev families + one held-out, two arms, known tallies."""
    rows = []
    for seed in range(3):  # dev families: 3 seeds
        rows.append(seed_row("clean", seed, "current", [(1, 1), (2, None), (3, 9)]))
        rows.append(seed_row("clean", seed, "baseline", [(1, 1), (2, None), (3, None)]))
        rows.append(seed_row("noisy", seed, "current", [(4, None), (5, 5), (6, 1)]))
        rows.append(seed_row("noisy", seed, "baseline", [(4, None), (5, None), (6, None)]))
    for seed in range(4):  # held-out: 4 seeds, deliberately uneven per-seed
        outcomes = [
            [(7, 7), (8, 8), (9, None), (10, 1)],   # 2 correct, 1 wrong, 1 abstain
            [(7, 7), (8, None), (9, 9), (10, None)],  # 2 correct, 2 abstain
            [(7, None), (8, 8), (9, None), (10, None)],  # 1 correct, 3 abstain
            [(7, 7), (8, 1), (9, 9), (10, 2)],   # 2 correct, 2 wrong
        ][seed]
        rows.append(seed_row("heldout-combined", seed, "current", outcomes))
        rows.append(seed_row("heldout-combined", seed, "baseline",
                             [(7, 7), (8, None), (9, None), (10, None)]))
    return {"results": rows}


def write_env(tmp_path, data):
    results = tmp_path / "replay-results.json"
    results.write_text(json.dumps(data))
    score.RESULTS = results
    score.REPORT = tmp_path / "score-report.json"
    return results


# --- selection rule -------------------------------------------------------

def test_selection_uses_dev_families_only():
    table = {
        ("dev", 0, "a"): {"scans": 10, "wrong": 5, "correct": 5, "abstained": 0},
        ("dev", 0, "b"): {"scans": 10, "wrong": 0, "correct": 4, "abstained": 6},
        ("heldout-combined", 0, "a"): {"scans": 10, "wrong": 0, "correct": 10, "abstained": 0},
        ("heldout-combined", 0, "b"): {"scans": 10, "wrong": 0, "correct": 0, "abstained": 10},
    }
    # arm a nets 0 on dev; arm b nets 4 — b wins even though a is perfect
    # on held-out, which selection must never read.
    selected, _ = score.select_arm(table, ["dev"])
    assert selected == "b"


def test_selection_tiebreak_prefers_fewer_wrong():
    table = {
        ("dev", 0, "a"): {"scans": 10, "wrong": 3, "correct": 5, "abstained": 2},
        ("dev", 0, "b"): {"scans": 10, "wrong": 1, "correct": 3, "abstained": 6},
    }
    # both net +2; b has fewer wrong -> b
    selected, _ = score.select_arm(table, ["dev"])
    assert selected == "b"


def test_row_stats_counts_and_abstains():
    row = seed_row("f", 0, "a", [(1, 1), (2, 9), (3, None), (4, None), (5, 5)])
    assert score.row_stats(row) == {
        "scans": 5, "wrong": 1, "correct": 2, "abstained": 2}


def test_missing_decision_key_counts_as_abstain():
    row = {"family": "f", "seed": 0, "arm": "a",
           "decisions": [{"i": 0, "truth": 1}]}  # no "decision" key
    assert score.row_stats(row)["abstained"] == 1


# --- bootstrap determinism ------------------------------------------------

def test_bootstrap_is_deterministic_for_fixed_seed():
    data = make_data()
    a = score.build_report("digest", data, b=50, seed=7)
    b = score.build_report("digest", data, b=50, seed=7)
    assert a == b


def test_bootstrap_varying_seed_varies_intervals():
    data = make_data()
    tables = set()
    for seed in (1, 2, 3, 4, 5):
        rep = score.build_report("digest", data, b=50, seed=seed)
        tables.add(json.dumps(rep["held_out"]["current"]["bootstrap_95"]))
    # with 4 held-out seeds and varying counts per seed, different seeds
    # should not all land on identical intervals
    assert len(tables) > 1


# --- report + verify pipeline --------------------------------------------

def test_write_and_verify_roundtrip(tmp_path):
    data = make_data()
    write_env(tmp_path, data)
    digest = hashlib.sha256(json.dumps(data).encode()).hexdigest()
    report = score.build_report(digest, data, b=20)
    score.write_report(report)

    # capture module state, run verify against a fresh parse of the file
    stored = json.loads(score.REPORT.read_text())
    assert stored["selected_arm"] == "baseline"  # net 3 vs 0 (see below)

    # recompute by hand from row tallies:
    # dev: current = 3*(1 correct) + 3*(1 correct) + 3*(1 correct 5? no...
    # per-seed current dev rows: clean (1c,1w), noisy (1c,1w) -> per seed
    # correct 2, wrong 2, net 0; baseline per seed: clean 1c 0w, noisy 0c 0w
    # -> net +1 per seed... totals: baseline correct 3, wrong 0, net 3.
    dev = stored["selection_dev_table"]
    by_arm = {r["arm"]: r for r in dev}
    assert by_arm["baseline"]["correct"] == 3
    assert by_arm["baseline"]["wrong"] == 0
    assert by_arm["current"]["correct"] == 6
    assert by_arm["current"]["wrong"] == 6

    # verify path: recompute and compare
    recomputed = score.build_report(
        digest, data, b=stored["bootstrap"]["resamples"],
        seed=stored["bootstrap"]["seed"])
    assert stored == recomputed


def test_verify_refuses_tampered_results(tmp_path):
    data = make_data()
    results = write_env(tmp_path, data)
    digest = hashlib.sha256(results.read_bytes()).hexdigest()
    score.write_report(score.build_report(digest, data, b=10))

    # tamper: flip one decision in the frozen results
    data["results"][0]["decisions"][0]["decision"] = 99
    results.write_text(json.dumps(data))

    with pytest.raises(SystemExit) as exc:
        score.verify_report()
    assert "VERIFY FAILED" in str(exc.value)


def test_verify_refuses_dropped_case(tmp_path):
    data = make_data()
    results = write_env(tmp_path, data)
    digest = hashlib.sha256(results.read_bytes()).hexdigest()
    score.write_report(score.build_report(digest, data, b=10))

    # drop one seed-result entirely
    data["results"] = data["results"][:-1]
    results.write_text(json.dumps(data))

    with pytest.raises(SystemExit):
        score.verify_report()


def test_verify_refuses_edited_report(tmp_path):
    data = make_data()
    results = write_env(tmp_path, data)
    digest = hashlib.sha256(results.read_bytes()).hexdigest()
    score.write_report(score.build_report(digest, data, b=10))

    # tamper with the stored report instead
    stored = json.loads(score.REPORT.read_text())
    stored["selected_arm"] = "current"
    score.REPORT.write_text(json.dumps(stored))

    with pytest.raises(SystemExit):
        score.verify_report()


def test_missing_heldout_refuses_to_score(tmp_path):
    data = make_data()
    data["results"] = [r for r in data["results"]
                       if r["family"] != "heldout-combined"]
    with pytest.raises(SystemExit) as exc:
        score.build_report("digest", data, b=10)
    assert "held-out" in str(exc.value)


# --- learner-only preservation (schema 1 -> schema 2) ---------------------

TOOL_DIR = Path(__file__).resolve().parents[1]
DATA = TOOL_DIR / "data"


def _committed(name):
    path = DATA / "replay-out" / name
    if not path.exists():
        pytest.skip(f"{name} not committed")
    return json.loads(path.read_text())


def test_learner_only_decisions_preserved():
    """Schema-2 replay must reproduce the schema-1 (learner-only) decisions
    exactly, row for row — routing must not perturb the verified
    1,200-row / 10,600-decision dataset."""
    old = _committed("replay-results-learner-only.json")
    new = _committed("replay-results.json")
    assert new["schema"] == 2

    def key(row):
        return (row["family"], row["seed"], row["arm"])

    old_by_key = {key(r): r for r in old["results"]}
    assert len(old_by_key) == 1200
    assert len(new["results"]) == 1200
    for row in new["results"]:
        base = old_by_key[key(row)]
        assert [(d["i"], d.get("decision"), d["label"], d["truth"])
                for d in row["decisions"]] == \
            [(d["i"], d.get("decision"), d["label"], d["truth"])
                for d in base["decisions"]]
        assert (row["wrongAuto"], row["correctAuto"], row["abstained"],
                row["restartAgreement"], row["dbReopenAgreement"]) == \
            (base["wrongAuto"], base["correctAuto"], base["abstained"],
                base["restartAgreement"], base["dbReopenAgreement"])


def test_routing_counts_match_decisions_and_thresholds():
    """Routing effects in the schema-2 file must re-derive from the recorded
    decisions plus the production vision thresholds (>=0.82 auto, >=0.45
    confirm, else possible) applied to the histories' confidences."""
    new = _committed("replay-results.json")
    histories = json.loads((DATA / "histories.json").read_text())

    # conf keyed by (family, seed, i) — every committed scan has one
    conf = {}
    for h in histories["histories"]:
        for e in h["events"]:
            if e["type"] == "scan":
                conf[(h["family"], h["seed"], e["i"])] = e["conf"]

    for row in new["results"]:
        exp = {"auto": 0, "auto_correct": 0, "auto_wrong": 0,
               "auto_unresolved": 0, "confirm": 0, "possible": 0}
        for d in row["decisions"]:
            c = conf[(row["family"], row["seed"], d["i"])]
            bucket = "auto" if c >= 0.82 else ("confirm" if c >= 0.45 else "possible")
            assert d["bucket"] == bucket, \
                f"bucket mismatch {row['arm']}/{row['family']}/{row['seed']}/{d['i']}"
            if bucket == "auto":
                exp["auto"] += 1
                if d.get("decision") is None:
                    exp["auto_unresolved"] += 1
                elif d["decision"] == d["truth"]:
                    exp["auto_correct"] += 1
                else:
                    exp["auto_wrong"] += 1
            elif bucket == "confirm":
                exp["confirm"] += 1
            else:
                exp["possible"] += 1
        assert row["routedAutoAdd"] == exp["auto"]
        assert row["routedAutoAddCorrect"] == exp["auto_correct"]
        assert row["routedAutoAddWrong"] == exp["auto_wrong"]
        assert row["routedAutoAddUnresolved"] == exp["auto_unresolved"]
        assert row["routedConfirm"] == exp["confirm"]
        assert row["routedPossible"] == exp["possible"]
