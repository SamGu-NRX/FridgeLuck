"""Scorer tests: verdict application, dev-only threshold selection, group
level false-addition counting, and the verify mode that must catch tampered
scored outputs (the mutation check).
"""
import hashlib
import json

import pytest

from score import evaluate, group_records, select_thresholds

TAU_HIGH = 0.7
TAU_LOW = 0.2


def mrow(iid, stratum, split, group, score, produced=False):
    return {
        "image_id": iid, "stratum": stratum, "split": split, "role":
        "food_control" if stratum == "food_control" else "negative",
        "group_id": group, "series_id": f"series:{group}", "pair_id": "pair-0",
        "food_score": score, "produced_food": produced, "food_labels": [],
    }


def fake_manifest():
    # 2 negative groups + 1 control group per split
    return {
        "meta": {"name": "nonfood-rejection-v1"},
        "images": [
            mrow("ev0" + "0" * 13, "empty_visible", "dev", "gA", 0.05),
            mrow("ou0" + "0" * 13, "opaque_unknown", "dev", "gB", 0.05),
            mrow("fc0" + "0" * 13, "food_control", "dev", "gC", 0.9),
            mrow("ev1" + "0" * 13, "empty_visible", "test", "gD", 0.05),
            mrow("ou1" + "0" * 13, "opaque_unknown", "test", "gE", 0.05),
            mrow("fc1" + "0" * 13, "food_control", "test", "gF", 0.9),
        ],
    }


def report_of(manifest, override=None):
    images = [dict(r) for r in manifest["images"]]
    for r in images:
        r.pop("role")  # raw reports carry no role; the scorer joins on the manifest
        if override:
            override(r)
    return images


def test_select_thresholds_uses_dev_only():
    manifest = fake_manifest()
    report = report_of(manifest)
    # a test-split control with a low score must not drag tau_high down:
    # tau_high is the smallest dev threshold at which every dev control is
    # admitted subject to the false-addition cap — dev negatives score 0.05,
    # so anything above 0.05 admits both dev controls
    for r in report:
        if r["image_id"].startswith("fc1"):
            r["food_score"] = 0.0  # test-split control, must be ignored
    tau_high, tau_low, diag = select_thresholds(manifest, report)
    assert tau_high == pytest.approx(0.06)  # first grid point above 0.05
    assert diag["dev_control_recall_at_tau_high"] == pytest.approx(1.0)


def test_tau_low_caps_at_worst_clean_dev_visible_empty():
    manifest = fake_manifest()
    report = report_of(
        manifest,
        lambda r: r.update(food_score=0.15) if r["image_id"].startswith("ev0") else None,
    )
    _, tau_low, _ = select_thresholds(manifest, report)
    assert tau_low == pytest.approx(0.15)


def test_group_level_false_additions():
    manifest = fake_manifest()
    # two dev negatives in ONE group: only one of them produced food, but the
    # whole group must still count as a single false addition
    manifest["images"][0]["group_id"] = manifest["images"][1]["group_id"] = "gShared"
    report = report_of(
        manifest,
        lambda r: r.update(produced_food=True) if r["image_id"] == "ev0" + "0" * 13 else None,
    )
    metrics, _ = evaluate(manifest, report, TAU_HIGH, TAU_LOW)
    dev = metrics["dev"]
    assert dev["negative_groups"] == 1  # both dev negatives merged into gShared
    assert dev["false_addition_groups"] == 1  # group flagged via any-member
    assert dev["false_addition_rate_groups"] == pytest.approx(1.0)


def test_oracle_opaque_never_counts_as_certain_empty_even_at_zero():
    # ORACLE policy: closed containers are protected by the privileged
    # stratum input, so only the empty_visible negatives may be certain-empty
    manifest = fake_manifest()
    report = report_of(manifest, lambda r: r.update(food_score=0.0))
    metrics, _ = evaluate(manifest, report, TAU_HIGH, TAU_LOW, "oracle")
    assert metrics["dev"]["certain_empty_groups"] == 1
    assert metrics["test"]["certain_empty_groups"] == 1


def test_measured_opaque_at_zero_score_is_certain_empty():
    # MEASURED policy: the stratum is invisible at prediction time, so a
    # zero score on an opaque container IS called certainly empty. That is
    # the risk the oracle upper bound guards against, stated plainly.
    manifest = fake_manifest()
    report = report_of(manifest, lambda r: r.update(food_score=0.0))
    metrics, _ = evaluate(manifest, report, TAU_HIGH, TAU_LOW, "measured")
    # every negative group with score <= tau_low is certain-empty: the
    # empty_visible one and the opaque_unknown one, per split
    assert metrics["dev"]["certain_empty_groups"] == 2
    assert metrics["test"]["certain_empty_groups"] == 2


