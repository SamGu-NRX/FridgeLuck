#!/usr/bin/env python3
"""Apply the accepted-substitutions join over data/recipes/corpus.jsonl.

Source table: data/substitutions/pairs.json on branch overhaul/substitution-table
(fetched read-only, never edited, never merged — point --table at an extracted
copy). The join mirrors the FLSubstitutions package's own semantics, no more:

  - alias resolution (SubstitutionTable.resolveIngredientKey): a corpus
    ingredient name resolves to a registry key when its lowercased, trimmed
    text exactly equals the key, the display name, or any alias;
  - verdict (ContextRules.verdict): evaluated for a pair's primary role and
    every `supported_also` role — `verified` requires BOTH sourced function
    and sourced ratio evidence; a `fails` entry with non-sourced ratio is
    `unsupported`; unknown stays unknown; a conflicting ratio is plausible
    at best and never verifies;
  - accepted = `verified` only. The package never offers unknown or
    unsupported swaps and the coverage report counts verified swaps only;
    this join applies nothing weaker. Nothing is forced: lines whose names
    do not resolve get no annotation, and no recipe text is modified.

The join result is a lean `substitutions` annotation per recipe (ingredient
name, pair id, substitute key, verified roles) — a join key back into
pairs.json, which stays the single source of pair text and evidence. Recipes
with no accepted swap get no field. Idempotent: re-running replaces every
annotation from the same table (matched by pair id) and removes stale ones.

    python3 data/recipes/tools/apply_substitutions.py \
        --table /path/to/pairs.json [--write]

Default is check mode (writes nothing, prints the full accounting).
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
CORPUS = REPO_ROOT / "data/recipes/corpus.jsonl"


def verdict(pair: dict[str, Any], role: str) -> str:
    """Mirror of FLSubstitutions ContextRules.verdict(for:requestedRole:)."""
    ratio_status: str
    if role == pair["role"]:
        ratio_status = pair["ratio"]["status"]
    else:
        also = next((a for a in pair.get("supported_also", [])
                     if a["role"] == role), None)
        if also is None:
            return ("unsupported"
                    if any(f["role"] == role for f in pair.get("fails", []))
                    else "unknown")
        ratio_status = also["status"]
    fails_role = any(f["role"] == role for f in pair.get("fails", []))
    if fails_role and ratio_status != "sourced":
        return "unsupported"
    fn, rs_ = pair["function_status"], ratio_status
    if fn == "sourced" and rs_ == "sourced":
        return "verified"
    if fn == "unknown" or rs_ == "unknown":
        return "unknown"
    if rs_ == "conflict":
        return "plausible"
    if rs_ == "unsupported":
        return "unsupported"
    return "plausible"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--table", required=True, type=Path,
                    help="pairs.json extracted from overhaul/substitution-table")
    ap.add_argument("--write", action="store_true",
                    help="write corpus.jsonl (default: check only)")
    args = ap.parse_args()

    table = json.loads(args.table.read_text())
    roles_order = {r: i for i, r in enumerate(table["roles"])}
    assert len(table["pairs"]) == 279, (
        f"expected the 279-pair table, got {len(table['pairs'])}")

    # alias index, collision-detected exactly like SubstitutionTable init
    alias: dict[str, str] = {}
    for key, rec in table["ingredients"].items():
        for name in [key, rec.get("display", ""), *rec.get("aliases", [])]:
            n = name.strip().lower()
            if not n:
                continue
            if n in alias and alias[n] != key:
                raise SystemExit(f"alias collision in table: {n!r}")
            alias[n] = key

    pairs_by_original: dict[str, list[dict[str, Any]]] = {}
    for pair in table["pairs"]:
        pairs_by_original.setdefault(pair["original"], []).append(pair)
    for lst in pairs_by_original.values():
        lst.sort(key=lambda p: p["id"])

    corpus = [json.loads(l) for l in CORPUS.read_bytes().decode("utf-8").splitlines()
              if l.strip()]

    stats: Counter[str] = Counter()
    pair_recipes: dict[str, list[str]] = {}
    out_lines: list[str] = []
    for rec in corpus:
        joined: list[dict[str, Any]] = []
        for ing in rec.get("ingredients", []):
            key = alias.get(str(ing.get("name", "")).strip().lower())
            if key is None:
                continue
            for pair in pairs_by_original.get(key, []):
                v_roles = sorted(
                    [r for r in [pair["role"]] +
                     [a["role"] for a in pair.get("supported_also", [])]
                     if verdict(pair, r) == "verified"],
                    key=lambda r: roles_order.get(r, 99))
                for r in [pair["role"]] + [a["role"] for a in pair.get("supported_also", [])]:
                    stats[f"candidate_{verdict(pair, r)}"] += 1
                if not v_roles:
                    continue
                entry = {"ingredient": ing["name"], "pair_id": pair["id"],
                         "substitute": pair["substitute"], "roles": v_roles}
                if entry not in joined:
                    joined.append(entry)
                    stats["landed"] += 1
                    rids = pair_recipes.setdefault(pair["id"], [])
                    if rec["id"] not in rids:
                        rids.append(rec["id"])
        if joined:
            rec["substitutions"] = joined
        else:
            rec.pop("substitutions", None)  # idempotence: drop stale annotations
        out_lines.append(json.dumps(rec) + "\n")

    recipes_touched = sum(1 for l in out_lines if '"substitutions"' in l)
    print(f"table: {len(table['pairs'])} pairs, {len(table['ingredients'])} "
          f"ingredients, {len(alias)} alias names")
    print(f"candidates evaluated (pair x connected role over resolving lines): "
          f"verified {stats['candidate_verified']}, plausible "
          f"{stats['candidate_plausible']}, unknown {stats['candidate_unknown']}, "
          f"unsupported {stats['candidate_unsupported']}")
    print(f"accepted join: {stats['landed']} verified (line, pair) annotations "
          f"on {recipes_touched}/{len(corpus)} recipes; {len(pair_recipes)} "
          f"distinct pairs used")
    role_counts = Counter()
    for rec in corpus:
        for s in rec.get("substitutions", []) if isinstance(rec, dict) else []:
            for r in s["roles"]:
                role_counts[r] += 1
    print("per-role landings: " + ", ".join(
        f"{r}={role_counts[r]}" for r in table["roles"] if role_counts[r]))
    print("top pairs by recipes touched:")
    for pid, rids in sorted(pair_recipes.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:10]:
        print(f"  {pid}: {len(rids)} recipes")

    if not args.write:
        print("CHECK-ONLY: no files written")
        return 0
    CORPUS.write_text("".join(out_lines), newline="\n")
    print(f"WROTE: corpus.jsonl ({len(corpus)} recipes) with the join applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
