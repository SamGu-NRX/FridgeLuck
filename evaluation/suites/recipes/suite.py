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

Self-test (SCORECARD.md): a planted-failure battery plus passing controls.
Passing controls first: a 400-recipe synthetic corpus with complete rights
records and every canonical doneness pattern (poultry 165F, ground poultry
165F, whole cuts 145F + 3-minute rest, fish 145F, egg 160F, reheat/casserole
165F) must derive ALL FIVE metrics as pass. Then 12 plants re-introduce the
PR #88 BLOCK defects one at a time (uncited conversions, flipped labels, a
lying emitter, denied permissions, coverage holes, wrong-class/lower-temp/
restless doneness checks, unknown-composition claims, mislabeled `weighed`,
and scoring the suite's own fixtures) and each must flip the derived status
to fail. Prints `caught k/12 planted failures` + `controls m/1 held` and
exits 0 only when every plant is caught and every control holds. Real
corpus files are never mutated.

Run:
    python3 suite.py --out <abs evaluation/out/recipes> --repo-root <abs root>
    python3 suite.py --self-test
"""

from __future__ import annotations

import argparse
import copy
import itertools
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


def _fsis_source() -> str:
    """The RS safety source string the canon rulebook directs corpora to cite."""
    return ("USDA FSIS Safe Minimum Internal Temperature Chart, "
            "https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/"
            "food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11")


# Protein rotation for the control corpus: (name, FSIS class, temp_f, rest_min).
# Covers every canon doneness pattern: poultry 165, ground poultry 165 (never
# meat_ground 160), whole cuts 145 + 3-minute rest, fish 145, egg 160.
_PROTEIN_ROTATION = (
    ("chicken thighs", "meat_poultry", 165, 0),
    ("ground turkey", "meat_poultry", 165, 0),
    ("pork loin", "meat_whole_cut_pork", 145, 3),
    ("beef steak", "meat_whole_cut_red", 145, 3),
    ("salmon fillet", "flesh_fish", 145, 0),
    ("eggs", "egg", 160, 0),
)

_STAPLE_ROTATION = (
    ("cooked rice", "cup", 175, "cooked_rice_cup"),
    ("broccoli", "cup", 90, "broccoli_cup"),
    ("chickpeas", "cup", 165, "chickpeas_cup"),
    ("tofu", "block", 350, "tofu_block"),
    ("brown rice", "cup", 195, "cooked_brown_rice_cup"),
)


def _ctl_recipe(i: int, cuisine: str, slot: str, minutes: int) -> dict[str, Any]:
    """One clean schema-true control recipe. Deterministic in i."""
    protein, p_cls, p_temp, p_rest = _PROTEIN_ROTATION[i % len(_PROTEIN_ROTATION)]
    staple, s_unit, s_grams, s_ref = _STAPLE_ROTATION[i % len(_STAPLE_ROTATION)]
    source = _fsis_source()

    if p_rest:
        protein_text = (f"Roast the {protein} to temperature, checking with a "
                        "thermometer, then rest for at least 3 minutes before serving.")
    else:
        protein_text = f"Cook the {protein}, checking with a thermometer before serving."
    steps: list[dict[str, Any]] = [
        {"text": protein_text,
         "safety": {"class": p_cls, "temp_f": p_temp, "method": "thermometer",
                    "source": source}},
        {"text": f"Cook the {staple} until tender and season to taste."},
    ]
    title = f"Control Dish {i:04d}"
    if i % 7 == 0:  # casserole-titled: combination dishes must reach 165 F
        title = f"{cuisine.title()} {protein.title()} Casserole"
        steps.append({"text": "Bake the dish and verify the centre with a thermometer.",
                      "safety": {"class": "leftovers", "temp_f": 165,
                                 "method": "thermometer", "source": source}})
    if i % 5 == 0:  # reheat step: leftovers must reach 165 F with a thermometer
        steps.append({"text": "Next day, reheat a portion, checking with a thermometer.",
                      "reheat": True,
                      "safety": {"class": "leftovers", "temp_f": 165,
                                 "method": "thermometer", "source": source}})
    return {
        "rs_version": "1", "id": f"ctl-{i:04d}", "title": title,
        "cuisine": cuisine, "meal_slots": [slot], "minutes": minutes, "servings": 2,
        "ingredients": [
            {"name": protein, "qty": {"kind": "source_grams", "grams": 300}},
            {"name": staple, "qty": {"kind": "household", "value": 1, "unit": s_unit,
                                     "grams": s_grams, "conversion_ref": s_ref}},
            {"name": "rice vinegar", "qty": {"kind": "household", "value": 1,
                                             "unit": "tbsp", "grams": 15,
                                             "conversion_ref": "rice_vinegar_tbsp"}},
        ],
        "steps": steps,
        "claims": [], "source_ref": f"ctl-src-{i:04d}", "provenance": "suite-selftest",
    }


def _ctl_rights_record(source_ref: str, *, permissions_all_true: bool = True) -> dict[str, Any]:
    flag = permissions_all_true
    return {
        "source_id": source_ref, "source_type": "original", "origin": "suite-selftest",
        "license": "LicenseRef-FL-Original", "access_date": "2026-10-11",
        "license_evidence": "suite C self-test control (original work)",
        "permissions": {"text": flag, "images": False, "modification": flag,
                        "attribution": flag, "caching": flag, "offline_use": flag},
    }


def _control_corpus(n_recipes: int = 400) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """A deterministic control corpus spanning every declared band, with one
    complete rights record per recipe. Every canon doneness pattern appears
    and PASSES, so each plant below is the only difference from a passing run.
    """
    combos = [
        (c, s, (lo + min(hi, 90)) // 2)
        for c, s, (_name, lo, hi) in itertools.product(
            bands.CUISINES, bands.MEAL_SLOTS, bands.TIME_BANDS)
    ]
    recipes = [_ctl_recipe(i, *combos[i % len(combos)]) for i in range(n_recipes)]
    manifest = {"records": {
        f"ctl-src-{i:04d}": _ctl_rights_record(f"ctl-src-{i:04d}")
        for i in range(n_recipes)
    }}
    return recipes, manifest


def _planted_mini(recipe_mutator,
                  manifest_mutator: Any = None,
                  ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Mini fixture (one recipe + manifest) with a plant applied."""
    corpus, manifest = _mini_fixtures()
    recipe_mutator(corpus[0])
    if manifest_mutator:
        manifest_mutator(manifest)
    return corpus, manifest





