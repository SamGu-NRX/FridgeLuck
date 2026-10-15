#!/usr/bin/env python3
"""Validation loop for data/recipes/corpus.jsonl + rights_manifest.json.

Runs suite C's own modules (rs.py, rights.py, bands.py) over the corpus files
this task owns — the same pipeline suite.py's evaluate_corpus applies, pointed
at data/recipes/ instead of the suite's committed fixtures:

  1. rights.validate_manifest over rights_manifest.json;
  2. fail if any corpus recipe's source_ref is missing or not rights-clear
     (no quarantined recipe may remain in corpus.jsonl);
  3. allergen classes injected (rs.AllergenScanner.classes_for), then
     rs.lint_corpus over every rights-clear recipe: zero violations;
  4. bands.coverage per-band counts (meal slots x time bands x cuisines);
  5. id scheme and uniqueness, JSONL hygiene (UTF-8, LF, one object/line),
     dedupe (normalized title + core-ingredient sets).

When data/recipes/conversions.json exists it is integrity-checked and its
rows join the suite's fixture table (the read contract the eval harness
adopts via fl-eval-harness-f1 / PR #88); the validator reports resolution
under BOTH read paths and the corpus-side evidence coverage of the
unresolved lines. --corpus/--conversions overrides exist for read-path
self-tests against scratch copies only.

The suite code is never modified: point --suite-dir at an extracted copy of
the eval/scorecard-runner suite, e.g.:

    git archive origin/eval/scorecard-runner evaluation/suites/recipes \
        | tar -x -C /tmp/suite
    python3 data/recipes/tools/validate_corpus.py --suite-dir /tmp/suite/evaluation/suites/recipes

Exit 0 only when everything is green; every check prints its result.
"""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import re
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import composition  # noqa: E402
import food_safety  # noqa: E402
import rights_evidence  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"
MANIFEST = REPO_ROOT / "data/recipes/rights_manifest.json"
QUARANTINE = REPO_ROOT / "data/recipes/quarantine.jsonl"
BUNDLED = REPO_ROOT / "apps/ios/Resources/data.json"
CORPUS_CONVERSIONS = REPO_ROOT / "data/recipes/conversions.json"

ID_SCHEME = re.compile(r"^fl-[a-z0-9]+-\d{4}$")


def fail(msg: str) -> None:
    print(f"  FAIL {msg}")


def quarantine_errors(recipes: list[dict[str, Any]], records: dict[str, Any],
                      entries: list[dict[str, Any]]) -> list[str]:
    """A quarantined recipe has a recorded reason and ships nowhere."""
    errors: list[str] = []
    corpus_ids = {r.get("id") for r in recipes}
    seen: set[str] = set()
    for n, e in enumerate(entries, start=1):
        rid = e.get("id")
        where = f"quarantine.jsonl line {n} ({rid})"
        if not isinstance(rid, str) or not rid:
            errors.append(f"{where}: missing id")
            continue
        if rid in seen:
            errors.append(f"{where}: id quarantined twice")
        seen.add(rid)
        if not str(e.get("reason", "")).strip() or not str(e.get("stage", "")).strip():
            errors.append(f"{where}: quarantine needs a stage and a reason")
        recipe = e.get("recipe")
        if not isinstance(recipe, dict) or recipe.get("id") != rid:
            errors.append(f"{where}: the quarantined recipe record is missing or has another id")
        if rid in corpus_ids:
            errors.append(f"{where}: quarantined recipe is still in corpus.jsonl")
        ref = recipe.get("source_ref") if isinstance(recipe, dict) else None
        if ref in records and ref not in {r.get("source_ref") for r in recipes}:
            errors.append(f"{where}: rights_manifest.json still holds a record for it")
    return errors


def release_gate_errors(recipes: list[dict[str, Any]], records: dict[str, Any],
                        bundled: dict[str, Any], *, allergens: dict[str, Any],
                        evidence: dict[str, Any]) -> list[str]:
    """The corpus-side gates the suite linter does not enforce.

    Rights: every shipped recipe's rights evidence is pinned in
    data/recipes/evidence/rights.json and agrees with it
    (rights_evidence.rights_violations), and FridgeLuck-original text does not
    reuse the bundled catalog's wording (rights_evidence.overlap_violation).
    Food safety: every food reaches its FSIS endpoint and the step text the
    cook reads names the thermometer and the temperature
    (food_safety.safety_violations).
    Claims: every allergen or diet claim rests on known composition of every
    ingredient (composition.claim_problems, with suite C's allergens.json).
    """
    errors: list[str] = []
    ref = rights_evidence.reference_ngrams(rights_evidence.bundled_texts(bundled))
    for r in recipes:
        errors.extend(food_safety.safety_violations(r))
        for cname, reasons in composition.claim_problems(r, allergens).items():
            errors.append(f"{r.get('id', '?')}: claim {cname!r} is not proven: "
                          + "; ".join(reasons))
        rec = records.get(r.get("source_ref"))
        errors.extend(rights_evidence.rights_violations(r, rec, evidence))
        if isinstance(rec, dict) and rec.get("license") == "LicenseRef-FL-Original":
            hit = rights_evidence.overlap_violation(r, ref)
            if hit:
                errors.append(hit)
    return errors


