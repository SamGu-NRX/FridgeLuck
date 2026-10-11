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
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"
MANIFEST = REPO_ROOT / "data/recipes/rights_manifest.json"

ID_SCHEME = re.compile(r"^fl-[a-z0-9]+-\d{4}$")


def fail(msg: str) -> None:
    print(f"  FAIL {msg}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--suite-dir", required=True,
                    help="extracted evaluation/suites/recipes (eval/scorecard-runner)")
    args = ap.parse_args()
    suite_dir = Path(args.suite_dir)
    sys.path.insert(0, str(suite_dir))
    import bands
    import rights
    import rs

    errors: list[str] = []

    # ---- inputs ----------------------------------------------------------
    recipes: list[dict[str, Any]] = []
    for lineno, line in enumerate(CORPUS.read_bytes().split(b"\n"), start=1):
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

    # ---- lint (same pipeline as suite.py evaluate_corpus) -----------------
    work = copy.deepcopy(clear)
    for r in work:
        r["_classes"] = sorted(scanner.classes_for(r))
    lint = rs.lint_corpus(
        work, cuisines=bands.CUISINE_SET, meal_slots=bands.SLOT_SET,
        conversions=conversions_tbl, allergen_scan=scanner)
    for rid, violations in lint["recipes_with_violations"].items():
        for v in violations:
            fail(v)
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