def self_test() -> int:
    """Planted-failure battery for the suite C defect fixes.

    Passing controls: a 400-recipe corpus with complete rights records and
    every canon doneness pattern present must derive ALL FIVE metrics as
    pass — proving the gates are satisfiable, not vacuously failing (the
    review BLOCK on PR #88 demanded exactly these controls).

    Planted failures: each plant mutates the control or the mini fixture to
    reintroduce one defect the BLOCK lists, and asserts the derived status
    flips to fail. The battery exits 0 only when every control holds and
    every plant is caught; a planted failure that goes uncaught is a defect
    again, so the battery fails.
    """
    conversions, allergens = _tables()

    def derived(corpus: list[dict[str, Any]], manifest: dict[str, Any],
                ) -> tuple[dict[str, str], dict[str, Any]]:
        ev = evaluate_corpus(copy.deepcopy(corpus), manifest, conversions, allergens)
        metrics = metric_list(copy.deepcopy(ev), Path("/tmp"))  # evidence to /tmp
        return {m["id"]: suite_contract.derive_status(m) for m in metrics}, ev

    caught = 0
    controls_held = 0
    plants_total = 0

    def plant(label: str, ok: bool, detail: str) -> None:
        nonlocal caught, plants_total
        plants_total += 1
        caught += ok
        print(f"  plant {label}: {'caught' if ok else 'MISSED'} ({detail})")

    # ---- passing control: the 400-recipe clean corpus must derive all-pass --
    control, control_manifest = _control_corpus()
    st, ev = derived(control, control_manifest)
    ctrl_ok = (all(s == "pass" for s in st.values())
               and ev["rights_clear_count"] == 400)
    controls_held += ctrl_ok
    print(f"  control clean 400-recipe corpus derives all five metrics pass: "
          f"{'held' if ctrl_ok else 'BROKEN'} "
          f"({', '.join(f'{k}={v}' for k, v in st.items())})")

    # P1 corrupted fixture: a household line citing a conversion it does not carry
    def _p1(r: dict[str, Any]) -> None:
        r["ingredients"][0]["qty"] = {"kind": "household", "value": 1, "unit": "block",
                                      "conversion_ref": "nonexistent_ref"}
    st, _ = derived(*_planted_mini(_p1))
    plant("P1 household line without cited gram evidence",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # P2 flipped label: vegan claim over a meat ingredient
    def _p2(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {
            "name": "chicken thighs",
            "qty": {"kind": "source_grams", "grams": 360}}
        r["claims"] = [{"claim": "vegan", "evidence": {"conflicts": []}}]
    st, _ = derived(*_planted_mini(_p2))
    plant("P2 vegan claim over chicken", st["unchecked_allergen_diet_claims"] == "fail",
          f"unchecked_allergen_diet_claims={st['unchecked_allergen_diet_claims']}")

    # P3 lying emitter: a 'pass' declared on a violated bar
    liar = {"id": "rights_clear_recipes", "metric": "Rights-clear recipes",
            "value": 3, "bar": BAR_RIGHTS, "status": "pass"}
    st3 = suite_contract.derive_status(liar)
    plant("P3 lying emitter (pass declared on value=3, bar>=400)", st3 == "fail",
          f"derived={st3}")

    # P4 denied permissions: flipping one control record's permissions to all
    # false must drop the count below the bar. On a tree where a record with
    # every permission denied still counts as rights-clear, this stays MISSED.
    flipped_corpus, flipped_manifest = _control_corpus()
    flipped_manifest["records"]["ctl-src-0000"]["permissions"] = {
        "text": False, "images": False, "modification": False, "attribution": False,
        "caching": False, "offline_use": False}
    st, _ = derived(flipped_corpus, flipped_manifest)
    plant("P4 record with every permission denied counts as rights-clear",
          st["rights_clear_recipes"] == "fail",
          f"rights_clear_recipes={st['rights_clear_recipes']}")

    # P5 coverage hole: the control corpus minus one cuisine
    hole_corpus, hole_manifest = _control_corpus()
    hole_corpus = [r for r in hole_corpus if r["cuisine"] != "indian"]
    st, _ = derived(hole_corpus, hole_manifest)
    plant("P5 coverage hole (control minus one cuisine)",
          st["cuisine_time_band_coverage"] == "fail",
          f"cuisine_time_band_coverage={st['cuisine_time_band_coverage']}")

    # D1a actual-class coverage: a chicken recipe carrying ONLY a fish-class
    # 145 F check. The ingredient's actual class (meat_poultry, 165 F) is never
    # checked — this is the BLOCK's rs.py:148-164 scenario.
    def _d1a(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "chicken thighs",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [{"text": "Sear the chicken thighs in a hot pan, checking "
                               "with a thermometer before serving.",
                       "safety": {"class": "flesh_fish", "temp_f": 145,
                                  "method": "thermometer", "source": _fsis_source()}}]
    st, _ = derived(*_planted_mini(_d1a))
    plant("D1a chicken recipe passes with a fish-class 145F check",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D1b reheat gating: a reheat step with no thermometer check while an
    # unrelated (valid) whole-cut check exists elsewhere in the recipe.
    def _d1b(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "pork loin",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [
            {"text": "Roast the pork loin to temperature with a thermometer, then "
                     "rest for at least 3 minutes before serving.",
             "safety": {"class": "meat_whole_cut_pork", "temp_f": 145,
                        "method": "thermometer", "source": _fsis_source()}},
            {"text": "Next day, reheat a portion and serve.", "reheat": True},
        ]
    st, _ = derived(*_planted_mini(_d1b))
    plant("D1b reheat step passes on an unrelated lower-threshold check",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D1c required rest: a whole-cut check at 145 F with no 3-minute rest
    # stated anywhere (not in the step text, not on the check).
    def _d1c(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "beef steak",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [{"text": "Sear the beef steak, checking with a thermometer "
                               "before serving.",
                       "safety": {"class": "meat_whole_cut_red", "temp_f": 145,
                                  "method": "thermometer", "source": _fsis_source()}}]
    st, _ = derived(*_planted_mini(_d1c))
    plant("D1c whole-cut check without the required 3-minute rest",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D1d ground poultry: a ground-turkey check citing meat_ground at 160 F.
    # The canon requires ground poultry at meat_poultry 165 F.
    def _d1d(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "ground turkey",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [{"text": "Brown the ground turkey, checking with a "
                               "thermometer before serving.",
                       "safety": {"class": "meat_ground", "temp_f": 160,
                                  "method": "thermometer", "source": _fsis_source()}}]
    st, _ = derived(*_planted_mini(_d1d))
    plant("D1d ground poultry checked at meat_ground 160F",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D2 unknown composition: an ingredient name no table resolves, carrying a
    # dairy-free claim with empty recorded conflicts. Unknown composition must
    # make the claim UNCHECKED, never clear (BLOCK's rs.py:259-285).
    def _d2(r: dict[str, Any]) -> None:
        r["ingredients"] = [
            {"name": "cream cheese",
             "qty": {"kind": "source_grams", "grams": 200}},
            {"name": "rice vinegar",
             "qty": {"kind": "household", "value": 1, "unit": "tbsp", "grams": 15,
                     "conversion_ref": "rice_vinegar_tbsp"}},
        ]
        r["claims"] = [{"claim": "dairy-free", "evidence": {"conflicts": []}}]
    st, _ = derived(*_planted_mini(_d2))
    plant("D2 dairy-free claim clears over an unresolvable ingredient",
          st["unchecked_allergen_diet_claims"] == "fail",
          f"unchecked_allergen_diet_claims={st['unchecked_allergen_diet_claims']}")

    # D5 mislabeled 'weighed': a builder constant labeled weighed with no scale
    # measurement recorded (BLOCK's corpus_build.py:369-372).
    def _d5(r: dict[str, Any]) -> None:
        r["ingredients"][0]["qty"] = {"kind": "weighed", "grams": 350}
    st, _ = derived(*_planted_mini(_d5))
    plant("D5 'weighed' line with no recorded scale measurement",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D4 scored input: run() must grade the scored tree's data/recipes corpus,
    # not this suite's own fixtures (BLOCK's suite.py:77-93). A temp repo-root
    # with a one-recipe corpus must produce rights_clear_count == 1.
    import tempfile
    with tempfile.TemporaryDirectory(prefix="suite-c-d4-") as td:
        tmp_root = Path(td) / "repo"
        (tmp_root / "data" / "recipes").mkdir(parents=True)
        d4_corpus, _ = _mini_fixtures()
        d4_corpus[0]["source_ref"] = "temp:ok"
        (tmp_root / "data" / "recipes" / "corpus.jsonl").write_text(
            json.dumps(d4_corpus[0]) + "\n")
        (tmp_root / "data" / "recipes" / "rights_manifest.json").write_text(
            json.dumps({"records": {"temp:ok": _ctl_rights_record("temp:ok")}}) + "\n")
        results_d4 = run(Path(td) / "out", tmp_root)
    d4_value = results_d4["metrics"][0]["value"]
    plant("D4 suite grades its own fixtures instead of the scored tree",
          d4_value == 1,
          f"rights_clear value scored from repo-root corpus = {d4_value} (want 1)")

    print(f"caught {caught}/{plants_total} planted failures; "
          f"controls {controls_held}/1 held")
    return 0 if (caught == plants_total and controls_held == 1) else 1


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
