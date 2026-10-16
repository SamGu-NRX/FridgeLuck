"""Rights revisions: fixes flagged changes_rights_pin stay LicenseRef-FL-Original.

A reviewed corpus fix (#195/#196/#197) edits FridgeLuck's own original text
after the authoring record was pinned at ingest — a missing molasses line, a
structural ingredient. The recipe keeps its licence: the revision is
FridgeLuck's own edit of its own text. The rights gate accepts the recipe only
against the pinned revision (data/recipes/evidence/rights.json, section
"fl_revisions", derived by fl_revisions.py), and only when the revision
describes the record exactly — title, ingredient-name hash, AND full-body
hash. These tests plant violations to prove the gate still refuses anything
else: a planted step edit, a renamed line, a retitled recipe, a missing or
wrong-licence revision.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
TOOLS = REPO / "data/recipes/tools"
sys.path.insert(0, str(TOOLS))

import corpus_io  # noqa: E402
import fl_revisions  # noqa: E402
import rights_evidence  # noqa: E402

CORPUS = REPO / "data/recipes/corpus.jsonl"
FIXES = fl_revisions.fix_files()
MANIFEST = REPO / "data/recipes/rights_manifest.json"
EVIDENCE = REPO / "data/recipes/evidence/rights.json"


@pytest.fixture(scope="module")
def corpus_by_id() -> dict[str, dict]:
    return {line.obj.get("id"): line.obj
            for line in corpus_io.read_jsonl(CORPUS)}


@pytest.fixture(scope="module")
def evidence() -> dict:
    return json.loads(EVIDENCE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def pin_ids(evidence: dict) -> set[str]:
    return set(evidence.get("fl_revisions") or {})


def violations(recipe: dict, rec: dict, evidence: dict) -> list[str]:
    return rights_evidence.rights_violations(recipe, rec, evidence)


def manifest_record(manifest: dict, rid: str) -> dict:
    rec = manifest["records"].get(rid)
    assert rec is not None, f"{rid} missing from rights_manifest.json"
    return rec


def test_revision_set_matches_pin_flags(pin_ids: set[str]) -> None:
    """The pinned revisions cover exactly the fixes flagged changes_rights_pin —
    none skipped, none invented."""
    from_fixes: set[str] = set()
    for path in FIXES:
        doc = json.loads(path.read_text(encoding="utf-8"))
        if doc.get("schema") != "fridgeluck/corpus-fixes/v1":
            continue
        from_fixes |= {f["id"] for f in doc.get("fixes", [])
                       if f.get("changes_rights_pin")}
    assert from_fixes, "no changes_rights_pin fixes found in the fix packets"
    assert pin_ids == from_fixes


def test_evidence_reproducible_from_corpus_and_fix_files(
        evidence: dict) -> None:
    """pin_rights_evidence.py --check stays green: the committed fl_revisions
    section is exactly what derive() regenerates from the corpus and the fix
    packets."""
    fresh = fl_revisions.derive(FIXES)
    assert fresh == (evidence.get("fl_revisions") or {})


def test_revisions_keep_original_licence(pin_ids: set[str],
                                         evidence: dict) -> None:
    for rid, rev in evidence["fl_revisions"].items():
        assert rev["license"] == "LicenseRef-FL-Original", rid
        assert rev["revised_by"] == "FridgeLuck", rid
        assert rev["packet"], rid
        assert rev["evidence"].startswith("data/recipes/fixes/"), rid
        stripped = rev.get("stripped_claims") or []
        assert all(isinstance(c, str) for c in stripped), rid


def test_gate_accepts_every_revised_recipe(corpus_by_id: dict, manifest: dict,
                                           evidence: dict) -> None:
    """Each revised recipe passes the full rights gate against its manifest
    record: title/ingredient mismatch cleared by the pinned revision only."""
    for rid in evidence["fl_revisions"]:
        problems = violations(corpus_by_id[rid],
                              manifest_record(manifest, rid), evidence)
        assert problems == [], (rid, problems)


@pytest.mark.parametrize("mutate", [
    pytest.param(lambda r: r["steps"].__setitem__(
        0, {**r["steps"][0], "text": "Stir in a splash of cold tap water."}),
        id="planted step edit"),
    pytest.param(lambda r: r["ingredients"][0].__setitem__("name", "sorghum syrup"),
        id="renamed ingredient"),
    pytest.param(lambda r: r.__setitem__("title", "Totally Different Title"),
        id="retitled recipe"),
])
def test_gate_refuses_unpinned_body_changes(corpus_by_id: dict, manifest: dict,
                                            evidence: dict, mutate) -> None:
    """A revision pins ONE reviewed edit. Any other body change — a planted
    step edit, a renamed line, a retitled recipe — still refuses."""
    rid = "fl-original-0001"  # molasses rubric fix, in the originals band
    recipe = copy.deepcopy(corpus_by_id[rid])
    mutate(recipe)
    problems = violations(recipe, manifest_record(manifest, rid), evidence)
    assert problems, "the gate accepted an unpinned body change"
    assert "different recipe" in problems[0]


def test_gate_refuses_when_revision_missing(corpus_by_id: dict,
                                            manifest: dict,
                                            evidence: dict) -> None:
    rid = "fl-original-0001"
    without = copy.deepcopy(evidence)
    del without["fl_revisions"][rid]
    problems = violations(corpus_by_id[rid],
                          manifest_record(manifest, rid), without)
    assert problems and "no pinned FridgeLuck revision" in problems[0]


def test_gate_refuses_non_original_revision_licence(corpus_by_id: dict,
                                                    manifest: dict,
                                                    evidence: dict) -> None:
    rid = "fl-original-0001"
    wrong = copy.deepcopy(evidence)
    wrong["fl_revisions"][rid]["license"] = "CC-BY-4.0"
    problems = violations(corpus_by_id[rid],
                          manifest_record(manifest, rid), wrong)
    assert problems and "LicenseRef-FL-Original" in problems[0]


def test_revision_record_hash_binds_the_full_body(corpus_by_id: dict,
                                                  evidence: dict) -> None:
    """record_sha256 is the canonical sort-keys hash of the shipped record —
    byte-format changes never move it; content changes do."""
    rid = "fl-original-0001"
    rev = evidence["fl_revisions"][rid]
    assert rev["record_sha256"] == fl_revisions.canonical_record_sha256(
        corpus_by_id[rid])


def test_claim_strip_is_idempotent() -> None:
    """strip_unproven_claims.py removes nothing on a second run."""
    import subprocess
    result = subprocess.run(
        [sys.executable, "-I", str(TOOLS / "strip_unproven_claims.py"),
         "--suite-dir", str(REPO / "data/recipes/suite")],
        capture_output=True, text=True, cwd=REPO, check=True)
    assert "0 removed" in result.stdout or "kept, 0 removed" in result.stdout, \
        result.stdout + result.stderr
