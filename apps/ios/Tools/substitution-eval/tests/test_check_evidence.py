"""Tests for the substitution evidence harness (offline, no fixtures needed).

Covers:
  * missing-reference control: a case citing a non-production pair is rejected
  * incompatible-function control: a context whose function the pair evidence
    marks unsuitable computes 'unsupported', and a 'verified' claim for it is
    rejected
  * exact small ratio math in score.py (Fraction-based, no float drift)
  * --verify-report round-trip: tampering is detected
"""
import csv
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = TOOL_DIR.parents[3]

sys.path.insert(0, str(TOOL_DIR / "tools"))
sys.path.insert(0, str(TOOL_DIR))

import build_cases  # noqa: E402
from build_cases import verdict_for  # noqa: E402


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, TOOL_DIR / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


check_evidence = _load("check_evidence")
score = _load("score")


def _load_pair_evidence():
    with (TOOL_DIR / "evidence" / "pair_evidence.csv").open(newline="", encoding="utf-8") as f:
        return {r["pair_id"]: r for r in csv.DictReader(f)}


# ---------------------------------------------------------------- controls

def test_missing_reference_control():
    """A case citing a non-production pair and a case citing a non-bundled
    recipe must each be rejected by the row-level validator."""
    pair_evidence = _load_pair_evidence()
    missing_ok, _, detail = check_evidence.run_controls(pair_evidence)
    assert missing_ok, detail
    # And independently: each bad reference flags its own error.
    recipes, ingredients = check_evidence._load_catalog()
    errors = []
    check_evidence.check_case_rows(
        [
            {
                "case_id": "ctrl-bad-pair", "pair_id": "99-98",
                "original_id": "14", "original_name": "butter",
                "substitute_id": "16", "substitute_name": "olive_oil",
                "recipe_id": "2", "recipe_title": "t",
                "ingredient_role": "required", "original_grams": "1",
                "context_function": "fat", "function_basis": "c",
                "verdict": "verified", "production_ratio": "1.0",
            },
            {
                "case_id": "ctrl-bad-recipe", "pair_id": "14-16",
                "original_id": "14", "original_name": "butter",
                "substitute_id": "16", "substitute_name": "olive_oil",
                "recipe_id": "99999", "recipe_title": "x",
                "ingredient_role": "required", "original_grams": "1",
                "context_function": "fat", "function_basis": "c",
                "verdict": "verified", "production_ratio": "1.0",
            },
        ],
        errors, pair_evidence, recipes, ingredients,
    )
    assert any("no evidence row" in e for e in errors), errors
    assert any("not in bundled data" in e for e in errors), errors


def test_incompatible_function_control():
    """butter -> olive oil in a binding context must compute 'unsupported'."""
    pair_evidence = _load_pair_evidence()
    _, incompatible_ok, detail = check_evidence.run_controls(pair_evidence)
    assert incompatible_ok, detail
    assert verdict_for(pair_evidence["14-16"], "binding") == "unsupported"
    # and the supported function stays positive
    assert verdict_for(pair_evidence["14-16"], "fat") == "verified"


def test_unknown_function_left_unverified():
    pair_evidence = _load_pair_evidence()
    assert verdict_for(pair_evidence["14-16"], "unknown") == "unverified"


# ------------------------------------------------------------ ratio math

def test_ratio_fraction_exact_small_values():
    assert score.ratio_fraction(1, 2) == "1/2"
    assert score.ratio_fraction(2, 4) == "1/2"  # reduced
    assert score.ratio_fraction(2, 5) == "2/5"
    assert score.ratio_fraction(1, 3) == "1/3"
    assert score.ratio_fraction(0, 7) == "0/1"  # Fraction reduces zero
    assert score.ratio_fraction(35, 227) == "35/227"


def test_ratio_fraction_matches_float_within_epsilon():
    for num, den in [(1, 2), (2, 5), (1, 3), (35, 227)]:
        f = score.ratio_fraction(num, den)
        a, b = f.split("/")
        assert abs(int(a) / int(b) - num / den) < 1e-12


# ---------------------------------------------------------- report verify

def test_build_report_is_deterministic():
    r1 = score.build_report()
    r2 = score.build_report()
    assert r1 == r2


def test_verify_report_detects_tampering():
    report = score.build_report()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tmp:
        json.dump(report, tmp)
        path = tmp.name
    # unmodified round trip
    assert score.build_report() == report

    tampered = dict(report)
    tampered["contexts_total"] = report["contexts_total"] + 1
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tmp2:
        json.dump(tampered, tmp2)
        tampered_path = tmp2.name

    stored = json.loads(Path(tampered_path).read_text())
    assert stored != score.build_report()


def test_case_set_size_and_grounding():
    cases = build_cases.build_cases(REPO_ROOT)
    assert len(cases) >= 200
    functions_seen = {c["context_function"] for c in cases}
    for required in ("binding", "fat", "liquid", "thickening", "garnish"):
        assert required in functions_seen, f"{required} not represented"
