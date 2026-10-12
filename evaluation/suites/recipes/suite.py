#!/usr/bin/env python3
"""Suite C — recipe corpus quality and rights.

Metrics (bars from PLAN.md's scorecard table via SCORECARD.md row C):

1. rights_clear_recipes   >= 400 recipes with complete per-recipe rights
                          evidence (programme target 1,500). A recipe counts
                          only when its manifest record is COMPLETE per
                          rights.py (source, source type, origin, license,
                          license evidence, access date, and every REQUIRED
                          permission affirmative — text, modification,
                          caching, offline_use, plus attribution when the
                          work is not a FridgeLuck original and images when
                          images ship). One denied or absent permission
                          fails and the record is quarantined.
2. food_safety_linter     == 100% of rights-clear corpus recipes pass the RS
                          linter (schema, quantity evidence, canon-rulebook
                          doneness checks, bounded timers, claim evidence).
3. quantity_evidence      >= 95% of ingredient lines across the rights-clear
                          corpus resolve to grams (weighed-with-scale-
                          evidence / source_grams / household-with-cited-
                          conversion). Unknown-quantity lines are honest but
                          count as unresolved.
4. unchecked_claims       == 0 allergen/diet claims without machine evidence
                          after the linter strips unchecked ones.
5. coverage               == 100% of the bands declared in bands.py hold at
                          least one rights-clear recipe (meal slots x time
                          bands x cuisines; marginal coverage per axis).

SCORED INPUTS (never this suite's own fixtures):

- the scored repo root's data/recipes/corpus.jsonl, plus
  data/recipes/originals/originals.jsonl and the tree's own rights
  manifests, when present (invoked as:
  python3 suite.py --out <abs out> --repo-root <abs repo root>);
- otherwise the bundled catalog (apps/ios/Resources/data.json) as an honest
  BASELINE: positional records with no per-recipe rights evidence, so
  0 rights-clear and the suite FAILS it outright.

The suite's authored/composed fixtures, conversions table and rights
manifest live under fixtures/selftest/ and feed ONLY the planted-failure
self-test. When no rights-clear recipe exists, metrics 2-5 report not-run
with the reason rather than vacuous values (a quarantined corpus scores
nothing). Missing inputs report not-run with a precise reason, never pass.

Identity: the runner renders the scorecard row from the run payload's
letter/title. They are loaded from suite.json at module load (hard exit if
undeclared — a payload without them renders `?. <id>`) and stamped on the
payload; check_identity() verifies a payload against suite.json and the
battery plants an identity-drifted payload to prove drift is caught.

Self-test (SCORECARD.md): a planted-failure battery plus passing controls.
Passing controls first: a 400-recipe synthetic corpus with complete rights
records and every canonical doneness pattern (poultry 165F, ground poultry
165F, whole cuts 145F + 3-minute rest, fish 145F, egg 160F, reheat/casserole
165F) must derive ALL FIVE metrics as pass. Then 19 plants re-introduce the
PR #88 BLOCK defects one at a time (uncited conversions, flipped labels, a
lying emitter, denied permissions, coverage holes, wrong-class/lower-temp/
restless doneness checks, an oven setting passing as the internal reading,
metadata-only doneness with a too-short rest, a rest_minutes metadata value
overriding the rest the cook reads in the text,
no-canon escapes, unclassified proteins, an invalid canonical rulebook,
unknown-composition claims, mislabeled `weighed`, scoring the suite's own
fixtures, and identity drift) and each must flip the
derived status to fail. Prints `caught k/19 planted failures` +
`controls m/2 held` and exits 0 only when every plant is caught and every
control holds. Real corpus files are never mutated.

Run:
    python3 suite.py --out <abs evaluation/out/recipes> --repo-root <abs root>
    python3 suite.py --self-test
"""

from __future__ import annotations

import argparse
import copy
import itertools
import json
import os
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
CORPUS_DIR = SUITE_DIR / "fixtures" / "selftest"


