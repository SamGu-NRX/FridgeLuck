#!/usr/bin/env python3
"""Catalog reach v2: named households, diet gates, and a shipped-vs-new comparison.

The v1 report (reach_report.py) replays the iOS hydration bridge over the shipped
bundle with synthetic random pantries. This report answers the burst-9 question:
what does the bundle's own diet evidence buy a real household? It compares two
bundles — the shipped resource and the newly compiled build — over the SAME
written pantries:

  1. Pantry resolution: each written pantry item is matched against the app
     ingredient space (legacy data.json names, USDA catalog rows, lowercased USDA
     aliases) by exact match only — candidates are the written name, its
     snake_case form, and naive plural folds, never a similarity guess. The
     resolution rule for each item is recorded; misses are disclosed per pantry.
  2. Cookable now: recipes whose every required non-staple line resolves into the
     pantry (the v1 rule, applied to named pantries).
  3. Diet-eligible: the app's diet gate fails closed — a recipe is eligible for a
     diet only when its bundle claim for that diet is `true` (null/false are
     refused). Shipped-bundle claims are authored-only; the new build derives
     claims from line composition classes, so the delta is exactly what the
     classes evidence adds.

Diets: omnivore (no gate) plus the four the bundle carries: vegetarian, vegan,
gluten_free, dairy_free.

Usage:
  python3 reach_report_v2.py --repo-root /path/to/FridgeLuck \
      --out reach-v2.json [--md reach-v2.md]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from reach_report import (
    build_app_ingredient_space,
    build_resolver,
    load_legacy_map,
    load_usda_catalog,
    required_lines,
)

SHIPPED_BUNDLE = Path("apps/ios/Resources/RecipeCatalog/recipes-v2.json")
NEW_BUNDLE = Path("data/recipes/build/recipes-v2.json")
PANTRIES_V2 = Path(__file__).resolve().parent / "pantries-v2.json"

DIETS = ["omnivore", "vegetarian", "vegan", "gluten_free", "dairy_free"]
NEAR_MATCH_MAX_MISSING = 2  # same near tier as reach_report.py


def _candidate_keys(item: str) -> list[str]:
    """Deterministic written-name candidates, in order: exact lowercase, then
    snake_case, then naive plural folds of both. No similarity, no guessing —
    every candidate is an exact string transform of the written item."""
    low = item.strip().lower()
    snake = low.replace("-", "_").replace(" ", "_")
    out = [low, snake]
    for base in (low, snake):
        if base.endswith("ies") and len(base) > 4:
            out.append(base[:-3] + "y")
        elif base.endswith("es") and len(base) > 3:
            out.append(base[:-2])
        elif base.endswith("s") and not base.endswith("ss") and len(base) > 2:
            out.append(base[:-1])
    seen: set[str] = set()
    return [c for c in out if not (c in seen or seen.add(c))]


def resolve_pantry(
    items: list[str],
    ids_by_name: dict[str, int],
    ids_by_alias: dict[str, set[int]],
) -> tuple[set[int], list[str], dict[str, str]]:
    """Resolve a written pantry against the app ingredient space by exact name
    or alias (with snake_case and plural-fold candidates); misses are returned,
    never guessed, with the rule that resolved each item."""
    pantry: set[int] = set()
    unresolved: list[str] = []
    resolved_by_rule: dict[str, str] = {}
    for item in items:
        hit: int | None = None
        rule = ""
        for candidate in _candidate_keys(item):
            if candidate in ids_by_name:
                hit, rule = ids_by_name[candidate], f"name:{candidate}"
                break
            if candidate in ids_by_alias:
                hit = sorted(ids_by_alias[candidate])[0]
                rule = f"alias:{candidate}"
                break
        if hit is None:
            unresolved.append(item)
        else:
            pantry.add(hit)
            resolved_by_rule[item] = rule
    return pantry, unresolved, resolved_by_rule


def cookable_and_diet_eligible(
    recipes: list[dict[str, Any]],
    resolved: dict[str, set[int]],
    pantry: set[int],
) -> dict[str, Any]:
    """Per-recipe pantry fit and per-diet eligibility under the app's fail-closed gate.

    Cookable has two tiers: exact (0 missing required lines) and near (at most
    2 missing — the household has everything but a garnish or one swap). Both
    gates require every required line to resolve at all: a key the bridge cannot
    resolve blocks every user, exactly as in production.
    """
    exact: list[str] = []
    near: list[str] = []
    diet_eligible: dict[str, int] = {diet: 0 for diet in DIETS}
    near_diet_eligible: dict[str, int] = {diet: 0 for diet in DIETS}
    per_diet_cookable: dict[str, list[str]] = {diet: [] for diet in DIETS}
    per_diet_near: dict[str, list[str]] = {diet: [] for diet in DIETS}
    for recipe in recipes:
        lines = required_lines(recipe)
        if not lines:
            continue  # no required non-staple lines: the engine never surfaces it
        if any(line["key"] not in resolved for line in lines):
            continue  # blocked for every user by an unresolved key
        missing = sum(1 for line in lines if not resolved[line["key"]] & pantry)
        if missing > NEAR_MATCH_MAX_MISSING:
            continue
        catalog_id = recipe["catalog_id"]
        claims = recipe.get("claims", {})
        for diet in DIETS:
            if diet != "omnivore" and claims.get(diet) is not True:
                continue  # the app gate refuses null and false alike
            if missing == 0:
                diet_eligible[diet] += 1
                per_diet_cookable[diet].append(catalog_id)
            near_diet_eligible[diet] += 1
            per_diet_near[diet].append(catalog_id)
        if missing == 0:
            exact.append(catalog_id)
        near.append(catalog_id)
    return {
        "cookable_now": exact,
        "cookable_near": near,
        "diet_eligible": diet_eligible,
        "near_diet_eligible": near_diet_eligible,
        "per_diet_cookable": per_diet_cookable,
        "per_diet_near": per_diet_near,
    }


def analyze_bundle(
    bundle: dict[str, Any],
    repo_root: Path,
    pantries_spec: dict[str, Any],
) -> dict[str, Any]:
    usda_names, usda_aliases = load_usda_catalog(
        repo_root / "apps/ios/Resources/usda_ingredient_catalog.sqlite")
    legacy_ids, legacy_names = load_legacy_map(
        repo_root / "apps/ios/Resources/data.json")
    ids_by_name, ids_by_alias = build_app_ingredient_space(
        legacy_names, usda_names, usda_aliases)
    resolved, resolved_by = build_resolver(
        bundle["ingredients"], legacy_ids, usda_names, usda_aliases,
        ids_by_name, ids_by_alias)

    claim_true_counts = {diet: 0 for diet in DIETS if diet != "omnivore"}
    for recipe in bundle["recipes"]:
        for diet in claim_true_counts:
            if recipe.get("claims", {}).get(diet) is True:
                claim_true_counts[diet] += 1

    per_pantry: dict[str, Any] = {}
    for spec in pantries_spec["pantries"]:
        pantry, unresolved, rules = resolve_pantry(spec["items"], ids_by_name, ids_by_alias)
        outcome = cookable_and_diet_eligible(bundle["recipes"], resolved, pantry)
        per_pantry[spec["name"]] = {
            "items_requested": len(spec["items"]),
            "items_resolved": len(spec["items"]) - len(unresolved),
            "unresolved_items": unresolved,
            "resolution_rules": rules,
            "cookable_now_count": len(outcome["cookable_now"]),
            "cookable_near_count": len(outcome["cookable_near"]),
            "diet_eligible": outcome["diet_eligible"],
            "near_diet_eligible": outcome["near_diet_eligible"],
            "per_diet_cookable": outcome["per_diet_cookable"],
            "per_diet_near": outcome["per_diet_near"],
        }
    return {
        "bundle_version": bundle.get("bundle_version"),
        "generated_at": bundle.get("generated_at"),
        "recipes_total": len(bundle["recipes"]),
        "claims_true_counts": claim_true_counts,
        "per_pantry": per_pantry,
    }


def diet_medians(analysis: dict[str, Any], key: str = "diet_eligible") -> dict[str, float]:
    """Median per-diet cookable counts across the ten pantries."""
    pantries = analysis["per_pantry"]
    out: dict[str, float] = {}
    for diet in DIETS:
        values = sorted(p[key].get(diet, 0) for p in pantries.values())
        n = len(values)
        out[diet] = (values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2)
    return out


def render_markdown(shipped: dict[str, Any], new: dict[str, Any]) -> str:
    lines = [
        "# Catalog reach v2: named households and diet gates",
        "",
        "Ten written pantries resolved against the app ingredient space (exact match",
        "with snake_case and plural-fold candidates; unresolved names disclosed",
        "below). Diet eligibility follows the app gate: a recipe is eligible only",
        "when its bundle claim is `true`. Medians across the ten pantries; \"exact\"",
        "needs every required line in the pantry, \"near\" allows at most 2 missing.",
        "",
        "## Diet-eligible cookable recipes (median across the 10 pantries)",
        "",
        "| diet | shipped exact | new exact | shipped near | new near | near delta |",
        "|---|---|---|---|---|---|",
    ]
    shipped_med = diet_medians(shipped)
    new_med = diet_medians(new)
    shipped_near = diet_medians(shipped, "near_diet_eligible")
    new_near = diet_medians(new, "near_diet_eligible")
    for diet in DIETS:
        lines.append(
            f"| {diet} | {shipped_med[diet]} | {new_med[diet]} "
            f"| {shipped_near[diet]} | {new_near[diet]} "
            f"| {new_near[diet] - shipped_near[diet]:+g} |"
        )
    lines += ["", "## Claims marked true (catalog-wide)", "",
              "| diet | shipped | new build |", "|---|---|---|"]
    for diet in sorted(new["claims_true_counts"]):
        lines.append(
            f"| {diet} | {shipped['claims_true_counts'].get(diet, 0)} "
            f"| {new['claims_true_counts'][diet]} |"
        )
    lines += ["", "## Per-pantry detail (new build)", "",
              "| pantry | resolved/requested | unresolved | cookable exact | cookable near | "
              "vegetarian near | vegan near | gluten_free near | dairy_free near |",
              "|---|---|---|---|---|---|---|---|---|"]
    for name, p in new["per_pantry"].items():
        lines.append(
            f"| {name} | {p['items_resolved']}/{p['items_requested']} "
            f"| {', '.join(p['unresolved_items']) or '—'} "
            f"| {p['cookable_now_count']} | {p['cookable_near_count']} "
            f"| {p['near_diet_eligible']['vegetarian']} "
            f"| {p['near_diet_eligible']['vegan']} "
            f"| {p['near_diet_eligible']['gluten_free']} "
            f"| {p['near_diet_eligible']['dairy_free']} |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--md", type=Path)
    args = parser.parse_args()

    pantries_spec = json.loads(PANTRIES_V2.read_text())
    shipped = analyze_bundle(
        json.loads((args.repo_root / SHIPPED_BUNDLE).read_text()), args.repo_root, pantries_spec)
    new = analyze_bundle(
        json.loads((args.repo_root / NEW_BUNDLE).read_text()), args.repo_root, pantries_spec)

    report = {
        "shipped_bundle": shipped,
        "new_build": new,
        "diet_medians": {
            "shipped": diet_medians(shipped),
            "new_build": diet_medians(new),
            "shipped_near": diet_medians(shipped, "near_diet_eligible"),
            "new_near": diet_medians(new, "near_diet_eligible"),
        },
        "method": __doc__.strip(),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    if args.md:
        args.md.write_text(render_markdown(shipped, new))
    for label, analysis in (("shipped", shipped), ("new", new)):
        counts = analysis["claims_true_counts"]
        print(f"{label}: claims true {counts}")
    for diet in DIETS:
        s = diet_medians(shipped)[diet]
        n = diet_medians(new)[diet]
        s_near = diet_medians(shipped, "near_diet_eligible")[diet]
        n_near = diet_medians(new, "near_diet_eligible")[diet]
        print(
            f"diet {diet}: median eligible exact {s}->{n}, near {s_near}->{n_near}"
        )


if __name__ == "__main__":
    main()
