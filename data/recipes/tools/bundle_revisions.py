#!/usr/bin/env python3
"""Per-recipe revision numbers for the compiled bundle.

Installed apps re-hydrate a catalog recipe only when the shipped revision is
higher than the one they stored (RecipeBundleV2Loader.upsertV2Recipe), and
they keep one nutrition snapshot per (catalog_id, revision) that logged meals
report against. So a recipe whose compiled content changes must ship a higher
revision, and a revision number must never be shipped again with different
content.

data/recipes/revisions.json records, per catalog id, each revision the bundle
has carried and the SHA-256 of that revision's compiled body (the recipe
object without its "revision" field, as canonical sort-keys JSON).
compile_bundle.py looks up every compiled recipe: when the body hash equals the
latest recorded one, the recipe ships that revision. Any other body stops the
compile, unless it runs with --bump-revisions, which appends the next revision
for the new body. Entries are only ever appended; a body that returns to an
older hash still gets a new revision, because devices may already hold the
newer one.

Seed the file once from a published bundle:
    python3 data/recipes/tools/bundle_revisions.py seed <published recipes-v2.json>
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
LEDGER = REPO / "data/recipes/revisions.json"
SCHEMA = "fridgeluck/recipe-revisions/v1"


def body_sha256(recipe: dict) -> str:
    body = {k: v for k, v in recipe.items() if k != "revision"}
    return hashlib.sha256(
        json.dumps(body, ensure_ascii=False, sort_keys=True).encode("utf-8")
    ).hexdigest()


def load(path: Path = LEDGER) -> dict[str, list[dict]]:
    if not path.exists():
        raise SystemExit(
            f"{path} is missing: seed it from the published bundle with "
            "`bundle_revisions.py seed <recipes-v2.json>` before compiling")
    doc = json.loads(path.read_text(encoding="utf-8"))
    if doc.get("schema") != SCHEMA:
        raise SystemExit(f"{path}: schema {doc.get('schema')!r}, expected {SCHEMA!r}")
    return doc["recipes"]


def write(ledger: dict[str, list[dict]], path: Path = LEDGER) -> None:
    """One recipe per line so a bump shows up as a one-line diff."""
    rows = [f"    {json.dumps(cid)}: {json.dumps(ledger[cid], ensure_ascii=False)}"
            for cid in sorted(ledger)]
    path.write_text(
        "{\n"
        f'  "schema": {json.dumps(SCHEMA)},\n'
        '  "recipes": {\n' + ",\n".join(rows) + "\n  }\n}\n",
        encoding="utf-8")


def assign(recipes: list[dict], ledger: dict[str, list[dict]],
           bump: bool) -> list[str]:
    """Set each recipe's "revision" from the ledger, in place.

    With bump=False, a recipe whose body hash is not the latest recorded one
    (or that has no entry) stops the compile with every such id named. With
    bump=True, it gets the next revision and the ledger gains an entry.
    Returns the bumped catalog ids."""
    bumped: list[str] = []
    unrecorded: list[str] = []
    for recipe in recipes:
        cid = recipe["catalog_id"]
        digest = body_sha256(recipe)
        history = ledger.get(cid, [])
        if history and history[-1]["body_sha256"] == digest:
            recipe["revision"] = history[-1]["revision"]
            continue
        if not bump:
            unrecorded.append(cid)
            continue
        revision = history[-1]["revision"] + 1 if history else 1
        ledger[cid] = [*history, {"revision": revision, "body_sha256": digest}]
        recipe["revision"] = revision
        bumped.append(cid)
    if unrecorded:
        raise SystemExit(
            f"{len(unrecorded)} recipes compiled to a body data/recipes/revisions.json "
            f"does not record as their latest revision: {', '.join(unrecorded[:20])}"
            f"{' ...' if len(unrecorded) > 20 else ''}. Installed apps skip a recipe "
            "whose revision does not go up; rerun compile_bundle.py --bump-revisions "
            "to give them the next revision.")
    return bumped


def seed(bundle_path: Path, path: Path = LEDGER) -> int:
    if path.exists():
        raise SystemExit(f"{path} already exists; seeding would discard its history")
    bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
    ledger = {r["catalog_id"]: [{"revision": r["revision"],
                                 "body_sha256": body_sha256(r)}]
              for r in bundle["recipes"]}
    write(ledger, path)
    return len(ledger)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("seed", help="record every recipe of a published bundle")
    s.add_argument("bundle", type=Path)
    args = ap.parse_args()
    n = seed(args.bundle)
    print(f"seeded {LEDGER} with {n} recipes from {args.bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
