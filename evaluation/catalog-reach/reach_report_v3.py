#!/usr/bin/env python3
"""Catalog reach v3: the app's own ingredient lookup, replayed exactly.

The v2 report resolved written pantry items with an exact-match rule (name/alias
candidates with snake_case and plural folds). That is not what the app does. A
household types a food into manual add, and `IngredientRepository.search`
(`apps/ios/Platform/Persistence/Repository/IngredientRepository.swift:27`) runs a
SQLite substring match:

    WHERE lower(name) LIKE '%q%' OR lower(description) LIKE '%q%'
       OR lower(notes)   LIKE '%q%' OR lower(alias)   LIKE '%q%'
    ORDER BY exact-name match, name-prefix match, name
    LIMIT 1 (first result)

and the first row wins. This report replays that lookup in Python — SQLite LIKE
semantics (% and _ wildcards, case-insensitive), binary name ordering, first
result — over the exact app ingredient space first-launch hydration builds
(legacy data.json rows first, then the bundled USDA catalog rows with their
lowercased aliases; INSERT OR IGNORE collapses binary-equal names onto the
legacy row). A pantry item counts as in the kitchen only when its first search
result is an app ingredient the recipe line's key bridges to
(`RecipeCatalogIngredientBridge`): legacy_id when the vocabulary row carries
one, plus (post-v3 union bridge) the fdc_id path — the source row's exact name
and lowercased aliases. Nothing is guessed: a search miss stays a miss.

Lost required lines are classified:
  (a) the pantry name finds no app ingredient (search returns no rows);
  (b) it finds one, but not an id the recipe key bridges to (one food, two ids
      — the search result and the bridge land on different rows of the same
      food, e.g. the legacy twin vs the USDA twin, or a prefix accident like
      "salt" landing on "Salt pork");
  (c) the recipe key has no bridge at all (unresolved key — lost for every
      household);
  and, separately, lines that are simply not in the kitchen (no pantry item
  corresponds to the key — the household genuinely lacks the food).

Diets follow the app's fail-closed gate: eligible only when the bundle claim is
`true`. Medians across the ten written pantries; "exact" needs every required
non-staple line in the kitchen, "near" allows at most 2 missing.

Usage (before-state snapshots are the pre-fix shipped catalog/bundle):
  python3 reach_report_v3.py --repo-root /path/to/FridgeLuck \
      --out reach-v3.json [--md reach-v3.md] \
      [--before-sqlite /tmp/before/catalog.sqlite --before-bundle /tmp/before/recipes-v2.json]

Without --before-* the current repo files stand in for both states (before ==
after) and the classification still runs.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from collections import defaultdict
from pathlib import Path
from typing import Any

PANTRIES_V2 = Path(__file__).resolve().parent / "pantries-v2.json"

DIETS = ["omnivore", "vegetarian", "vegan", "gluten_free", "dairy_free"]
NEAR_MATCH_MAX_MISSING = 2


# --------------------------------------------------------------------------
# SQLite LIKE replay
# --------------------------------------------------------------------------

def like_match(pattern: str, text: str) -> bool:
    """SQLite LIKE: % = any run, _ = one char, case-insensitive (ASCII)."""
    rx = "^" + "".join(
        ".*" if c == "%" else "." if c == "_" else re.escape(c) for c in pattern
    ) + "$"
    return re.match(rx, text, re.IGNORECASE | re.DOTALL) is not None


# --------------------------------------------------------------------------
# App ingredient space (what first-launch hydration builds)
# --------------------------------------------------------------------------

class AppSpace:
    """App `ingredients` + `ingredient_aliases` after hydration, by numeric id."""

    def __init__(self, sqlite_path: Path, data_json_path: Path) -> None:
        conn = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
        try:
            usda_names: dict[int, str] = {}
            for fdc_id, name in conn.execute(
                "SELECT fdc_id, display_name FROM ingredient_catalog"):
                usda_names[int(fdc_id)] = name
            usda_aliases: dict[int, list[str]] = defaultdict(list)
            for iid, alias in conn.execute(
                "SELECT ingredient_id, alias FROM ingredient_aliases WHERE alias <> ''"):
                usda_aliases[int(iid)].append(alias.lower())
            shipped = [
                (int(iid), name, desc or "", notes or "")
                for iid, name, desc, notes in conn.execute(
                    "SELECT id, name, COALESCE(description,''), COALESCE(notes,'') "
                    "FROM ingredients ORDER BY id")
            ]
            shipped_alias_rows = [
                (name, alias) for name, alias in conn.execute(
                    "SELECT i.name AS n, a.alias FROM ingredient_aliases a "
                    "JOIN ingredients i ON i.id = a.ingredient_id")
            ]
        finally:
            conn.close()

        # Legacy rows first (fixed ids, no aliases), then USDA rows; INSERT OR
        # IGNORE + UNIQUE(name) collapses binary-equal names onto the legacy row.
        self.rows: dict[int, dict[str, str]] = {}
        taken: set[str] = set()
        data = json.loads(data_json_path.read_text())
        for id_string, raw in sorted(data["ingredients"].items(), key=lambda kv: int(kv[0])):
            iid = int(id_string)
            name = raw[0]
            storage = raw[9] if isinstance(raw, list) and len(raw) > 9 else ""
            self.rows[iid] = {"name": name, "description": "", "notes": storage}
            taken.add(name)
        for iid, name, desc, notes in shipped:
            if name in taken:
                continue
            self.rows[iid] = {"name": name, "description": desc, "notes": notes}
            taken.add(name)
        self.aliases: dict[int, set[str]] = defaultdict(set)
        for name, alias in shipped_alias_rows:
            for iid, row in self.rows.items():
                if row["name"] == name:
                    self.aliases[iid].add(alias.lower())
                    break
        self.usda_names = usda_names
        self.usda_aliases = dict(usda_aliases)
        self.name_to_id = {row["name"]: iid for iid, row in self.rows.items()}
        alias_to_ids: dict[str, set[int]] = defaultdict(set)
        for iid, alias_set in self.aliases.items():
            for alias in alias_set:
                alias_to_ids[alias].add(iid)
        self.alias_to_ids = dict(alias_to_ids)

    def search_first(self, query: str) -> tuple[int, str, int] | None:
        """Replay IngredientRepository.search; return (id, name, rank) of row 1."""
        q = query.lower()
        hits: list[tuple[int, str, int]] = []
        for iid, row in self.rows.items():
            name = row["name"]
            lowered = name.lower()
            matched = like_match(f"%{q}%", lowered) \
                or like_match(f"%{q}%", row["description"].lower()) \
                or like_match(f"%{q}%", row["notes"].lower()) \
                or any(like_match(f"%{q}%", a) for a in self.aliases.get(iid, ()))
            if not matched:
                continue
            if lowered == q:
                rank = 0
            elif like_match(f"{q}%", lowered):
                rank = 1
            else:
                rank = 2
            hits.append((rank, name, iid))
        if not hits:
            return None
        # ORDER BY rank, i.name (BINARY collation: byte order, uppercase first)
        hits.sort(key=lambda t: (t[0], t[1]))
        rank, name, iid = hits[0]
        return iid, name, rank


# --------------------------------------------------------------------------
# Bridge replay (RecipeCatalogIngredientBridge.rebuild)
# --------------------------------------------------------------------------

def build_bridge(
    vocabulary: list[dict[str, Any]],
    space: AppSpace,
    union_legacy_and_fdc: bool,
) -> tuple[dict[str, set[int]], dict[str, str]]:
    """Per key: the app ingredient ids the line stands for, and the rule.

    union_legacy_and_fdc=False replays the shipped strict precedence
    (legacy_id takes all; fdc only otherwise). True replays the v3 union:
    legacy_id and the fdc_id path both contribute when both carry evidence —
    every id is still an exact, cited same-food row.
    """
    app_ids = set(space.rows)
    resolved: dict[str, set[int]] = {}
    resolved_by: dict[str, str] = {}
    for row in vocabulary:
        key = row["key"]
        ids: set[int] = set()
        by: list[str] = []
        legacy_id = row.get("legacy_id")
        if legacy_id is not None and int(legacy_id) in app_ids:
            ids.add(int(legacy_id))
            by.append("legacy_id")
            if not union_legacy_and_fdc:
                resolved[key] = ids
                resolved_by[key] = "legacy_id"
                continue
        fdc_id = row.get("fdc_id")
        if fdc_id is not None:
            fdc_id = int(fdc_id)
            source_name = space.usda_names.get(fdc_id)
            if source_name is not None and source_name in space.name_to_id:
                ids.add(space.name_to_id[source_name])
            for alias in space.usda_aliases.get(fdc_id, []):
                ids |= space.alias_to_ids.get(alias, set())
            if ids and "legacy_id" not in by:
                by.append("fdc_id")
            elif ids:
                by = ["legacy_id+fdc_id"]
        if ids:
            resolved[key] = ids
            resolved_by[key] = "+".join(by) if by else ""
    return resolved, resolved_by


# --------------------------------------------------------------------------
# Pantry correspondence: written item -> vocabulary key (exact forms + folds)
# --------------------------------------------------------------------------

def candidate_forms(text: str) -> set[str]:
    low = text.strip().lower()
    snake = low.replace("-", "_").replace(" ", "_")
    out = {low, snake}
    for base in (low, snake):
        if base.endswith("ies") and len(base) > 4:
            out.add(base[:-3] + "y")
        if base.endswith("es") and len(base) > 3:
            out.add(base[:-2])
        if base.endswith("s") and not base.endswith("ss") and len(base) > 2:
            out.add(base[:-1])
    return out


def key_forms(row: dict[str, Any]) -> set[str]:
    forms = {row["key"], row.get("display_name", "")}
    forms.update(row.get("aliases", []))
    return candidate_forms(" ".join(sorted(forms))) | {
        f for form in forms for f in candidate_forms(form)
    }


def correspond(item: str, key_row: dict[str, Any]) -> bool:
    return bool(candidate_forms(item) & key_forms(key_row))


# --------------------------------------------------------------------------
# Reach + classification
# --------------------------------------------------------------------------

def required_lines(recipe: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        line for line in recipe["ingredients"]
        if line.get("required", True) and not line.get("assumed_staple", False)
    ]


def analyze_state(
    label: str,
    bundle: dict[str, Any],
    space: AppSpace,
    pantries_spec: dict[str, Any],
    union_bridge: bool,
    classify: bool,
) -> dict[str, Any]:
    vocab = bundle["ingredients"]
    bridge, bridge_by = build_bridge(vocab, space, union_bridge)
    key_rows = {row["key"]: row for row in vocab}

    per_pantry: dict[str, Any] = {}
    class_lines: dict[str, int] = {"a_no_app_ingredient": 0, "b_wrong_id": 0,
                                   "c_no_bridge": 0, "not_in_kitchen": 0}
    class_recipes: dict[str, int] = {k: 0 for k in class_lines}
    line_examples: dict[str, list[dict[str, str]]] = {k: [] for k in class_lines}
    resolution_rows: list[dict[str, Any]] = []

    for spec in pantries_spec["pantries"]:
        items = spec["items"]
        first_results: dict[str, tuple[int, str, int] | None] = {}
        for item in items:
            first_results[item] = space.search_first(item)
        pantry_ids = {r[0] for r in first_results.values() if r}

        exact: list[str] = []
        near: list[str] = []
        diet_eligible = {diet: 0 for diet in DIETS}
        near_diet_eligible = {diet: 0 for diet in DIETS}
        unresolved_search = [i for i, r in first_results.items() if r is None]

        for recipe in bundle["recipes"]:
            lines = required_lines(recipe)
            if not lines:
                continue
            missing_lines: list[tuple[dict[str, Any], str | None]] = []
            for line in lines:
                key = line["key"]
                ids = bridge.get(key, set())
                if ids & pantry_ids:
                    continue
                why: str | None = None
                if classify:
                    if not ids:
                        why = "c_no_bridge"
                    else:
                        matching_items = [
                            item for item in items if correspond(item, key_rows[key])
                        ]
                        if not matching_items:
                            why = "not_in_kitchen"
                        elif any(first_results[i] is None for i in matching_items):
                            why = "a_no_app_ingredient"
                        else:
                            why = "b_wrong_id"
                    class_lines[why] += 1
                    if len(line_examples[why]) < 12:
                        line_examples[why].append({
                            "pantry": spec["name"], "key": key,
                            "recipe": recipe["catalog_id"],
                        })
                    missing_lines.append((line, why))
                else:
                    missing_lines.append((line, None))
            missing = len(missing_lines)
            if missing > NEAR_MATCH_MAX_MISSING:
                continue
            catalog_id = recipe["catalog_id"]
            if classify and missing_lines:
                seen = {why for _, why in missing_lines if why}
                for why in seen:
                    class_recipes[why] += 1
            claims = recipe.get("claims", {})
            for diet in DIETS:
                if diet != "omnivore" and claims.get(diet) is not True:
                    continue
                if missing == 0:
                    diet_eligible[diet] += 1
                near_diet_eligible[diet] += 1
            if missing == 0:
                exact.append(catalog_id)
            near.append(catalog_id)

        per_pantry[spec["name"]] = {
            "items_requested": len(items),
            "items_resolved": len(items) - len(unresolved_search),
            "unresolved_items": unresolved_search,
            "first_results": {
                item: ({"id": r[0], "name": r[1], "rank": r[2]} if r else None)
                for item, r in first_results.items()
            },
            "cookable_now_count": len(exact),
            "cookable_near_count": len(near),
            "diet_eligible": diet_eligible,
            "near_diet_eligible": near_diet_eligible,
        }
        for item, r in first_results.items():
            resolution_rows.append({
                "pantry": spec["name"], "item": item,
                "search_first": {"id": r[0], "name": r[1], "rank": r[2]} if r else None,
            })

    return {
        "state": label,
        "bundle_version": bundle.get("bundle_version"),
        "recipes_total": len(bundle["recipes"]),
        "keys_total": len(vocab),
        "keys_bridged": len(bridge),
        "per_pantry": per_pantry,
        "resolutions": resolution_rows,
        "classification": {
            "lines_by_class": class_lines,
            "recipes_by_class": class_recipes,
            "examples": line_examples,
        } if classify else None,
    }


def diet_medians(analysis: dict[str, Any], key: str) -> dict[str, float]:
    out: dict[str, float] = {}
    pantries = analysis["per_pantry"]
    for diet in DIETS:
        values = sorted(p[key].get(diet, 0) for p in pantries.values())
        n = len(values)
        out[diet] = values[n // 2] if n % 2 else (values[n // 2 - 1] + values[n // 2]) / 2
    return out


def render_markdown(report: dict[str, Any]) -> str:
    before = report["states"]["before"]
    after = report["states"]["after"]
    b_exact = diet_medians(before, "diet_eligible")
    a_exact = diet_medians(after, "diet_eligible")
    b_near = diet_medians(before, "near_diet_eligible")
    a_near = diet_medians(after, "near_diet_eligible")
    lines = [
        "# Catalog reach v3: the app's own lookup over ten written pantries",
        "",
        "Pantry items resolve through a replay of `IngredientRepository.search`",
        "(SQLite substring LIKE over name/description/notes/alias; exact-name, then",
        "name-prefix, then name; first result). A recipe line is in the kitchen only",
        "when its key bridges to the same app ingredient id the first search result",
        "holds. Before: shipped data with the strict-precedence bridge. After: cited",
        "alias/name/row repairs plus the union identity bridge.",
        "",
        "## Diet-eligible cookable recipes (median across the 10 pantries)",
        "",
        "| diet | before exact | after exact | before near | after near | near delta |",
        "|---|---|---|---|---|---|",
    ]
    for diet in DIETS:
        lines.append(
            f"| {diet} | {b_exact[diet]} | {a_exact[diet]} "
            f"| {b_near[diet]} | {a_near[diet]} | {a_near[diet] - b_near[diet]:+g} |"
        )
    cls = after.get("classification") or before["classification"]
    lines += [
        "",
        "## Lost required lines by class (before-state classification)",
        "",
        "| class | lines | distinct recipes hit (across pantries) |",
        "|---|---|---|",
    ]
    labels = {
        "a_no_app_ingredient": "(a) pantry name finds no app ingredient",
        "b_wrong_id": "(b) search lands on a different id of the same food",
        "c_no_bridge": "(c) recipe key has no bridge",
        "not_in_kitchen": "genuinely not in the kitchen",
    }
    b_cls = before["classification"]
    for why, label in labels.items():
        lines.append(
            f"| {label} | {b_cls['lines_by_class'][why]} "
            f"| {b_cls['recipes_by_class'][why]} |"
        )
    lines += [
        "",
        "## Remaining unresolved pantry items (after)",
        "",
    ]
    remaining = sorted({
        item for p in after["per_pantry"].values() for item in p["unresolved_items"]
    })
    lines.extend(f"- {item}" for item in remaining) if remaining else lines.append("- none")
    lines += ["", "## Remaining unbridged keys (after)", ""]
    unbridged = sorted(
        {row["key"] for row in json.loads(Path(report["_bundle_path"]).read_text())["ingredients"]}
        - set(after["_bridged_keys"])
    ) if False else after.get("_unbridged_keys", [])
    lines.extend(f"- `{k}`" for k in unbridged) if unbridged else lines.append("- none")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--md", type=Path)
    parser.add_argument("--before-sqlite", type=Path)
    parser.add_argument("--before-bundle", type=Path)
    args = parser.parse_args()

    repo = args.repo_root
    pantries_spec = json.loads(PANTRIES_V2.read_text())
    after_bundle = json.loads((repo / "apps/ios/Resources/RecipeCatalog/recipes-v2.json").read_text())
    after_sqlite = repo / "apps/ios/Resources/usda_ingredient_catalog.sqlite"

    before_bundle_path = args.before_bundle or repo / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
    before_sqlite_path = args.before_sqlite or after_sqlite
    before_bundle = json.loads(Path(before_bundle_path).read_text())

    # The bridge semantic is part of the state: before replays the shipped
    # strict-precedence bridge, after replays the union bridge.
    before = analyze_state("before", before_bundle, AppSpace(before_sqlite_path, repo / "apps/ios/Resources/data.json"), pantries_spec, union_bridge=False, classify=True)
    after = analyze_state("after", after_bundle, AppSpace(after_sqlite, repo / "apps/ios/Resources/data.json"), pantries_spec, union_bridge=True, classify=True)

    unbridged_after = sorted(
        {row["key"] for row in after_bundle["ingredients"]}
        - set(_bridged_keys(after_bundle, after_sqlite, repo)))
    report = {
        "before_bundle": str(before_bundle_path),
        "after_bundle": str(repo / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"),
        "states": {"before": before, "after": after},
        "diet_medians": {
            "before_exact": diet_medians(before, "diet_eligible"),
            "after_exact": diet_medians(after, "diet_eligible"),
            "before_near": diet_medians(before, "near_diet_eligible"),
            "after_near": diet_medians(after, "near_diet_eligible"),
        },
        "unbridged_keys_after": unbridged_after,
        "method": __doc__.strip(),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    if args.md:
        args.md.write_text(render_markdown(report))
    for label, key_e, key_n in (
        ("before", "before_exact", "before_near"), ("after", "after_exact", "after_near")):
        print(f"{label}: exact {report['diet_medians'][key_e]}")
        print(f"{label}: near  {report['diet_medians'][key_n]}")
    print(f"classification (before): {before['classification']['lines_by_class']}")


def _bridged_keys(bundle: dict[str, Any], sqlite_path: Path, repo: Path) -> list[str]:
    space = AppSpace(sqlite_path, repo / "apps/ios/Resources/data.json")
    bridge, _ = build_bridge(bundle["ingredients"], space, union_legacy_and_fdc=True)
    return list(bridge)


if __name__ == "__main__":
    main()