def test_control_recall_counts_only_admitted_food():
    manifest = fake_manifest()
    report = report_of(
        manifest, lambda r: r.update(food_score=0.5) if r["stratum"] == "food_control" else None
    )
    metrics, _ = evaluate(manifest, report, TAU_HIGH, TAU_LOW)
    assert metrics["dev"]["control_recall_groups"] == pytest.approx(0.0)


def test_group_records_folds_max_score_and_any_produced():
    rows = [
        {"group_id": "g", "stratum": "empty_visible", "split": "dev",
         "food_score": 0.1, "produced_food": False},
        {"group_id": "g", "stratum": "empty_visible", "split": "dev",
         "food_score": 0.4, "produced_food": True},
    ]
    g = group_records(rows)["g"]
    assert g["max_score"] == 0.4
    assert g["any_produced"] is True
    assert g["strata"] == {"empty_visible"}


def test_load_and_check_rejects_wrong_manifest_hash(tmp_path):
    from score import load_and_check

    manifest = fake_manifest()
    report = {
        "arm": {"name": "t", "version": "1"},
        "manifest_name": "nonfood-rejection-v1",
        "manifest_sha256": "deadbeef",
        "images": report_of(manifest),
    }
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    (tmp_path / "raw.json").write_text(json.dumps(report))
    with pytest.raises(SystemExit, match="manifest hash mismatch"):
        load_and_check(str(tmp_path / "manifest.json"), str(tmp_path / "raw.json"))


def test_verify_flags_mutated_scored_output(tmp_path):
    """The mutation check: a scored output with flipped verdicts and gutted
    metrics must be detected by recomputation from the raw report + manifest."""
    import score as S

    manifest_bytes = json.dumps(fake_manifest(), indent=1).encode()
    manifest = json.loads(manifest_bytes)
    raw = {
        "arm": {"name": "t", "version": "1"},
        "manifest_name": "nonfood-rejection-v1",
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "images": report_of(manifest),
    }
    (tmp_path / "manifest.json").write_bytes(manifest_bytes)
    (tmp_path / "raw.json").write_text(json.dumps(raw))

    manifest2, report2 = S.load_and_check(str(tmp_path / "manifest.json"), str(tmp_path / "raw.json"))
    tau_high, tau_low, _ = S.select_thresholds(manifest2, report2["images"])
    metrics, joined = S.evaluate(manifest2, report2["images"], tau_high, tau_low)

    # tamper: everything becomes "empty", metrics wiped
    scored = {
        "tau_high": tau_high, "tau_low": tau_low,
        "manifest_sha256": raw["manifest_sha256"],
        "images": [dict(r, verdict="empty") for r in joined],
        "metrics": {"dev": {}, "test": {}},
    }
    (tmp_path / "scored.json").write_text(json.dumps(scored))

    scored2 = json.load(open(tmp_path / "scored.json"))
    stored = {r["image_id"]: r.get("verdict") for r in scored2["images"]}
    verdict_problems = [r["image_id"] for r in joined if stored.get(r["image_id"]) != r["verdict"]]
    assert verdict_problems, "tampered verdicts must be detected"
    assert scored2["metrics"] != metrics, "gutted metrics must differ from recomputation"
    # sanity: genuine verdicts include "food" (controls at 0.9), so the
    # blanket "empty" tamper is definitely caught
    assert any(r["verdict"] == "food" for r in joined)


def test_scored_output_round_trips_then_detects_one_flip(tmp_path):
    import score as S

    manifest_bytes = json.dumps(fake_manifest(), indent=1).encode()
    manifest = json.loads(manifest_bytes)
    raw = {
        "arm": {"name": "t", "version": "1"},
        "manifest_name": "nonfood-rejection-v1",
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "images": report_of(manifest),
    }
    (tmp_path / "manifest.json").write_bytes(manifest_bytes)
    (tmp_path / "raw.json").write_text(json.dumps(raw))

    manifest2, report2 = S.load_and_check(str(tmp_path / "manifest.json"), str(tmp_path / "raw.json"))
    tau_high, tau_low, _ = S.select_thresholds(manifest2, report2["images"])
    metrics, joined = S.evaluate(manifest2, report2["images"], tau_high, tau_low)
    scored = {
        "tau_high": tau_high, "tau_low": tau_low,
        "manifest_sha256": raw["manifest_sha256"],
        "images": [{"image_id": r["image_id"], "verdict": r["verdict"]} for r in joined],
        "metrics": metrics,
    }
    path = tmp_path / "scored.json"
    path.write_text(json.dumps(scored))

    # untouched file reproduces exactly
    reloaded = json.load(open(path))
    assert reloaded["metrics"] == metrics
    stored = {r["image_id"]: r["verdict"] for r in reloaded["images"]}
    assert all(stored[r["image_id"]] == r["verdict"] for r in joined)

    # a single flipped verdict is detected
    reloaded["images"][0]["verdict"] = "food"
    stored = {r["image_id"]: r["verdict"] for r in reloaded["images"]}
    assert any(stored[r["image_id"]] != r["verdict"] for r in joined)