def load_corpus_conversions(path: Path) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Load + integrity-check the corpus-side conversions table.

    Row shape (one row per (ingredient, unit) conversion, every field
    evidence-backed): id, ingredient, unit, grams (positive number),
    source {name, url, quote (verbatim sentence carrying the mass),
    retrieved (YYYY-MM-DD, actual access date)}. Returns ({}, []) when the
    file does not exist yet — the table ships with its first citable
    tranche; until then the suite's fixture table stays the read path for
    existing household refs.
    """
    if not path.exists():
        return {}, []
    data = json.loads(path.read_text())
    rows = data.get("conversions", data) if isinstance(data, dict) else data
    checked: dict[str, dict[str, Any]] = {}
    problems: list[str] = []
    if isinstance(rows, dict):
        items = list(rows.items())
    elif isinstance(rows, list):
        items = [(row.get("id", "?"), row) for row in rows if isinstance(row, dict)]
    else:
        items = []
    for ref, row in items:
        where = f"conversions row {ref!r}"
        if not isinstance(row, dict):
            problems.append(f"{where}: not an object")
            continue
        grams = row.get("grams", row.get("grams_per_unit"))
        src = row.get("source") or {}
        if row.get("ingredient", "") in ("", None):
            problems.append(f"{where}: missing ingredient")
        if row.get("unit", "") in ("", None):
            problems.append(f"{where}: missing unit")
        if not isinstance(grams, (int, float)) or isinstance(grams, bool) or grams <= 0:
            problems.append(f"{where}: grams must be a positive number")
        for field in ("name", "url", "quote", "retrieved"):
            if not str(src.get(field, "")).strip():
                problems.append(f"{where}: source.{field} empty")
        try:
            datetime.date.fromisoformat(str(src.get("retrieved", "")))
        except ValueError:
            problems.append(f"{where}: source.retrieved must be YYYY-MM-DD")
        checked[str(ref)] = {**row, "grams_per_unit": grams}
    return checked, problems


def unresolved_pair_stats(recipes: list[dict[str, Any]],
                          corpus_tbl: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Corpus-side evidence coverage over the unresolved lines.

    A line is coverable when some corpus row matches its (ingredient, unit)
    pair; a line is ANNOTATED when it carries kind=household with a
    conversion_ref that resolves in the corpus table. Coverage must be
    reproducible from the table alone.
    """
    def norm(s: Any) -> str:
        return str(s).strip().lower()

    row_pairs = {(norm(r.get("ingredient")), norm(r.get("unit"))): ref
                 for ref, r in corpus_tbl.items()}
    unresolved = 0
    coverable = 0
    pairs: dict[tuple[str, str], int] = {}
    covered_pairs: set[tuple[str, str]] = set()
    annotated = 0
    annotated_refs: set[str] = set()
    for recipe in recipes:
        for line in recipe.get("ingredients", []):
            qty = line.get("qty") if isinstance(line, dict) else None
            if not isinstance(qty, dict):
                continue
            if qty.get("kind") == "unknown":
                unresolved += 1
                key = (norm(line.get("name")), norm(qty.get("unit")))
                pairs[key] = pairs.get(key, 0) + 1
                if key in row_pairs:
                    coverable += 1
                    covered_pairs.add(key)
            elif qty.get("kind") == "household":
                ref = qty.get("conversion_ref")
                if isinstance(ref, str) and ref in corpus_tbl:
                    annotated += 1
                    annotated_refs.add(ref)
    return {
        "unresolved": unresolved,
        "distinct_pairs": len(pairs),
        "coverable_lines": coverable,
        "covered_pairs": len(covered_pairs),
        "annotated_lines": annotated,
        "annotated_rows": len(annotated_refs),
        "uncovered_pairs": sorted(f"{k[0]} [{k[1] or 'no unit'}]"
                                  for k in pairs if k not in row_pairs),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite-dir", required=True,
                    help="extracted evaluation/suites/recipes (eval/scorecard-runner)")
    ap.add_argument("--corpus", type=Path, default=CORPUS,
                    help="corpus.jsonl to validate (default data/recipes/corpus.jsonl; "
                         "override for read-path self-tests)")
    ap.add_argument("--conversions", type=Path, default=CORPUS_CONVERSIONS,
                    help="corpus-side conversions table (default data/recipes/conversions.json)")
    args = ap.parse_args()
    suite_dir = Path(args.suite_dir)
    sys.path.insert(0, str(suite_dir))
    import bands
    import rights
    import rs

    errors: list[str] = []

    # ---- inputs ----------------------------------------------------------
    recipes: list[dict[str, Any]] = []
    for lineno, line in enumerate(args.corpus.read_bytes().split(b"\n"), start=1):
        if not line.strip():
            continue
        try:
            recipes.append(json.loads(line.decode("utf-8")))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            errors.append(f"corpus.jsonl line {lineno}: {exc}")
    manifest = json.loads(MANIFEST.read_text())
    conversions = json.loads((suite_dir / "conversions.json").read_text())
    conversions_tbl = conversions.get("conversions", conversions)
    allergens = json.loads((suite_dir / "allergens.json").read_text())
    scanner = rs.AllergenScanner(allergens)

    print(f"corpus: {len(recipes)} recipes, "
          f"{sum(len(r.get('ingredients', [])) for r in recipes)} ingredient lines")

    # ---- id scheme + uniqueness + dedupe ---------------------------------
    ids = [r.get("id", "?") for r in recipes]
    if any(not isinstance(i, str) or not ID_SCHEME.match(i) for i in ids):
        errors.append("id scheme: every id must match fl-<source-tag>-<4 digits>")
    if len(set(ids)) != len(ids):
        errors.append("duplicate recipe ids in corpus.jsonl")
    norm = lambda s: re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
    titles = [norm(r.get("title", "")) for r in recipes]
    cores: list[frozenset[str]] = [
        frozenset(norm(i.get("name", "")) for i in r.get("ingredients", [])
                  if isinstance(i, dict))
        for r in recipes
    ]
    # SCHEMA.md section 7: duplicates share normalized title AND core set.
    keys = list(zip(titles, cores))
    if len(set(keys)) != len(keys):
        errors.append("duplicate (title, core-ingredients) pairs in corpus.jsonl")

    # ---- rights gate -----------------------------------------------------
    statuses = rights.validate_manifest(manifest)
    clear: list[dict[str, Any]] = []
    for r in recipes:
        ref = r.get("source_ref")
        status = statuses.get(ref)
        if status is None:
            errors.append(f"{r.get('id', '?')}: source_ref {ref!r} has no rights record")
        elif status["status"] != "clear":
            errors.append(f"{r.get('id', '?')}: rights not clear: {status['reason']}")
        else:
            clear.append(r)
    print(f"rights: {len(clear)} rights-clear, "
          f"{len(recipes) - len(clear)} quarantined-in-corpus (must be 0)")

    # ---- quarantine + release gates --------------------------------------
    quarantined: list[dict[str, Any]] = []
    if QUARANTINE.exists():
        quarantined = [json.loads(l) for l in QUARANTINE.read_text(encoding="utf-8").splitlines()
                       if l.strip()]
    records = manifest.get("records", {})
    q_errors = quarantine_errors(recipes, records, quarantined)
    gate_errors = release_gate_errors(recipes, records,
                                      json.loads(BUNDLED.read_text(encoding="utf-8")),
                                      allergens=allergens,
                                      evidence=rights_evidence.load_evidence())
    for e in q_errors + gate_errors:
        fail(e)
    errors.extend(q_errors + gate_errors)
    by_stage: dict[str, int] = {}
    for e in quarantined:
        by_stage[str(e.get("stage"))] = by_stage.get(str(e.get("stage")), 0) + 1
    print(f"accepted: {len(recipes)} recipes in corpus.jsonl; quarantined: "
          f"{len(quarantined)} in quarantine.jsonl "
          f"({', '.join(f'{k} {v}' for k, v in sorted(by_stage.items())) or 'none'})")
    print(f"release gates: {len(gate_errors)} violation(s) "
          "(rights evidence, original-text overlap, FSIS endpoints, thermometer in step text, "
          "claim composition)")
    print(f"claims shipped: {sum(len(r.get('claims', [])) for r in recipes)}")

    # ---- lint (same pipeline as suite.py evaluate_corpus) -----------------
    work = copy.deepcopy(clear)
    for r in work:
        r["_classes"] = sorted(scanner.classes_for(r))
    lint = rs.lint_corpus(
        work, cuisines=bands.CUISINE_SET, meal_slots=bands.SLOT_SET,
        conversions=conversions_tbl, allergen_scan=scanner)
    corpus_ref_rids = {
        r["id"] for r in clear
        if any(isinstance(l, dict) and isinstance((l.get("qty") or {}).get("conversion_ref"), str)
               for l in r.get("ingredients", []))
    }
    for rid, violations in lint["recipes_with_violations"].items():
        for v in violations:
            fail(v)
        # Operator ruling (2026-10-11): a corpus-annotated line cannot resolve
        # under the suite's CURRENT read path (its table lacks the ref); that
        # exact R2 class is the anticipated hard-error until PR #88 adopts the
        # corpus read contract — report it, never weaken the suite, gate on
        # anything else.
        anticipated = (rid in corpus_ref_rids
                       and all("no conversion in the table" in v for v in violations))
        if anticipated:
            print(f"  NOTE {rid}: {len(violations)} violation(s) are the anticipated "
                  f"R2 hard-error on corpus-annotated lines (suite read path predates "
                  f"PR #88); reported, not gated")
        else:
            errors.append(f"{rid}: {len(violations)} linter violation(s)")
    resolved_pct = (round(100.0 * lint["resolved_lines"] / lint["total_lines"], 2)
                    if lint["total_lines"] else 0.0)
    print(f"linter: {len(lint['passed'])}/{len(work)} recipes pass; "
          f"quantity evidence: {lint['resolved_lines']}/{lint['total_lines']} "
          f"lines resolved ({resolved_pct}%)")
    print(f"claims: {lint['unchecked_claims']} unchecked, "
          f"{lint['stripped_claims']} stripped by the linter")
    if lint["unchecked_claims"]:
        errors.append(f"{lint['unchecked_claims']} unchecked claim(s) (bar: 0)")

    # ---- corpus-side conversion evidence (read path for PR #88) -----------
    corpus_tbl, conv_problems = load_corpus_conversions(args.conversions)
    for p in conv_problems:
        fail(p)
    errors.extend(f"conversions.json: {p}" for p in conv_problems)
    if args.conversions.exists():
        print(f"corpus conversions: {len(corpus_tbl)} row(s) in {args.conversions.name} "
              f"(integrity checked: id, ingredient, unit, grams>0, source quote + "
              f"retrieval date)")
    else:
        print("corpus conversions: no data/recipes/conversions.json yet — the suite's "
              "fixture table stays the read path for existing household refs")

    cov_stats = unresolved_pair_stats(recipes, corpus_tbl)
    print(f"corpus-side evidence coverage: {cov_stats['annotated_lines']}/"
          f"{cov_stats['unresolved']} unresolved lines annotated "
          f"({cov_stats['covered_pairs']}/{cov_stats['distinct_pairs']} distinct "
          f"(ingredient, unit) pairs have a citable row)")
    if cov_stats["uncovered_pairs"]:
        print(f"  uncovered pairs ({len(cov_stats['uncovered_pairs'])}):")
        for u in cov_stats["uncovered_pairs"]:
            print(f"    {u}")

    # PASS B: the read contract the eval harness adopts (PR #88) — the corpus
    # table joined over the suite's fixture table.
    merged = {**conversions_tbl, **corpus_tbl}
    work_b = copy.deepcopy(clear)
    for r in work_b:
        r["_classes"] = sorted(scanner.classes_for(r))
    lint_b = rs.lint_corpus(
        work_b, cuisines=bands.CUISINE_SET, meal_slots=bands.SLOT_SET,
        conversions=merged, allergen_scan=scanner)
    resolved_pct_b = (round(100.0 * lint_b["resolved_lines"] / lint_b["total_lines"], 2)
                      if lint_b["total_lines"] else 0.0)
    print(f"pass A (suite current semantics): {lint['resolved_lines']}/{lint['total_lines']} "
          f"lines resolved ({resolved_pct}%)")
    print(f"pass B (corpus read path):        {lint_b['resolved_lines']}/{lint_b['total_lines']} "
          f"lines resolved ({resolved_pct_b}%)")
    for rid, violations in lint_b["recipes_with_violations"].items():
        for v in violations:
            fail(v)
        errors.append(f"pass B {rid}: {len(violations)} linter violation(s)")

    # ---- coverage ---------------------------------------------------------
    cov = bands.coverage(clear)
    print("coverage (per-band counts):")
    for band_name in cov["declared"]:
        print(f"  {band_name}: {cov['counts'][band_name]}")
    print(f"  bands represented: {cov['represented']}/{cov['total_declared']}"
          f"{' (missing: ' + ', '.join(cov['missing']) + ')' if cov['missing'] else ''}")
    print(f"  cross-product cells filled: {cov['cross_product_filled']}/"
          f"{cov['cross_product_cells']} (informational)")

    # ---- verdict ----------------------------------------------------------
    if errors:
        print(f"\nVALIDATION FAILED: {len(errors)} error(s)")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("\nVALIDATION GREEN: rights-clear corpus lints clean, claims verified, "
          "ids unique and in-scheme, no quarantined recipe in corpus.jsonl")
    print(f"measured: recipes={len(clear)} resolved_pct={resolved_pct} "
          f"bands={cov['represented']}/{cov['total_declared']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