def _load_identity() -> tuple[str, str]:
    """The suite's letter/title from suite.json.

    The runner renders the scorecard row from the run payload's letter/title;
    a payload without them renders `?. <id>`. Loading at module import and
    hard-exiting on an undeclared identity keeps every emission path stamped
    from the one source of truth (same fix suite A shipped at 564482c5).
    """
    try:
        manifest = json.loads((SUITE_DIR / "suite.json").read_text())
        letter, title = str(manifest["letter"]), str(manifest["title"])
        if not letter or not title:
            raise ValueError("letter/title must be non-empty strings")
        return letter, title
    except (OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
        sys.exit(f"recipes: suite.json must declare letter/title (SCORECARD.md): {exc}")


SUITE_LETTER, SUITE_TITLE = _load_identity()


def check_identity(payload: dict[str, Any]) -> bool:
    """True when a run payload's letter/title match suite.json exactly."""
    return (payload.get("letter") == SUITE_LETTER
            and payload.get("title") == SUITE_TITLE)

# SCORECARD row C bars (the suite declares bars; the contract derives status)
BAR_RIGHTS = {"op": ">=", "value": 400, "label": ">= 400 rights-clear recipes (programme target 1,500)"}
BAR_LINTER = {"op": "==", "value": 100, "label": "100% of corpus passes the food-safety linter"}
BAR_QTY = {"op": ">=", "value": 95, "label": ">= 95% of lines resolved with quantity evidence"}
BAR_CLAIMS = {"op": "==", "value": 0, "label": "0 unchecked allergen/diet claims"}
BAR_COVERAGE = {"op": "==", "value": 100, "label": "every declared cuisine/time band represented"}


# ---------------------------------------------------------------------------
# scored inputs: the product tree's corpus, else the bundled baseline
# ---------------------------------------------------------------------------

BUNDLED_CATALOG_CANDIDATES = ("apps/ios/Resources/data.json",   # eval branches
                              "assets/recipes.json")             # suite C brief


def _read_product_jsonl(path: Path, repo_root: Path
                        ) -> tuple[list[dict[str, Any]], str | None]:
    """Parse one product JSONL corpus file; returns (recipes, error)."""
    recipes: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError as exc:
            return [], (f"unreadable {path.relative_to(repo_root)} line {lineno}: {exc}")
        if not isinstance(rec, dict) or not rec.get("id"):
            return [], (f"{path.relative_to(repo_root)} line {lineno}: "
                        "recipe object with an id required")
        if rec["id"] in seen_ids:
            return [], (f"{path.relative_to(repo_root)}: "
                        f"duplicate recipe id {rec['id']!r}")
        seen_ids.add(rec["id"])
        recipes.append(rec)
    return recipes, None


def _read_rights_manifest(path: Path, repo_root: Path
                          ) -> tuple[dict[str, Any], str | None]:
    """Parse one rights manifest; returns (ref -> record rows, error)."""
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        return {}, f"unreadable {path.relative_to(repo_root)}: {exc}"
    rows = data.get("records", data) if isinstance(data, dict) else {}
    if not isinstance(rows, dict):
        return {}, (f"{path.relative_to(repo_root)}: rights manifest must "
                    "map source_ref -> record")
    return rows, None


# rights-substance fields: a substantive contradiction between two manifests
# for the same ref fails the run; purely descriptive differences do not
_RIGHTS_SUBSTANCE_FIELDS = ("license", "source_type", "access_date")


def _merge_rights_rows(dst: dict[str, Any], rows: dict[str, Any],
                       src_label: str) -> str | None:
    """Merge one manifest's rows into dst; substantive conflicts error."""
    for ref, mrec in rows.items():
        if ref in dst and dst[ref] != mrec:
            prior = dst[ref]
            if isinstance(prior, dict) and isinstance(mrec, dict):
                for field in _RIGHTS_SUBSTANCE_FIELDS:
                    if prior.get(field) != mrec.get(field):
                        return (f"conflicting rights records for {ref!r} across the "
                                f"tree's manifests: {field} differs ({src_label})")
            else:
                return (f"conflicting rights records for {ref!r} across the "
                        f"tree's manifests ({src_label})")
        dst[ref] = mrec
    return None


def load_scored_corpus(repo_root: Path
                       ) -> tuple[list[dict[str, Any]], dict[str, Any], str, str | None]:
    """Load the corpus suite C scores, with the tree's own rights evidence.

    Each product source is scored INDEPENDENTLY as product data, with the
    rights evidence its own tree carries:

    1. data/recipes/corpus.jsonl (PR #113) — the ingested corpus of record;
    2. data/recipes/originals/originals.jsonl (PR #107) — the originals.

    When both are present, originals already ingested into corpus.jsonl are
    skipped by id (counted and described in the scored-input line) and the
    corpus of record's manifest governs the ingested refs after a
    rights-substance check (license, source type, access date and
    permissions must agree — a substantive contradiction still fails the
    run); originals NOT ingested score from their own manifest.

    Only when NEITHER product source exists does the bundled catalog score,
    as an honest failing BASELINE: positional records with no per-recipe
    rights evidence — 0 rights-clear, and the suite fails it.

    Returns (recipes, manifest, description, error). The suite's own fixture
    files (fixtures/selftest/*) are NEVER scoring inputs.
    """
    product = repo_root / "data" / "recipes"
    corpus_path = product / "corpus.jsonl"
    originals_path = product / "originals" / "originals.jsonl"
    has_main = corpus_path.is_file()
    has_orig = originals_path.is_file()

    if not has_main and not has_orig:
        for rel in BUNDLED_CATALOG_CANDIDATES:
            p = repo_root / rel
            if not p.is_file():
                continue
            try:
                raw = json.loads(p.read_text())
            except (json.JSONDecodeError, OSError) as exc:
                return [], {}, "", f"unreadable {rel}: {exc}"
            decoded = rights.decode_bundled_catalog(raw)
            recipes = [{
                "rs_version": "1", "id": f"bundled-{r['bundled_id']}", "title": r["title"],
                "cuisine": None, "meal_slots": [], "minutes": r["minutes"],
                "servings": r["servings"], "ingredients": [], "steps": [],
                "claims": [], "source_ref": r.get("source_url") or f"bundled:{r['bundled_id']}",
                "_bundled": True,
            } for r in decoded]
            desc = (f"BUNDLED BASELINE (neither product source on this tree): {rel}, "
                    f"{len(recipes)} positional recipes; no per-recipe rights evidence in data")
            return recipes, {"records": {}}, desc, None
        return [], {}, "", (f"no scored corpus found under {repo_root}: "
                            "no product source (data/recipes/corpus.jsonl or "
                            "data/recipes/originals/) and no bundled catalog")

    manifest: dict[str, Any] = {"records": {}}
    manifest_paths: list[str] = []
    desc_parts: list[str] = []
    recipes: list[dict[str, Any]] = []

    if has_orig:
        orig_recipes, err = _read_product_jsonl(originals_path, repo_root)
        if err:
            return [], {}, "", err
        orig_mp = product / "originals" / "rights_manifest.json"
        orig_rows, merr = (_read_rights_manifest(orig_mp, repo_root)
                           if orig_mp.is_file() else ({}, None))
        if merr:
            return [], {}, "", merr
        err = _merge_rights_rows(manifest["records"], orig_rows,
                                 str(orig_mp.relative_to(repo_root)))
        if err:
            return [], {}, "", err
        if orig_mp.is_file():
            manifest_paths.append(str(orig_mp.relative_to(repo_root)))

    if has_main:
        main_recipes, err = _read_product_jsonl(corpus_path, repo_root)
        if err:
            return [], {}, "", err
        main_mp = product / "rights_manifest.json"
        main_rows, merr = (_read_rights_manifest(main_mp, repo_root)
                           if main_mp.is_file() else ({}, None))
        if merr:
            return [], {}, "", merr
        # the corpus of record governs ingested refs; a substantive
        # contradiction with the originals manifest still fails the run
        err = _merge_rights_rows(manifest["records"], main_rows,
                                 str(main_mp.relative_to(repo_root)))
        if err:
            return [], {}, "", err
        if main_mp.is_file():
            manifest_paths.append(str(main_mp.relative_to(repo_root)))

        main_ids = {r["id"] for r in main_recipes}
        ingested = sum(1 for r in orig_recipes if r["id"] in main_ids) if has_orig else 0
        # originals NOT already ingested score as their own product source
        not_ingested = [r for r in orig_recipes if r["id"] not in main_ids] \
            if has_orig else []
        recipes = main_recipes + not_ingested
        desc_parts.append(
            f"scored tree corpus: {corpus_path.relative_to(repo_root)} ({len(main_recipes)} recipes"
            + (f"; {ingested} of them ingested originals" if ingested else "")
            + ")"
            + (f" + {originals_path.relative_to(repo_root)} ({len(not_ingested)} not already ingested)"
               if has_orig else ""))
    else:
        recipes = orig_recipes  # originals-only tree: product data, its own manifest
        desc_parts.append(
            f"scored tree originals: {originals_path.relative_to(repo_root)} "
            f"({len(recipes)} recipes)")

    desc_parts.append("rights evidence: "
                      + (", ".join(manifest_paths) or "NONE FOUND (0 rights-clear)"))
    return recipes, manifest, "; ".join(desc_parts), None


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
                    corpus_conversions: dict[str, Any], allergen_table: dict[str, Any],
                    *, canon: "rs.CanonRulebook | None" = None,
                    scored_desc: str = "suite fixture corpus",
                    ) -> dict[str, Any]:
    """Rights-gate, lint and cover the corpus. Returns derived metric values.

    This is the only place metrics are computed; results emission (run())
    and the self-test both go through it, so a planted lie has to survive
    THIS to flip a status.

    `canon` is the validated food-safety rulebook (rs.CanonRulebook.load);
    None fails every doneness judgment closed. `corpus_conversions` is the
    scored tree's OWN conversion-evidence payload (its
    data/recipes/conversions.json, normalized ref -> row) — never a
    harness-internal table; the suite passes {} for planted corpora, whose
    records must carry their own evidence.
    """
    scanner = rs.AllergenScanner(allergen_table)

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

    lint = rs.lint_corpus(
        clear,
        cuisines=bands.CUISINE_SET,
        meal_slots=bands.SLOT_SET,
        conversion_rows=rs.as_conversion_rows(corpus_conversions),
        allergen_scan=scanner,
        canon=canon,
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
        "scored_input": scored_desc,
        "canon": (canon.source if canon is not None
                  else "UNAVAILABLE — doneness fail-closed"),
        "linter_engine": lint["linter_engine"],
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
        "stripped_detail": lint["stripped_detail"],
        "classification_incomplete": lint["classification_incomplete"],
        "coverage": cov,
        "coverage_pct": coverage_pct,
    }


