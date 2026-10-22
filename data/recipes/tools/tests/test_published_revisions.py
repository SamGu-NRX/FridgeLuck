"""The compiled bundle against the bundle alpha publishes.

Installed apps re-hydrate a catalog recipe only when the shipped revision is
higher than the stored one (RecipeBundleV2Loader.upsertV2Recipe), and they
keep one nutrition snapshot per (catalog_id, revision) that logged meals
report against. So, against the published bundle:

- a recipe whose compiled body changed must ship a higher revision, or
  installed apps keep the old lines and kcal, and the old revision's frozen
  snapshot would no longer describe what that revision number ships;
- a revision never goes backwards.

The published bundle is read from git (origin/alpha). The test skips only
when that ref is not available in the checkout.
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[4]
BUNDLE = REPO / "data/recipes/build/recipes-v2.json"
PUBLISHED_REF = "origin/alpha"


def published_bundle() -> dict:
    out = subprocess.run(
        ["git", "show", f"{PUBLISHED_REF}:data/recipes/build/recipes-v2.json"],
        capture_output=True, cwd=REPO)
    if out.returncode != 0:
        pytest.skip(f"{PUBLISHED_REF} bundle not readable from git: "
                    f"{out.stderr.decode(errors='replace').strip()}")
    return json.loads(out.stdout)


def body(recipe: dict) -> dict:
    return {k: v for k, v in recipe.items() if k != "revision"}


def test_changed_recipes_ship_a_higher_revision_than_published():
    published = {r["catalog_id"]: r for r in published_bundle()["recipes"]}
    current = json.load(BUNDLE.open())["recipes"]

    stale = []
    reused = []
    for recipe in current:
        old = published.get(recipe["catalog_id"])
        if old is None:
            continue
        if body(recipe) != body(old):
            if recipe["revision"] <= old["revision"]:
                stale.append(f"{recipe['catalog_id']} (revision {recipe['revision']}, "
                             f"published {old['revision']})")
        elif recipe["revision"] < old["revision"]:
            reused.append(f"{recipe['catalog_id']} (revision {recipe['revision']} "
                          f"< published {old['revision']})")

    assert not stale, (
        f"{len(stale)} recipes changed against {PUBLISHED_REF} but keep their "
        f"revision, so installed apps never load them: {stale[:10]}")
    assert not reused, f"revisions went backwards: {reused[:10]}"
