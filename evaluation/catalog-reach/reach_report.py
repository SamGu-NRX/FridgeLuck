#!/usr/bin/env python3
"""Catalog reach report: how much of the shipped recipe catalog a real kitchen can cook.

Replays, in Python, the exact identity rules the iOS hydration-time bridge applies
(`RecipeCatalogIngredientBridge.rebuild`):

  1. `legacy_id`, when the vocabulary row carries one and the app ingredient exists.
  2. Otherwise the key's `fdc_id` against the shipped USDA catalog row for that id:
     the source row's exact name and its exact (lowercased) aliases, matched against
     the app ingredient space. No similarity, no guessing: a miss leaves the key
     unresolved, and every required line on an unresolved key counts as "not in your
     kitchen" for every user.

The app ingredient space is what first-launch hydration builds
(`BundledDataLoader.loadInto` → `loadUSDACatalogIngredientsIfAvailable`): the legacy
`data.json` ingredients (fixed integer ids, no aliases) plus every USDA catalog row
(id = fdc_id, aliases lowercased). Pantry replay draws uniformly from those rows —
the ingredient ids the scan and manual-add flows can actually produce.

Outputs a JSON report (and a markdown summary) with:
  - resolvable keys (total, by legacy_id, by fdc_id)
  - fully resolvable recipes overall, by cuisine, and among original-rights recipes
  - the unresolved keys that block the most recipes (top N)
  - a pantry replay: 200 pantries of 12-25 ingredients (fixed seed), counting recipes
    with 0 missing required lines (exact) and at most 2 (near-match tier), with medians.

Usage:
  python3 reach_report.py --repo-root /path/to/FridgeLuck --out reach.json [--md reach.md]
"""

from __future__ import annotations

import argparse
import json
import random
import sqlite3
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

PANTRY_REPLAY_PANTRIES = 200
PANTRY_REPLAY_MIN_SIZE = 12
PANTRY_REPLAY_MAX_SIZE = 25
PANTRY_REPLAY_SEED = 42
BLOCKING_KEY_LIMIT = 30
NEAR_MATCH_MAX_MISSING = 2


def load_vocabulary(bundle: dict[str, Any]) -> list[dict[str, Any]]:
    return bundle["ingredients"]


def load_recipes(bundle: dict[str, Any]) -> list[dict[str, Any]]:
    return bundle["recipes"]


def load_usda_catalog(path: Path) -> tuple[dict[int, str], dict[int, list[str]]]:
    """Shipped USDA source rows: fdc_id -> exact name, fdc_id -> lowercased aliases."""
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        names: dict[int, str] = {}
        for fdc_id, name in conn.execute("SELECT fdc_id, display_name FROM ingredient_catalog"):
            names[int(fdc_id)] = name
        aliases: dict[int, list[str]] = defaultdict(list)
        for ingredient_id, alias in conn.execute(
            "SELECT ingredient_id, alias FROM ingredient_aliases WHERE alias <> ''"
        ):
            aliases[int(ingredient_id)].append(alias.lower())
        return names, dict(aliases)
    finally:
        conn.close()


def load_legacy_map(path: Path) -> tuple[dict[int, int], dict[int, list[int]]]:
    """Legacy app ingredients from data.json: id -> name, id -> [] (data.json carries
    no aliases; the alias table is USDA-hydrated only)."""
    data = json.loads(path.read_text())
    ids: dict[int, int] = {}
    names: dict[int, str] = {}
    for id_string, raw in data["ingredients"].items():
        # IngredientArray: [name, calories, protein, carbs, fat, ...]
        ingredient_id = int(id_string)
        ids[ingredient_id] = ingredient_id
        names[ingredient_id] = raw[0] if isinstance(raw, list) else raw["name"]
    return ids, names