def metric_list(ev: dict[str, Any], out_dir: Path) -> list[dict[str, Any]]:
    """Emit the five scorecard metrics from derived values.

    Statuses are NOT declared: `suite_contract.derive_status` computes them
    from value + bar at validation time (and the runner re-derives).
    When NO rights-clear recipe exists, the downstream metrics (2-5) are
    not-run with the reason rather than vacuous zeros — a quarantined
    corpus scores nothing.
    """
    # evidence files written next to results.json
    (out_dir / "coverage.json").write_text(json.dumps(ev["coverage"], indent=2) + "\n")
    (out_dir / "lint_report.json").write_text(json.dumps({
        "scored_input": ev["scored_input"],
        "canon": ev["canon"],
        "linter_engine": ev["linter_engine"],
        "recipes_with_violations": ev["violations"],
        "linter_passed": ev["linter_passed"],
        "linter_total": ev["linter_total"],
        "total_lines": ev["total_lines"],
        "resolved_lines": ev["resolved_lines"],
        "unchecked_claims": ev["unchecked_claims"],
        "stripped_claims": ev["stripped_claims"],
        "stripped_detail": ev["stripped_detail"],
        "classification_incomplete": ev["classification_incomplete"],
    }, indent=2) + "\n")
    (out_dir / "quarantined.json").write_text(json.dumps({
        "count": len(ev["quarantined"]), "recipes": ev["quarantined"][:200],
        "count_truncated": max(0, len(ev["quarantined"]) - 200),
    }, indent=2) + "\n")

    no_clear = not ev["rights_clear_count"]
    downstream_reason = ("no rights-clear recipes to score: the scored corpus is "
                         "quarantined outright (rights metric shows the reason)")

    def not_run_row(mid: str, label: str) -> dict[str, Any]:
        return suite_contract.metric_not_run(mid, label, downstream_reason)

    metrics: list[dict[str, Any]] = [
        {
            "id": "rights_clear_recipes",
            "metric": "Rights-clear recipes (complete per-recipe manifest evidence)",
            "value": ev["rights_clear_count"],
            "bar": BAR_RIGHTS,
            "detail": (f"{ev['rights_clear_count']} rights-clear; "
                       f"{len(ev['quarantined'])} quarantined (fail-closed; see "
                       "quarantined.json). Scored input: " + ev["scored_input"] +
                       ". Bundled-catalog audit: see bundled_rights_audit.json."),
            "evidence": {"path": "quarantined.json",
                         "note": "per-recipe manifest validation by rights.record_status; "
                                 "every needed permission must be affirmative"},
        },
    ]
    if no_clear:
        metrics.append(not_run_row("food_safety_linter_pass", "Food-safety linter pass (% of corpus)"))
        metrics.append(not_run_row("lines_with_quantity_evidence", "Lines resolved with quantity evidence (%)"))
        metrics.append(not_run_row("unchecked_allergen_diet_claims", "Unchecked allergen/diet claims (after linter strip)"))
        metrics.append(not_run_row("cuisine_time_band_coverage", "Declared cuisines and time bands represented (%)"))
        return metrics
    metrics += [
        {
            "id": "food_safety_linter_pass",
            "metric": "Food-safety linter pass (% of corpus)",
            "value": ev["linter_pct"],
            "bar": BAR_LINTER,
            "detail": (f"{ev['linter_passed']}/{ev['linter_total']} recipes pass the RS linter "
                       "(R1 schema, R2 quantity evidence, R3 canon doneness, R4 claim "
                       "evidence, R5 timers). Canon: " + ev["canon"] + ". Engine: " +
                       ev["linter_engine"] + "; see lint_report.json."),
            "evidence": {"path": "lint_report.json",
                         "note": "per-recipe violations listed with ids"},
        },
        {
            "id": "lines_with_quantity_evidence",
            "metric": "Lines resolved with quantity evidence (%)",
            "value": ev["resolved_pct"],
            "bar": BAR_QTY,
            "detail": (f"{ev['resolved_lines']}/{ev['total_lines']} ingredient lines resolve to "
                       "grams (weighed with recorded scale evidence, source_grams, or household "
                       "measure with its cited conversion on the line); unknown-quantity lines "
                       "are honest but unresolved; a 'weighed' label without scale evidence "
                       "fails the lint bar."),
            "evidence": {"path": "lint_report.json", "note": "line counts from the linter"},
        },
        {
            "id": "unchecked_allergen_diet_claims",
            "metric": "Unchecked allergen/diet claims (after linter strip)",
            "value": ev["unchecked_claims"],
            "bar": BAR_CLAIMS,
            "detail": (f"{ev['stripped_claims']} unchecked claim(s) stripped by the linter; "
                       f"{ev['unchecked_claims']} remain unchecked. Classification INCOMPLETE "
                       f"for {len(ev['classification_incomplete'])} recipe(s) with unresolvable "
                       "composition (FLIngredientFacts pending; unknown never means allowed) "
                       "— see lint_report.json."),
            "evidence": {"path": "lint_report.json", "note": "claim counts + stripped_detail"},
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


def _load_corpus_conversions(repo_root: Path) -> tuple[dict[str, Any], str | None]:
    """The scored tree's OWN corpus-level conversion-evidence rows (ref ->
    row), merged across its product sources (originals first; the corpus of
    record overrides). The suite's fixture table is NEVER consulted here.
    Empty when the tree ships no conversion file — records must then carry
    their own rows; a ref defined twice across the tree's files fails closed.
    """
    merged: dict[str, Any] = {}
    for rel in ("data/recipes/originals/conversions.json",
                "data/recipes/conversions.json"):
        p = repo_root / rel
        if not p.is_file():
            continue
        try:
            payload = json.loads(p.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            return {}, f"unreadable {rel}: {exc}"
        rows = rs.as_conversion_rows(payload)
        conflicts = sorted(set(rows) & set(merged))
        if conflicts:
            return {}, (f"conflicting conversion rows for {len(conflicts)} ref(s) "
                        f"across the tree's conversion files (e.g. {conflicts[0]!r})")
        merged.update(rows)
    return merged, None


def run(out_dir: Path, repo_root: Path | None) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    results: dict[str, Any] = {
        "suite": "recipes",
        "letter": SUITE_LETTER,
        "title": SUITE_TITLE,
        "run_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "toolchain": {"python": sys.version.split()[0]},
        "metrics": [],
    }
    # Producer binding (SCORECARD.md §3/§4): the runner hands this run's
    # identity as FL_RUN_BINDING and the suite stamps it as its producer
    # binding, so the runner can verify — not overwrite — the emitted one.
    # Standalone runs (no runner) carry no binding.
    if os.environ.get("FL_RUN_BINDING"):
        results["run"] = json.loads(os.environ["FL_RUN_BINDING"])

    def _not_run(reason: str) -> list[dict[str, Any]]:
        rows = []
        for mid, label in (
            ("rights_clear_recipes", "Rights-clear recipes"),
            ("food_safety_linter_pass", "Food-safety linter pass (%)"),
            ("lines_with_quantity_evidence", "Lines resolved with quantity evidence (%)"),
            ("unchecked_allergen_diet_claims", "Unchecked allergen/diet claims"),
            ("cuisine_time_band_coverage", "Declared cuisines and time bands represented (%)"),
        ):
            rows.append(suite_contract.metric_not_run(mid, label, reason))
        return rows

    if repo_root is None:
        print("  not-run: no --repo-root given; nothing to score")
        results["metrics"] = _not_run("no repo root given (pass --repo-root <abs root>)")
        results = suite_contract.validate_results(results, expected_suite_id="recipes")
        (out_dir / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        return results

    not_run: list[tuple[str, str]] = []

    corpus, manifest, scored_desc, err = load_scored_corpus(repo_root)
    print(f"  scored input: {scored_desc}" if not err else f"  not-run: scored corpus: {err}")
    if err:
        not_run.append(("scored corpus", err))
    corpus_rows, err = _load_corpus_conversions(repo_root)
    if err:
        not_run.append(("corpus conversion evidence", err))
    elif corpus_rows:
        scored_desc += (f"; corpus conversion evidence: {len(corpus_rows)} ref(s) "
                        "from the tree's own data/recipes conversion file")
    allergens, err = load_json(SUITE_DIR / "allergens.json")
    if err:
        not_run.append(("allergen classification table", err))

    # the canonical rulebook: scored tree's data/food-safety/rules.json first,
    # else the suite-pinned snapshot (canon/PROVENANCE.md). Unavailable =>
    # doneness judgments fail closed inside the linter.
    canon, canon_desc = rs.CanonRulebook.load(repo_root)
    print(f"  {canon_desc}")

    if not_run:
        reasons = "; ".join(r for _, r in not_run)
        results["metrics"] = _not_run(reasons)
    else:
        assert manifest is not None and allergens is not None
        ev = evaluate_corpus(corpus, manifest, corpus_rows, allergens,
                             canon=canon, scored_desc=scored_desc)

        # bundled catalog audit: read-only, evidence for the rights metric
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
        # the record's OWN conversion-evidence rows: the citations above must
        # resolve from these (or the corpus's own data/recipes file) — the
        # suite passes no fixture table at score time
        "conversions": [
            {"ref": "tofu_block", "ingredient": "tofu", "unit": "block",
             "grams_per_unit": 350},
            {"ref": "rice_vinegar_tbsp", "ingredient": "rice vinegar", "unit": "tbsp",
             "grams_per_unit": 15},
        ],
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
    conversions = json.loads((CORPUS_DIR / "conversions.json").read_text())
    allergens = json.loads((SUITE_DIR / "allergens.json").read_text())
    return conversions, allergens


def _canon() -> "rs.CanonRulebook | None":
    """The canon rulebook for battery runs: pinned snapshot (repo_root=None)."""
    book, desc = rs.CanonRulebook.load(None)
    if book is None:
        print(f"  battery cannot run: {desc}")
    return book


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
        protein_text = (f"Roast the {protein} until a thermometer inserted in the "
                        f"thickest part registers {p_temp}°F, then rest for at least "
                        "3 minutes before serving.")
    else:
        protein_text = (f"Cook the {protein} until a thermometer inserted in the "
                        f"thickest part registers {p_temp}°F.")
    steps: list[dict[str, Any]] = [
        {"text": protein_text,
         "safety": {"class": p_cls, "temp_f": p_temp, "method": "thermometer",
                    "source": source}},
        {"text": f"Cook the {staple} until tender and season to taste."},
    ]
    title = f"Control Dish {i:04d}"
    if i % 7 == 0:  # casserole-titled: combination dishes must reach 165 F
        title = f"{cuisine.title()} {protein.title()} Casserole"
        steps.append({"text": "Bake the dish until a thermometer in the centre registers 165°F.",
                      "safety": {"class": "leftovers", "temp_f": 165,
                                 "method": "thermometer", "source": source}})
    if i % 5 == 0:  # reheat step: leftovers must reach 165 F with a thermometer
        steps.append({"text": "Next day, reheat a portion until a thermometer registers 165°F.",
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
        # the record's OWN conversion-evidence rows for its household lines
        "conversions": [
            {"ref": s_ref, "ingredient": staple, "unit": s_unit,
             "grams_per_unit": s_grams},
            {"ref": "rice_vinegar_tbsp", "ingredient": "rice vinegar", "unit": "tbsp",
             "grams_per_unit": 15},
        ],
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
    _, allergens = _tables()  # fixture conversions are build-time material only
    book = _canon()

    def derived(corpus: list[dict[str, Any]], manifest: dict[str, Any],
                ) -> tuple[dict[str, str], dict[str, Any]]:
        # the suite passes NO conversion table at score time: every record
        # carries its own evidence (the fixture table is build-time material,
        # never a scoring input)
        ev = evaluate_corpus(copy.deepcopy(corpus), manifest, {}, allergens,
                             canon=book)
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

    # ---- passing control (review case iv, weighed side): a line whose OWN
    # linked scale measurement agrees with its carried grams RESOLVES — the
    # per-line linkage gate is satisfiable, not vacuously failing.
    def _qc(r: dict[str, Any]) -> None:
        r["ingredients"][0]["qty"] = {"kind": "weighed", "grams": 350}
        r["provenance"] = {"scale_measurements": [{"ingredient": "tofu", "grams": 350}]}
    st, _ = derived(*_planted_mini(_qc))
    qc_ok = (st["food_safety_linter_pass"] == "pass"
             and st["lines_with_quantity_evidence"] == "pass")
    controls_held += qc_ok
    print(f"  control linked scale measurement resolves its weighed line: "
          f"{'held' if qc_ok else 'BROKEN'} "
          f"(lint={st['food_safety_linter_pass']}, qty={st['lines_with_quantity_evidence']})")

    # P1 corrupted fixture: a household line citing a conversion it does not carry
    def _p1(r: dict[str, Any]) -> None:
        r["ingredients"][0]["qty"] = {"kind": "household", "value": 1, "unit": "block",
                                      "conversion_ref": "nonexistent_ref"}
    st, _ = derived(*_planted_mini(_p1))
    plant("P1 household line without cited gram evidence",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # P6 (review case i): a household line citing a NONEXISTENT conversion_ref
    # while grams ARE present. The citation must RESOLVE from the record's own
    # rows — grams plus a nonempty ref string clear nothing.
    def _p6(r: dict[str, Any]) -> None:
        r["ingredients"][0]["qty"] = {"kind": "household", "value": 1, "unit": "block",
                                      "grams": 350, "conversion_ref": "nonexistent_ref"}
    st, _ = derived(*_planted_mini(_p6))
    plant("P6 nonexistent conversion_ref with grams present still clears",
          st["food_safety_linter_pass"] == "fail"
          and st["lines_with_quantity_evidence"] == "fail",
          f"lint={st['food_safety_linter_pass']}, qty={st['lines_with_quantity_evidence']}")

    # P7 (review case ii): a weighed line 'covered' by a REAL scale measurement
    # of a DIFFERENT line. Per-line linkage: an unrelated row covers nothing.
    def _p7(r: dict[str, Any]) -> None:
        r["ingredients"][0]["qty"] = {"kind": "weighed", "grams": 350}
        r["provenance"] = {"scale_measurements": [{"ingredient": "rice vinegar",
                                                   "grams": 15}]}
    st, _ = derived(*_planted_mini(_p7))
    plant("P7 weighed line clears on an unrelated scale measurement",
          st["food_safety_linter_pass"] == "fail"
          and st["lines_with_quantity_evidence"] == "fail",
          f"lint={st['food_safety_linter_pass']}, qty={st['lines_with_quantity_evidence']}")

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

    # D1e (reviewer-reproduced at 393b5de by calling rs.py directly): the
    # oven setting in a thermometer sentence must never pass as the food's
    # internal reading. 'Heat the oven to 350°F and check the chicken with a
    # thermometer.' carries no reading of the chicken itself, yet the old
    # sentence-level max() handed the 350 F oven setting to the poultry
    # check and the recipe passed.
    def _d1e(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "chicken thighs",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [{"text": "Heat the oven to 350°F and check the chicken "
                               "with a thermometer.",
                       "safety": {"class": "meat_poultry", "temp_f": 165,
                                  "method": "thermometer",
                                  "source": _fsis_source()}}]
    st, _ = derived(*_planted_mini(_d1e))
    plant("D1e poultry check clears on an oven setting in the same sentence",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D1f (reviewer-reproduced at 393b5de by calling rs.py directly): the
    # rest the cook reads is the rest in the instruction text — 'Rest 1
    # minute' — but _stated_rest returned the check metadata's rest_minutes
    # before ever reading the text, so metadata rest_minutes: 3 silently
    # cleared a whole-cut check against a 1-minute stated rest. The text's
    # rest is what counts, and metadata disagreeing with the text must be
    # flagged, never silently preferred.
    def _d1f(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "pork loin",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [{"text": "Roast the pork loin until a thermometer inserted "
                               "in the thickest part registers 145°F. Rest 1 "
                               "minute, then carve.",
                       "safety": {"class": "meat_whole_cut_pork", "temp_f": 145,
                                  "rest_minutes": 3, "method": "thermometer",
                                  "source": _fsis_source()}}]
    st, _ = derived(*_planted_mini(_d1f))
    plant("D1f whole-cut rest clears on rest_minutes metadata over the text's 1-minute rest",
          st["food_safety_linter_pass"] == "fail",
          f"food_safety_linter_pass={st['food_safety_linter_pass']}")

    # D1g (reviewer-reproduced at 393b5de by calling rs.py directly): a whole
    # cut whose instruction text states NO rest at all, while the check
    # metadata claims rest_minutes: 3. The metadata alone never told the cook
    # to rest the food — with no rest stated where the class requires one,
    # the check must fail. (Old behavior returned the metadata's 3.0 and the
    # recipe passed.)
    def _d1g(r: dict[str, Any]) -> None:
        r["ingredients"][0] = {"name": "beef steak",
                               "qty": {"kind": "source_grams", "grams": 300}}
        r["steps"] = [{"text": "Roast the beef steak until a thermometer inserted "
                               "in the thickest part registers 145°F, then carve "
                               "and serve immediately.",
                       "safety": {"class": "meat_whole_cut_red", "temp_f": 145,
                                  "rest_minutes": 3, "method": "thermometer",
                                  "source": _fsis_source()}}]
    st, _ = derived(*_planted_mini(_d1g))
    plant("D1g whole-cut rest clears on rest_minutes metadata with no rest in the text",
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

    # P8 (review case iii): a tree carrying ONLY the originals product source
    # (data/recipes/originals/) is scored as PRODUCT DATA — never as the
    # bundled baseline, even when a bundled catalog is also present.
    with tempfile.TemporaryDirectory(prefix="suite-c-p8-") as td:
        tmp_root = Path(td) / "repo"
        (tmp_root / "data" / "recipes" / "originals").mkdir(parents=True)
        (tmp_root / "apps" / "ios" / "Resources").mkdir(parents=True)
        (tmp_root / "apps" / "ios" / "Resources" / "data.json").write_text(json.dumps({
            "recipes": [["bundled-1", "Some Bundled Dish", 20, 2, [], [], "Cook it."]]}))
        p8_corpus, _ = _mini_fixtures()
        p8_corpus[0]["id"] = "fl-original-9999"
        p8_corpus[0]["source_ref"] = "temp:orig"
        (tmp_root / "data" / "recipes" / "originals" / "originals.jsonl").write_text(
            json.dumps(p8_corpus[0]) + "\n")
        (tmp_root / "data" / "recipes" / "originals" / "rights_manifest.json").write_text(
            json.dumps({"records": {"temp:orig": _ctl_rights_record("temp:orig")}}) + "\n")
        results_p8 = run(Path(td) / "out", tmp_root)
    m0 = results_p8["metrics"][0]
    p8_ok = (m0["value"] == 1
             and "originals.jsonl" in str(m0.get("detail", "")))
    plant("P8 originals-only tree scored as the bundled baseline", p8_ok,
          f"rights_clear value = {m0['value']}, scored input = "
          f"{str(m0.get('detail', ''))[:120]}")

    # D6 identity drift: the runner renders the scorecard row from the run
    # payload's letter/title; a payload that omits or mismatches suite.json
    # renders `?. <id>` (the gap suite A fixed at 564482c5). check_identity
    # must catch a drifted payload and accept the correctly stamped one.
    drifted = {"suite": "recipes", "letter": "Z", "title": "Wrong title"}
    stamped = {"suite": "recipes", "letter": SUITE_LETTER, "title": SUITE_TITLE}
    _d6_ok = (check_identity(drifted) is False and check_identity(stamped) is True
              and check_identity({"suite": "recipes"}) is False)
    plant("D6 run payload identity drifts from suite.json", _d6_ok,
          f"check_identity(drifted)={check_identity(drifted)}, "
          f"check_identity(stamped)={check_identity(stamped)}, "
          f"check_identity(missing)={check_identity({'suite': 'recipes'})}")

    # ---- Part A plants (eval/scorecard-a-safety-lint): the r3 review BLOCK
    # 1-2 — cook-visible doneness + rest minimums, fail-closed safety
    # classification. Each plant below must be MISSED at base 9e04af4 and
    # caught on the branch; the two part-A controls must hold on both. ----
    import tempfile

    a_plants = 0
    a_caught = 0

    def a_plant(label: str, ok: bool, detail: str) -> None:
        nonlocal a_plants, a_caught
        a_plants += 1
        a_caught += ok
        print(f"  plant {label}: {'caught' if ok else 'MISSED'} ({detail})")

    def a_lint(corpus: list[dict[str, Any]], *,
               canon_book: "rs.CanonRulebook | None") -> list[str]:
        """Lint the one mini-fixture recipe directly (violations, not metrics)."""
        scanner = rs.AllergenScanner(allergens)
        return rs.lint_recipe(
            copy.deepcopy(corpus)[0], cuisines=bands.CUISINE_SET,
            meal_slots=bands.SLOT_SET,
            # no harness-internal table at score time: records carry their
            # own conversion-evidence rows (the fixture table is inert here
            # anyway — part-A plants use source_grams lines)
            conversion_rows={},
            allergen_scan=scanner, canon=canon_book)

    def a_protein_recipe(name: str, text: str,
                         safety: dict[str, Any] | None) -> list[dict[str, Any]]:
        """Mini fixture with its first ingredient replaced by `name` and one
        protein step carrying (or omitting) the safety metadata."""
        corpus, _manifest = _mini_fixtures()
        corpus[0]["ingredients"][0] = {"name": name,
                                       "qty": {"kind": "source_grams", "grams": 300}}
        step: dict[str, Any] = {"text": text}
        if safety is not None:
            step["safety"] = safety
        corpus[0]["steps"] = [step]
        return corpus

    # A1 (BLOCK 1): a whole-cut recipe whose instruction text omits the
    # thermometer/temperature while metadata claims 165 F + rest_minutes: 1.
    # A rest that merely EXISTS must not pass: the text must name a
    # thermometer reading at the class minimum, and the stated rest must
    # reach the class-required 3 minutes.
    a1_v = a_lint(a_protein_recipe(
        "pork loin", "Roast the pork loin until done to your liking.",
        {"class": "meat_whole_cut_pork", "temp_f": 165, "rest_minutes": 1,
         "method": "thermometer", "source": _fsis_source()}), canon_book=book)
    a_plant("A1 whole-cut passes on metadata-only doneness and a 1-minute rest",
            any("cook-visible" in x for x in a1_v)
            and any("rest" in x.lower() for x in a1_v),
            f"violations={a1_v[:2] or 'NONE'}")

    # A2 (BLOCK 2): a chicken recipe with NO safety metadata and NO reheat
    # flag, canon unavailable — must fail closed (no safety signal may
    # escape), at lint level and on the derived metric.
    a2 = a_protein_recipe("chicken thighs",
                          "Sear the chicken thighs in a hot pan and serve.", None)
    a2_v = a_lint(a2, canon_book=None)
    a2_ev = evaluate_corpus(copy.deepcopy(a2), _mini_fixtures()[1], {},
                            allergens, canon=None)
    a2_st = {m["id"]: suite_contract.derive_status(m)
             for m in metric_list(a2_ev, Path("/tmp"))}
    a_plant("A2 chicken recipe with no safety signal escapes the no-canon "
            "fail-closed check",
            bool(a2_v)
            and any("chicken thighs" in x and "canon rulebook unavailable" in x
                    for x in a2_v)
            and a2_st["food_safety_linter_pass"] == "fail",
            f"violations={a2_v[:1] or 'NONE'}, "
            f"food_safety_linter_pass={a2_st['food_safety_linter_pass']}")

    # A3 (BLOCK 2): an invalid canonical rules.json — well-formed JSON,
    # schema-invalid — must fail closed NAMING the scored-tree source, never
    # fall back to the pinned snapshot.
    with tempfile.TemporaryDirectory(prefix="suite-c-a3-") as td:
        bad_root = Path(td) / "repo"
        (bad_root / "data" / "food-safety").mkdir(parents=True)
        (bad_root / "data" / "food-safety" / "rules.json").write_text(
            json.dumps({"schema_version": 2, "citations": [], "rules": []}) + "\n")
        a3_book, a3_reason = rs.CanonRulebook.load(bad_root)
    a_plant("A3 invalid scored-tree rulebook falls back to the snapshot",
            a3_book is None
            and "scored tree data/food-safety/rules.json" in a3_reason
            and "invalid" in a3_reason.lower(),
            f"book={'None' if a3_book is None else 'LOADED (fallback)'}, "
            f"reason={a3_reason[:140]}")

    # A4 (BLOCK 2): venison — an ingredient neither the canon rulebook nor the
    # allergen table can classify, carrying no claims — must fail R3 closed,
    # with the reason naming the unresolved ingredient.
    a4_v = a_lint(a_protein_recipe(
        "venison", "Roast the venison until done to your liking.", None),
        canon_book=book)
    a_plant("A4 unclassified ingredient (venison) does not block safety lint",
            bool(a4_v)
            and any("venison" in x and "unresolved" in x.lower() for x in a4_v),
            f"violations={a4_v[:1] or 'NONE'}")

    # Part-A passing controls: the correct patterns must pass — a whole-cut
    # recipe whose text states 145 F + the 3-minute rest, and a poultry
    # recipe whose text states 165 F (satisfiability of A1/A2/A4).
    ctlw_v = a_lint(a_protein_recipe(
        "pork loin",
        "Roast the pork loin until a thermometer inserted in the thickest part "
        "registers 145°F, then rest for at least 3 minutes before serving.",
        {"class": "meat_whole_cut_pork", "temp_f": 145, "method": "thermometer",
         "source": _fsis_source()}), canon_book=book)
    ctlp_v = a_lint(a_protein_recipe(
        "chicken thighs",
        "Cook the chicken thighs until a thermometer inserted in the thickest "
        "part registers 165°F.",
        {"class": "meat_poultry", "temp_f": 165, "method": "thermometer",
         "source": _fsis_source()}), canon_book=book)
    a_controls_ok = not ctlw_v and not ctlp_v
    print(f"  part-A controls (whole-cut text 145F + 3-min rest; poultry text "
          f"165F): {'held' if a_controls_ok else 'BROKEN'} "
          f"(whole-cut={ctlw_v[:1] or 'clean'}, poultry={ctlp_v[:1] or 'clean'})")

    a_all_green = a_caught == a_plants and a_controls_ok
    print(f"caught {caught}/{plants_total} planted failures; "
          f"controls {controls_held}/2 held; part-A safety-lint battery: "
          f"{a_caught}/{a_plants} plants, "
          f"controls {'held' if a_controls_ok else 'BROKEN'}")
    return 0 if (caught == plants_total and controls_held == 2
                 and a_all_green) else 1


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
