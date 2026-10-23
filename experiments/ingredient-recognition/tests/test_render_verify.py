#!/usr/bin/env python3
"""Mutation controls for the canonical report and the GRDB replay artifacts.

Each test mutates ONE pinned input in a disposable copy and asserts the
corresponding verifier check FAILS — i.e. the byte-for-byte report
regeneration and the replay integrity checks actually have teeth. Nothing
here writes to the repository tree.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

EXPERIMENT = Path(__file__).resolve().parent.parent
SCORING = EXPERIMENT / "scoring"
DIFF = EXPERIMENT / "differential"
sys.path.insert(0, str(SCORING))

import render_report  # noqa: E402
import verify_report  # noqa: E402


@pytest.fixture(scope="module")
def fixture_root(tmp_path_factory) -> Path:
    """A minimal experiment tree: exactly what load() and the checks read."""
    root = tmp_path_factory.mktemp("fixture")
    (root / "scoring").mkdir()
    (root / "observations").mkdir()
    (root / "resolution").mkdir()
    (root / "differential").mkdir()
    for stem, _, _, _ in render_report.FINAL_RUNS:
        shutil.copy(SCORING / f"{stem}_scores.json", root / "scoring")
    for stem, _ in render_report.COST_RUNS:
        shutil.copy(EXPERIMENT / "observations" / f"{stem}.meta.json", root / "observations")
    for name in ["thresholds_sixcrop_dev.json", "thresholds_wholecrop_dev.json"]:
        shutil.copy(SCORING / name, root / "scoring")
    shutil.copy(EXPERIMENT / "resolution" / "lexicon_snapshot.json", root / "resolution")
    for name in ["grdb_replay_meta.json", "grdb_replay_results.jsonl",
                 "python_catalog_results.jsonl", "probes.jsonl"]:
        shutil.copy(DIFF / name, root / "differential")
    return root


def test_render_is_deterministic():
    once = render_report.render(render_report.load(EXPERIMENT))
    twice = render_report.render(render_report.load(EXPERIMENT))
    assert once == twice


def test_committed_report_is_the_canonical_render():
    assert verify_report.check_report_bytes() is None


def test_hand_editing_the_report_fails_verification():
    doctored = render_report.render(render_report.load(EXPERIMENT)) + "\nHand edit.\n"
    message = verify_report.check_report_bytes(report_path=_write(doctored))
    assert message is not None and "canonical render" in message


def test_mutating_a_score_artifact_changes_the_render(fixture_root):
    intact = render_report.render(render_report.load(fixture_root))
    scores_path = fixture_root / "scoring" / "validation_curated_absorberson_sixcrop_scores.json"
    scores = json.loads(scores_path.read_text())
    scores["detection_precision"] = 0.9999
    scores_path.write_text(json.dumps(scores))
    mutated = render_report.render(render_report.load(fixture_root))
    assert intact != mutated
    # and the verifier's byte-compare would fail against a report rendered
    # from the intact artifacts
    assert verify_report.check_report_bytes(
        root=fixture_root,
        report_path=_write(intact),
    ) is not None


def test_mutating_grdb_replay_output_fails_the_python_side_check(fixture_root):
    replay = fixture_root / "differential" / "grdb_replay_results.jsonl"
    rows = [json.loads(line) for line in replay.read_text().splitlines()]
    # flip one resolved id to a wrong value
    for row in rows:
        if row.get("resolveAllowPrefix"):
            row["resolveAllowPrefix"] = str(int(row["resolveAllowPrefix"]) + 1)
            break
    replay.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
    problems = verify_report.check_grdb_python_side(diff_dir=fixture_root / "differential")
    assert problems and any("GRDB replay differs" in p for p in problems)


def test_mutating_port_outputs_fails_the_python_side_check(fixture_root):
    port = fixture_root / "differential" / "python_catalog_results.jsonl"
    rows = [json.loads(line) for line in port.read_text().splitlines()]
    for row in rows:
        if row.get("resolveExact"):
            row["resolveExact"] = str(int(row["resolveExact"]) + 1)
            break
    port.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
    problems = verify_report.check_grdb_python_side(diff_dir=fixture_root / "differential")
    assert any("does not match a fresh port run" in p for p in problems)


def test_stale_mirror_hash_fails(tmp_path):
    """A doctored SourceManifest (wrong pinned hash) must fail the mirror check."""
    mirror = tmp_path / "mirror"
    mirror.mkdir()
    shutil.copy(
        verify_report.MIRROR / "IngredientCatalogResolver.swift",
        mirror / "IngredientCatalogResolver.swift",
    )
    doctored = (verify_report.MIRROR / "SourceManifest.swift").read_text().replace(
        _pinned(), "0" * 64
    )
    (mirror / "SourceManifest.swift").write_text(doctored)
    message = verify_report.check_mirror_hash(mirror_dir=mirror)
    assert message is not None and "pinned hash" in message


def test_mirror_matches_repository_file():
    """The committed mirror is byte-identical to the production source."""
    assert verify_report.check_mirror_hash() is None


def test_probes_file_is_current():
    proc = subprocess.run(
        [sys.executable, str(DIFF / "extract_probes.py"), "--check"],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_full_grdb_diff_passes():
    proc = subprocess.run(
        [sys.executable, str(DIFF / "grdb_diff.py")],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr


# ---------------------------------------------------------------- helpers

def _write(text: str) -> Path:
    import tempfile
    f = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
    f.write(text)
    f.close()
    return Path(f.name)


def _pinned() -> str:
    text = (verify_report.MIRROR / "SourceManifest.swift").read_text()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('"IngredientCatalogResolver.swift"'):
            return line.split('"')[3]
    raise AssertionError("pinned hash not found")