def build_app_ingredient_space(
    legacy_names: dict[int, str], usda_names: dict[int, str], usda_aliases: dict[int, list[str]]
) -> tuple[dict[str, int], dict[str, set[int]]]:
    """App `ingredients` (unique by name, first write wins: legacy before USDA) and
    app `ingredient_aliases` (lowercased, USDA rows only)."""
    ids_by_name: dict[str, int] = {}
    for ingredient_id, name in sorted(legacy_names.items()):
        ids_by_name.setdefault(name, ingredient_id)
    for fdc_id, name in sorted(usda_names.items()):
        ids_by_name.setdefault(name, fdc_id)
    ids_by_alias: dict[str, set[int]] = defaultdict(set)
    for fdc_id, alias_list in usda_aliases.items():
        if fdc_id not in usda_names:
            continue
        for alias in alias_list:
            ids_by_alias[alias].add(fdc_id)
    return ids_by_name, dict(ids_by_alias)


def build_resolver(
    vocabulary: list[dict[str, Any]],
    legacy_names: dict[int, str],
    usda_names: dict[int, str],
    usda_aliases: dict[int, list[str]],
    ids_by_name: dict[str, int],
    ids_by_alias: dict[str, set[int]],
) -> tuple[dict[str, set[int]], dict[str, str]]:
    """Exact bridge replay per key: resolved app ids and the rule that resolved it."""
    app_ids = set(legacy_names) | set(usda_names)
    resolved: dict[str, set[int]] = {}
    resolved_by: dict[str, str] = {}
    for row in vocabulary:
        key = row["key"]
        legacy_id = row.get("legacy_id")
        fdc_id = row.get("fdc_id")
        ids: set[int] = set()
        by = ""
        if legacy_id is not None and int(legacy_id) in app_ids:
            ids.add(int(legacy_id))
            by = "legacy_id"
        elif fdc_id is not None:
            fdc_id = int(fdc_id)
            source_name = usda_names.get(fdc_id)
            if source_name is not None and source_name in ids_by_name:
                ids.add(ids_by_name[source_name])
            for alias in usda_aliases.get(fdc_id, []):
                ids |= ids_by_alias.get(alias, set())
            if ids:
                by = "fdc_id"
        if ids:
            resolved[key] = ids
            resolved_by[key] = by
    return resolved, resolved_by


def required_lines(recipe: dict[str, Any]) -> list[dict[str, Any]]:
    """Required lines that can block a match: assumed staples never do."""
    return [
        line
        for line in recipe["ingredients"]
        if line.get("required", True) and not line.get("assumed_staple", False)
    ]


def unresolved_key_blocks(vocabulary, recipes, resolved) -> Counter:
    """For each unresolved key, how many recipes carry it on a required line."""
    blocks: Counter = Counter()
    for recipe in recipes:
        for line in required_lines(recipe):
            if line["key"] not in resolved:
                blocks[line["key"]] += 1
    return blocks


