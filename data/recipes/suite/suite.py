#!/usr/bin/env python3
"""Suite C — recipe corpus quality and rights.

Metrics (bars from PLAN.md's scorecard table via SCORECARD.md row C):

1. rights_clear_recipes   >= 400 recipes with complete per-recipe rights
                          evidence (programme target 1,500). A recipe counts
                          only when its manifest record is COMPLETE per
                          rights.py (source, source type, origin, license,
                          license evidence, access date, six permissions).
2. food_safety_linter     == 100% of rights-clear corpus recipes pass the RS
                          linter (schema, quantity evidence, FSIS thermometer
                          checks, bounded timers, claim evidence).
3. quantity_evidence      >= 95% of ingredient lines across the rights-clear
                          corpus resolve to grams (weighed / source_grams /
                          household-with-conversion). Unknown-quantity lines
                          are honest but count as unresolved.
4. unchecked_claims       == 0 allergen/diet claims without machine evidence
                          after the linter strips unchecked ones.
5. coverage               == 100% of the bands declared in bands.py hold at
                          least one rights-clear recipe (meal slots x time
                          bands x cuisines; marginal coverage per axis).

Inputs are all committed inside this suite directory, so the suite reports
`not-run` (with a precise reason) rather than pass when one is missing.

Self-test (SCORECARD.md): plants 5 sabotage scenarios against small synthetic
fixtures — a corrupted fixture, a flipped diet label, a lying emitter, a
missing rights record, and a missing coverage band — and asserts each flips
the derived status to fail. Prints `caught k/k planted failures` and exits 0
only when all are caught. Real corpus files are never mutated.

Run:
    python3 suite.py --out <abs evaluation/out/recipes> --repo-root <abs root>
    python3 suite.py --self-test
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
# suite_contract.py lives in evaluation/ — for this FILE that is parents[2]
# (recipes -> suites -> evaluation); the runner invokes suite.py with
# cwd = the suite directory, so resolve from the file's own path.
_eval_dir = str(Path(__file__).resolve().parents[2])
if _eval_dir not in sys.path:
    sys.path.insert(0, _eval_dir)

import bands  # noqa: E402
import rs  # noqa: E402
import rights  # noqa: E402
import suite_contract  # noqa: E402

SUITE_DIR = Path(__file__).resolve().parent
CORPUS_DIR = SUITE_DIR / "corpus"

# SCORECARD row C bars (the suite declares bars; the contract derives status)
BAR_RIGHTS = {"op": ">=", "value": 400, "label": ">= 400 rights-clear recipes (programme target 1,500)"}
BAR_LINTER = {"op": "==", "value": 100, "label": "100% of corpus passes the food-safety linter"}
BAR_QTY = {"op": ">=", "value": 95, "label": ">= 95% of lines resolved with quantity evidence"}
BAR_CLAIMS = {"op": "==", "value": 0, "label": "0 unchecked allergen/diet claims"}
BAR_COVERAGE = {"op": "==", "value": 100, "label": "every declared cuisine/time band represented"}


# ---------------------------------------------------------------------------
# corpus + inputs
# ---------------------------------------------------------------------------


def load_corpus() -> tuple[list[dict[str, Any]], str | None]:
    """Load the committed corpus (authored seed + composed expansion).

    Returns (recipes, error). error is None when both files load.
    """
    recipes: list[dict[str, Any]] = []
    missing: list[str] = []
    for name in ("authored.json", "composed.json"):
        p = CORPUS_DIR / name
        if not p.is_file():
            missing.append(str(p.relative_to(SUITE_DIR)))
            continue
        data = json.loads(p.read_text())
        recipes.extend(data.get("recipes", []))
    if missing:
        return recipes, "missing corpus input(s): " + ", ".join(missing)
    return recipes, None


def load_json(path: Path) -> tuple[Any, str | None]:
    if not path.is_file():
        return None, f"missing input: {path.relative_to(SUITE_DIR)}"
    try:
        return json.loads(path.read_text()), None
    except json.JSONDecodeError as exc:
        return None, f"unreadable input {path.relative_to(SUITE_DIR)}: {exc}"


# ---------------------------------------------------------------------------
# the scoring pipeline (shared by the real run and the self-test plants)
# ---------------------------------------------------------------------------


def evaluate_corpus(corpus: list[dict[str, Any]], manifest: dict[str, Any],
                    conversions: dict[str, Any], allergen_table: dict[str, Any],
                    ) -> dict[str, Any]:
    """Rights-gate, lint and cover the corpus. Returns derived metric values.

    This is the only place metrics are computed; results emission (run())
    and the self-test both go through it, so a planted lie has to survive
    THIS to flip a status.
    """
    scanner = rs.AllergenScanner(allergen_table)
    conversions_tbl = conversions.get("conversions", conversions)

    statuses = rights.validate_manifest(manifest)

    clear: list[dict[str, Any]] = []
    quarantined: list[str] = []
    for r in corpus:
        ref = r.get("source_ref")
        rec = statuses.get(ref)
        if rec and rec["status"] == "clear":
            clear.append(r)
        else:
            quarantined.append(
                f"{r.get('id', '?')} ({(rec or {}).get('reason', 'no manifest record')})")

    # precompute allergen classes for the linter's safety rule (R3)
    for r in clear:
        r["_classes"] = sorted(scanner.classes_for(r))

    lint = rs.lint_corpus(
        clear,
        cuisines=bands.CUISINE_SET,
        meal_slots=bands.SLOT_SET,
        conversions=conversions_tbl,
        allergen_scan=scanner,
    )

    cov = bands.coverage(clear)

    n = len(clear)
    linter_n = len(lint["passed"])
    linter_pct = round(100.0 * linter_n / n, 2) if n else 0.0
    total_lines = lint["total_lines"]
    resolved_pct = round(100.0 * lint["resolved_lines"] / total_lines, 2) if total_lines else 0.0
    coverage_pct = round(100.0 * cov["represented"] / cov["total_declared"], 2) \
        if cov["total_declared"] else 0.0

    return {
        "rights_clear_count": n,
        "quarantined": quarantined,
        "linter_pct": linter_pct,
        "linter_passed": linter_n,
        "linter_total": n,
        "violations": lint["recipes_with_violations"],
        "resolved_pct": resolved_pct,
        "total_lines": total_lines,
        "resolved_lines": lint["resolved_lines"],
        "unchecked_claims": lint["unchecked_claims"],
        "stripped_claims": lint["stripped_claims"],
        "coverage": cov,
        "coverage_pct": coverage_pct,
    }


def metric_list(ev: dict[str, Any], out_dir: Path) -> list[dict[str, Any]]:
    """Emit the five scorecard metrics from derived values.

    Statuses are NOT declared: `suite_contract.derive_status` computes them
    from value + bar at validation time (and the runner re-derives).
    """
    # evidence files written next to results.json
    (out_dir / "coverage.json").write_text(json.dumps(ev["coverage"], indent=2) + "\n")
    (out_dir / "lint_report.json").write_text(json.dumps({
        "recipes_with_violations": ev["violations"],
        "linter_passed": ev["linter_passed"],
        "linter_total": ev["linter_total"],
        "total_lines": ev["total_lines"],
        "resolved_lines": ev["resolved_lines"],
        "unchecked_claims": ev["unchecked_claims"],
        "stripped_claims": ev["stripped_claims"],
    }, indent=2) + "\n")
    (out_dir / "quarantined.json").write_text(json.dumps({
        "count": len(ev["quarantined"]), "recipes": ev["quarantined"],
    }, indent=2) + "\n")

    metrics: list[dict[str, Any]] = [
        {
            "id": "rights_clear_recipes",
            "metric": "Rights-clear recipes (complete per-recipe manifest evidence)",
            "value": ev["rights_clear_count"],
            "bar": BAR_RIGHTS,
            "detail": (f"{ev['rights_clear_count']} rights-clear; "
                       f"{len(ev['quarantined'])} quarantined (fail-closed; see quarantined.json). "
                       "Bundled-catalog audit: see bundled_rights_audit.json."),
            "evidence": {"path": "rights_manifest.json",
                         "note": "per-recipe manifest validated by rights.validate_manifest"},
        },
        {
            "id": "food_safety_linter_pass",
            "metric": "Food-safety linter pass (% of corpus)",
            "value": ev["linter_pct"],
            "bar": BAR_LINTER,
            "detail": (f"{ev['linter_passed']}/{ev['linter_total']} recipes pass the RS linter "
                       f"(R1 schema, R2 quantity evidence, R3 FSIS thermometer checks, "
                       f"R4 claim evidence, R5 timers); see lint_report.json."),
            "evidence": {"path": "lint_report.json",
                         "note": "per-recipe violations listed with ids"},
        },
        {
            "id": "lines_with_quantity_evidence",
            "metric": "Lines resolved with quantity evidence (%)",
            "value": ev["resolved_pct"],
            "bar": BAR_QTY,
            "detail": (f"{ev['resolved_lines']}/{ev['total_lines']} ingredient lines resolve to "
                       "grams (weighed, source_grams, or household measure with a conversion); "
                       "unknown-quantity lines are honest but unresolved."),
            "evidence": {"path": "lint_report.json", "note": "line counts from the linter"},
        },
        {
            "id": "unchecked_allergen_diet_claims",
            "metric": "Unchecked allergen/diet claims (after linter strip)",
            "value": ev["unchecked_claims"],
            "bar": BAR_CLAIMS,
            "detail": (f"{ev['stripped_claims']} unchecked claim(s) stripped by the linter; "
                       f"{ev['unchecked_claims']} remain unchecked."),
            "evidence": {"path": "lint_report.json", "note": "claim counts"},
        },
        {
            "id": "cuisine_time_band_coverage",
            "metric": "Declared cuisines and time bands represented (%)",
            "value": ev["coverage_pct"],
            "bar": BAR_COVERAGE,
            "detail": (f"{ev['coverage']['represented']}/{ev['coverage']['total_declared']} declared "
                       f"bands hold >=1 recipe; missing: {ev['coverage']['missing'] or 'none'}. "
                       f"Cross-product cells filled: {ev['coverage']['cross_product_filled']}/"
                       f"{ev['coverage']['cross_product_cells']} (informational). "
                       "Per-band counts in coverage.json."),
            "evidence": {"path": "coverage.json", "note": "per-band counts"},
        },
    ]
    return metrics


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------


def run(out_dir: Path, repo_root: Path | None) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    results: dict[str, Any] = {
        "suite": "recipes",
        "letter": "C",
        "title": "Recipe corpus quality and rights",
        "run_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": {"python": sys.version.split()[0]},
        "metrics": [],
    }

    not_run: list[dict[str, Any]] = []

    corpus, err = load_corpus()
    if err:
        not_run.append(("corpus", err))
    manifest, err = load_json(SUITE_DIR / "rights_manifest.json")
    if err:
        not_run.append(("manifest", err))
    conversions, err = load_json(SUITE_DIR / "conversions.json")
    if err:
        not_run.append(("conversions", err))
    allergens, err = load_json(SUITE_DIR / "allergens.json")
    if err:
        not_run.append(("allergens", err))

    if not_run:
        for name, reason in not_run:
            print(f"  not-run: {name}: {reason}")
        metrics: list[dict[str, Any]] = []
        # every metric that needs the missing input is not-run with the reason
        reasons = "; ".join(r for _, r in not_run)
        for mid, label in (
            ("rights_clear_recipes", "Rights-clear recipes"),
            ("food_safety_linter_pass", "Food-safety linter pass (%)"),
            ("lines_with_quantity_evidence", "Lines resolved with quantity evidence (%)"),
            ("unchecked_allergen_diet_claims", "Unchecked allergen/diet claims"),
            ("cuisine_time_band_coverage", "Declared cuisines and time bands represented (%)"),
        ):
            metrics.append({"id": mid, "metric": label, "status": "not-run", "reason": reasons})
        results["metrics"] = metrics
    else:
        assert manifest is not None and conversions is not None and allergens is not None
        ev = evaluate_corpus(corpus, manifest, conversions, allergens)

        # bundled catalog audit: read-only, evidence for the rights metric
        if repo_root is not None:
            audit = rights.audit_bundled_catalog(repo_root, out_dir)
            (out_dir / "bundled_rights_audit.json").write_text(
                json.dumps(audit, indent=2) + "\n")
            print(f"  bundled catalog audit: {audit.get('recipes_audited', 0)} recipes, "
                  f"{audit.get('quarantined', 0)} quarantined, "
                  f"{audit.get('rights_clear', 0)} rights-clear in-bundle")

        results["metrics"] = metric_list(ev, out_dir)

    results = suite_contract.validate_results(results, expected_suite_id="recipes")
    (out_dir / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    for m in results["metrics"]:
        print(f"  {m['id']}: {m.get('status')} (value={m.get('value', '-')})")
    return results


# ---------------------------------------------------------------------------
# self-test: planted sabotage must flip the derived status to fail
# ---------------------------------------------------------------------------


def _mini_fixtures() -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """A tiny well-formed corpus + manifest for planting sabotage into."""
    good = {
        "rs_version": "1", "id": "fix-ok", "title": "OK recipe",
        "cuisine": "asian", "meal_slots": ["dinner"], "minutes": 20,
        "servings": 2,
        "ingredients": [
            {"name": "tofu", "qty": {"kind": "household", "value": 1, "unit": "block",
                                     "grams": 350, "conversion_ref": "tofu_block"}},
            {"name": "rice vinegar", "qty": {"kind": "household", "value": 1, "unit": "tbsp",
                                             "grams": 15, "conversion_ref": "rice_vinegar_tbsp"}},
        ],
        "steps": [{"text": "Sear, then serve over rice."}],
        "claims": [], "source_ref": "test:ok", "provenance": "test",
    }
    manifest = {"records": {
        "test:ok": {
            "source_id": "test:ok", "source_type": "original", "origin": "test",
            "license": "LicenseRef-FL-Original", "access_date": "2026-10-11",
            "license_evidence": "test fixture",
            "permissions": {"text": True, "images": False, "modification": True,
                            "attribution": True, "caching": True, "offline_use": True},
        },
    }}
    return [copy.deepcopy(good)], manifest


def _tables() -> tuple[dict[str, Any], dict[str, Any]]:
    conversions = json.loads((SUITE_DIR / "conversions.json").read_text())
    allergens = json.loads((SUITE_DIR / "allergens.json").read_text())
    return conversions, allergens


def self_test() -> int:
    conversions, allergens = _tables()

    def derived(corpus: list[dict[str, Any]], manifest: dict[str, Any]) -> dict[str, str]:
        ev = evaluate_corpus(copy.deepcopy(corpus), manifest, conversions, allergens)
        metrics = metric_list(copy.deepcopy(ev), Path("/tmp"))  # evidence to /tmp
        return {m["id"]: suite_contract.derive_status(m) for m in metrics}

    caught = 0
    planted = 5

    # P1 corrupted fixture: quantity evidence destroyed on a line
    corpus, manifest = _mini_fixtures()
    broken = copy.deepcopy(corpus)
    broken[0]["ingredients"][0]["qty"] = {"kind": "household", "value": 1,
                                          "unit": "block", "conversion_ref": "nonexistent_ref"}
    st = derived(broken, manifest)
    ok1 = st["food_safety_linter_pass"] == "fail"
    caught += ok1
    print(f"  P1 corrupted fixture (invented conversion): "
          f"{'caught' if ok1 else 'MISSED'} (food_safety_linter_pass={st['food_safety_linter_pass']})")

    # P2 flipped label: vegan claim over a meat ingredient
    corpus, manifest = _mini_fixtures()
    flipped = copy.deepcopy(corpus)
    flipped[0]["ingredients"][0] = {
        "name": "chicken thighs",
        "qty": {"kind": "household", "value": 3, "unit": "piece", "grams": 360,
                "conversion_ref": "chicken_thigh_piece"}}
    flipped[0]["claims"] = [{"claim": "vegan", "evidence": {"conflicts": []}}]
    st = derived(flipped, manifest)
    ok2 = st["unchecked_allergen_diet_claims"] == "fail"
    caught += ok2
    print(f"  P2 flipped label (vegan over chicken): "
          f"{'caught' if ok2 else 'MISSED'} (unchecked_allergen_diet_claims={st['unchecked_allergen_diet_claims']})")

    # P3 lying emitter: a 'pass' declared on a violated bar
    liar = {"id": "rights_clear_recipes", "metric": "Rights-clear recipes",
            "value": 3, "bar": BAR_RIGHTS, "status": "pass"}
    st3 = suite_contract.derive_status(liar)
    ok3 = st3 == "fail"
    caught += ok3
    print(f"  P3 lying emitter (pass declared on value=3, bar>=400): "
          f"{'caught' if ok3 else 'MISSED'} (derived={st3})")

    # P4 missing rights record: recipe falls out of the rights-clear corpus
    corpus, manifest = _mini_fixtures()
    short_manifest = copy.deepcopy(manifest)
    short_manifest["records"].pop("test:ok")
    st = derived(corpus, short_manifest)
    ok4 = st["rights_clear_recipes"] == "fail"
    caught += ok4
    print(f"  P4 missing rights record: "
          f"{'caught' if ok4 else 'MISSED'} (rights_clear_recipes={st['rights_clear_recipes']})")

    # P5 coverage hole: a corpus that misses declared bands
    corpus, manifest = _mini_fixtures()
    st = derived(corpus, manifest)
    ok5 = st["cuisine_time_band_coverage"] == "fail"
    caught += ok5
    print(f"  P5 coverage hole (1 recipe vs all declared bands): "
          f"{'caught' if ok5 else 'MISSED'} (cuisine_time_band_coverage={st['cuisine_time_band_coverage']})")

    print(f"caught {caught}/{planted} planted failures")
    return 0 if caught == planted else 1


# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Suite C: recipe corpus quality and rights")
    ap.add_argument("--out", default=None, help="abs output dir (evaluation/out/recipes); required unless --self-test")
    ap.add_argument("--repo-root", default=None, help="abs repo root (for the bundled audit)")
    ap.add_argument("--self-test", action="store_true", help="run the planted-failure self-test")
    args = ap.parse_args()

    if args.self_test:
        sys.exit(self_test())

    if not args.out:
        ap.error("--out is required unless --self-test")

    if args.repo_root:
        repo_root = Path(args.repo_root).resolve()
    else:
        # default: the repo root is two directories up (evaluation/suites/recipes)
        repo_root = SUITE_DIR.parents[2]
        if not (repo_root / "evaluation").is_dir():
            repo_root = None
    results = run(Path(args.out).resolve(), repo_root)
    n_pass = sum(1 for m in results["metrics"] if m.get("status") == "pass")
    n_total = len(results["metrics"])
    print(f"suite recipes: {n_pass}/{n_total} metrics pass")
    return 0


if __name__ == "__main__":
    main()