def pantry_replay(
    recipes: list[dict[str, Any]],
    resolved: dict[str, set[int]],
    pantry_pool: list[int],
    rights_by_catalog_id: dict[str, str],
) -> dict[str, Any]:
    """200 pantries of 12-25 items, fixed seed. Counts recipes reachable with 0 and
    at most 2 missing required lines per pantry, with medians across pantries."""
    rng = random.Random(PANTRY_REPLAY_SEED)
    per_recipe_lines = []
    for recipe in recipes:
        lines = [
            resolved.get(line["key"], set())  # unresolved key -> never in the pantry
            for line in required_lines(recipe)
        ]
        per_recipe_lines.append((recipe["catalog_id"], lines))

    exact_counts: list[int] = []
    near_counts: list[int] = []
    original_exact_counts: list[int] = []
    original_near_counts: list[int] = []
    for _ in range(PANTRY_REPLAY_PANTRIES):
        pantry = set(rng.sample(pantry_pool, rng.randint(PANTRY_REPLAY_MIN_SIZE, PANTRY_REPLAY_MAX_SIZE)))
        exact = 0
        near = 0
        original_exact = 0
        original_near = 0
        for catalog_id, lines in per_recipe_lines:
            if not lines:
                continue  # no required non-staple lines: the engine never surfaces it
            missing = sum(1 for ids in lines if not ids & pantry)
            if missing > NEAR_MATCH_MAX_MISSING:
                continue
            near += 1
            if missing == 0:
                exact += 1
            if rights_by_catalog_id.get(catalog_id) == "original":
                original_near += 1
                if missing == 0:
                    original_exact += 1
        exact_counts.append(exact)
        near_counts.append(near)
        original_exact_counts.append(original_exact)
        original_near_counts.append(original_near)

    return {
        "pantries": PANTRY_REPLAY_PANTRIES,
        "size_range": [PANTRY_REPLAY_MIN_SIZE, PANTRY_REPLAY_MAX_SIZE],
        "seed": PANTRY_REPLAY_SEED,
        "pool_size": len(pantry_pool),
        "exact_missing_0_median": statistics.median(exact_counts),
        "exact_missing_0_p10": sorted(exact_counts)[PANTRY_REPLAY_PANTRIES // 10],
        "exact_missing_0_p90": sorted(exact_counts)[PANTRY_REPLAY_PANTRIES * 9 // 10],
        "at_most_2_missing_median": statistics.median(near_counts),
        "at_most_2_missing_p10": sorted(near_counts)[PANTRY_REPLAY_PANTRIES // 10],
        "at_most_2_missing_p90": sorted(near_counts)[PANTRY_REPLAY_PANTRIES * 9 // 10],
        "original_rights_exact_missing_0_median": statistics.median(original_exact_counts),
        "original_rights_at_most_2_missing_median": statistics.median(original_near_counts),
    }


def build_report(repo_root: Path) -> dict[str, Any]:
    bundle_path = repo_root / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
    usda_path = repo_root / "apps/ios/Resources/usda_ingredient_catalog.sqlite"
    data_json_path = repo_root / "apps/ios/Resources/data.json"

    bundle = json.loads(bundle_path.read_text())
    vocabulary = load_vocabulary(bundle)
    recipes = load_recipes(bundle)

    usda_names, usda_aliases = load_usda_catalog(usda_path)
    legacy_ids, legacy_names = load_legacy_map(data_json_path)
    ids_by_name, ids_by_alias = build_app_ingredient_space(legacy_names, usda_names, usda_aliases)

    resolved, resolved_by = build_resolver(
        vocabulary, legacy_ids, usda_names, usda_aliases, ids_by_name, ids_by_alias
    )

    rights = {recipe["catalog_id"]: recipe.get("rights", {}).get("status", "") for recipe in recipes}

    keys_total = len(vocabulary)
    resolvable = len(resolved)
    resolvable_by_legacy = sum(1 for by in resolved_by.values() if by == "legacy_id")
    resolvable_by_fdc = sum(1 for by in resolved_by.values() if by == "fdc_id")

    unreachable_no_required = 0
    fully_resolvable_by_cuisine: Counter = Counter()
    total_by_cuisine: Counter = Counter()
    fully_resolvable = 0
    fully_resolvable_original = 0
    original_total = sum(1 for status in rights.values() if status == "original")
    blocked_recipes = 0
    blocked_original = 0
    for recipe in recipes:
        cuisine = recipe.get("cuisine", "<none>")
        total_by_cuisine[cuisine] += 1
        lines = required_lines(recipe)
        ok = bool(lines) and all(line["key"] in resolved for line in lines)
        if not lines:
            unreachable_no_required += 1
        if ok:
            fully_resolvable += 1
            fully_resolvable_by_cuisine[cuisine] += 1
            if rights.get(recipe["catalog_id"]) == "original":
                fully_resolvable_original += 1
        elif lines:
            blocked_recipes += 1
            if rights.get(recipe["catalog_id"]) == "original":
                blocked_original += 1

    blocks = unresolved_key_blocks(vocabulary, recipes, resolved)
    top_blocks = [
        {
            "key": key,
            "recipes_blocked": count,
            "fdc_id": next(
                (row.get("fdc_id") for row in vocabulary if row["key"] == key), None
            ),
        }
        for key, count in blocks.most_common(BLOCKING_KEY_LIMIT)
    ]

    pantry_pool = sorted(set(legacy_ids) | set(usda_names))
    replay = pantry_replay(recipes, resolved, pantry_pool, rights)

    return {
        "bundle_version": bundle.get("bundle_version"),
        "generated_at": bundle.get("generated_at"),
        "vocabulary_keys": keys_total,
        "resolvable_keys": resolvable,
        "resolvable_by_legacy_id": resolvable_by_legacy,
        "resolvable_by_fdc_id": resolvable_by_fdc,
        "unresolvable_keys": keys_total - resolvable,
        "recipes_total": len(recipes),
        "recipes_with_no_required_lines": unreachable_no_required,
        "fully_resolvable_recipes": fully_resolvable,
        "fully_resolvable_share": round(fully_resolvable / len(recipes), 4),
        "fully_resolvable_by_cuisine": {
            cuisine: fully_resolvable_by_cuisine.get(cuisine, 0)
            for cuisine in sorted(total_by_cuisine)
        },
        "recipes_by_cuisine": dict(sorted(total_by_cuisine.items())),
        "original_rights_recipes": original_total,
        "fully_resolvable_original_rights_recipes": fully_resolvable_original,
        "fully_resolvable_original_rights_share": round(
            fully_resolvable_original / original_total, 4
        )
        if original_total
        else 0,
        "blocked_by_unresolved_key_recipes": blocked_recipes,
        "blocked_by_unresolved_key_original_rights_recipes": blocked_original,
        "top_unresolved_keys_blocking_recipes": top_blocks,
        "pantry_replay": replay,
    }


def render_markdown(report: dict[str, Any]) -> str:
    replay = report["pantry_replay"]
    lines = [
        "# Catalog reach report",
        "",
        f"- Vocabulary keys: **{report['vocabulary_keys']}**, resolvable "
        f"**{report['resolvable_keys']}** "
        f"(legacy_id {report['resolvable_by_legacy_id']}, fdc_id {report['resolvable_by_fdc_id']}), "
        f"unresolvable {report['unresolvable_keys']}",
        f"- Recipes: **{report['recipes_total']}**, fully resolvable "
        f"**{report['fully_resolvable_recipes']}** ({report['fully_resolvable_share']:.1%})",
        f"- Original-rights recipes: {report['original_rights_recipes']}, fully resolvable "
        f"**{report['fully_resolvable_original_rights_recipes']}** "
        f"({report['fully_resolvable_original_rights_share']:.1%})",
        f"- Recipes blocked by at least one unresolved required key: "
        f"{report['blocked_by_unresolved_key_recipes']}",
        f"- Pantry replay ({replay['pantries']} pantries of {replay['size_range'][0]}-"
        f"{replay['size_range'][1]} ingredients, seed {replay['seed']}, pool "
        f"{replay['pool_size']}): exact median **{replay['exact_missing_0_median']}** "
        f"(p10 {replay['exact_missing_0_p10']}, p90 {replay['exact_missing_0_p90']}), "
        f"at-most-2-missing median **{replay['at_most_2_missing_median']}** "
        f"(p10 {replay['at_most_2_missing_p10']}, p90 {replay['at_most_2_missing_p90']})",
        "",
        "## Fully resolvable by cuisine",
        "",
        "| cuisine | fully resolvable | total |",
        "|---|---|---|",
    ]
    for cuisine in sorted(report["recipes_by_cuisine"]):
        lines.append(
            f"| {cuisine} | {report['fully_resolvable_by_cuisine'][cuisine]} "
            f"| {report['recipes_by_cuisine'][cuisine]} |"
        )
    lines += [
        "",
        f"## Top unresolved keys blocking recipes ({BLOCKING_KEY_LIMIT} shown)",
        "",
        "| key | recipes blocked | fdc_id |",
        "|---|---|---|",
    ]
    for entry in report["top_unresolved_keys_blocking_recipes"]:
        lines.append(f"| `{entry['key']}` | {entry['recipes_blocked']} | {entry['fdc_id']} |")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path, required=True, help="JSON report output path")
    parser.add_argument("--md", type=Path, help="Optional markdown summary output path")
    args = parser.parse_args()

    report = build_report(args.repo_root)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    if args.md:
        args.md.write_text(render_markdown(report))
    print(
        f"resolvable keys {report['resolvable_keys']}/{report['vocabulary_keys']}, "
        f"fully resolvable recipes {report['fully_resolvable_recipes']}/{report['recipes_total']} "
        f"({report['fully_resolvable_share']:.1%})"
    )


if __name__ == "__main__":
    main()
