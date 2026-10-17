"""Shared plumbing for the FridgeLuck originals tooling (data/recipes/originals/).

Loads the RS corpus linter (suite C, PR #88) from the commit pinned in
SUITE-PIN.json, merges the suite's fixture tables with the originals' own
reviewed extension shards (conversions, compound-allergen knowledge, rights
manifests), and discovers recipe files. Standard library only.

Design notes:
- The suite's own files are NEVER modified; when `evaluation/suites/recipes/`
  is not in the working tree (PR #88 not merged yet), the pinned blobs are
  extracted read-only into tools/.cache/ (gitignored).
- Originals' extension shards live inside each part directory
  (`<part>/tables/`) so two writer threads never edit the same file.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# part directory name -> (recipe id prefix, family label, allowed suite cuisines)
PARTS: dict[str, tuple[str, str, set[str] | None]] = {
    "part1-rewrite": ("rw", "bundled-rewrite", None),
    "east-southeast-asian": ("ea", "east-southeast-asian", {"asian"}),
    "south-asian": ("sa", "south-asian", {"indian"}),
    "middle-east-north-africa": ("me", "middle-east-north-africa", {"mediterranean"}),
    "latin-american": ("la", "latin-american", {"mexican"}),
    "european-american": ("eu", "european-american", {"american", "italian"}),
}

SUITE_FILES = ("rs.py", "bands.py", "rights.py", "allergens.json", "conversions.json")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def originals_dir() -> Path:
    return repo_root() / "data" / "recipes" / "originals"


def load_pin() -> dict[str, Any]:
    return json.loads((originals_dir() / "tools" / "SUITE-PIN.json").read_text())


def _ensure_commit(sha: str) -> None:
    r = subprocess.run(
        ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
        cwd=repo_root(), capture_output=True,
    )
    if r.returncode == 0:
        return
    pin = load_pin()
    # try the alpha branch first, then the pinned PR head ref
    for refspec in (f"refs/pull/{pin['suite_pr']}/head", "alpha"):
        subprocess.run(["git", "fetch", "-q", "origin", refspec],
                       cwd=repo_root(), check=False)
    r = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"],
                       cwd=repo_root(), capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"pinned commit {sha} not fetchable from origin")


def suite_dir() -> Path:
    """Path to the suite C directory (in-tree when merged, else .cache extraction)."""
    in_tree = repo_root() / "evaluation" / "suites" / "recipes"
    if (in_tree / "rs.py").is_file():
        return in_tree
    pin = load_pin()
    _ensure_commit(pin["suite_head"])
    cache = originals_dir() / "tools" / ".cache" / "suite-c"
    cache.mkdir(parents=True, exist_ok=True)
    marker = cache / "pin.txt"
    if not marker.exists() or marker.read_text().strip() != pin["suite_head"]:
        for fname in SUITE_FILES:
            blob = subprocess.run(
                ["git", "show", f"{pin['suite_head']}:evaluation/suites/recipes/{fname}"],
                cwd=repo_root(), capture_output=True, text=True, check=True,
            ).stdout
            (cache / fname).write_text(blob)
        marker.write_text(pin["suite_head"] + "\n")
    return cache


def bundled_sqlite_path() -> Path:
    """Path to the bundled USDA catalog sqlite (extracted from the pinned alpha)."""
    pin = load_pin()
    _ensure_commit(pin["alpha_head"])
    target = originals_dir() / "tools" / ".cache" / "usda_ingredient_catalog.sqlite"
    if not target.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        blob = subprocess.run(
            ["git", "show",
             f"{pin['alpha_head']}:apps/ios/Resources/usda_ingredient_catalog.sqlite"],
            cwd=repo_root(), capture_output=True, check=True,
        ).stdout
        target.write_bytes(blob)
    return target


def bundled_data_json_path() -> Path:
    pin = load_pin()
    _ensure_commit(pin["alpha_head"])
    target = originals_dir() / "tools" / ".cache" / "data.json"
    if not target.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        blob = subprocess.run(
            ["git", "show", f"{pin['alpha_head']}:apps/ios/Resources/data.json"],
            cwd=repo_root(), capture_output=True, text=True, check=True,
        ).stdout
        target.write_text(blob)
    return target


def load_suite_modules():
    """Import (and cache) the suite C modules rs / bands / rights."""
    d = suite_dir()
    if str(d) not in sys.path:
        sys.path.insert(0, str(d))
    import rs  # noqa: E402  (suite C recipes-grammar + linter)
    import bands  # noqa: E402  (declared coverage bands)
    import rights  # noqa: E402  (rights manifest validation)
    return rs, bands, rights


def table_shards(name: str, part: str | None = None) -> list[Path]:
    """All <part>/tables/<name> shards, optionally restricted to one part."""
    shards: list[Path] = []
    part_iter = [part] if part else sorted(PARTS)
    for p in part_iter:
        f = originals_dir() / p / "tables" / name
        if f.is_file():
            shards.append(f)
    return shards


def load_conversions(part: str | None = None) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """Suite fixture conversions merged with every part shard.

    Returns (merged, conflicts) where conflicts lists refs defined twice with
    different grams_per_unit (a hard error for callers).
    """
    conv = dict(json.loads((suite_dir() / "conversions.json").read_text())["conversions"])
    conflicts: list[str] = []
    for shard_path in table_shards("conversions.json", part):
        shard = json.loads(shard_path.read_text())
        for ref, entry in shard.get("conversions", {}).items():
            if ref in conv and abs(
                    float(conv[ref].get("grams_per_unit", 0) or 0)
                    - float(entry.get("grams_per_unit", 0) or 0)) > 1e-9:
                conflicts.append(ref)
            else:
                conv[ref] = entry
    return conv, conflicts


def load_compound_entries(part: str | None = None) -> list[dict[str, Any]]:
    """Shared compound-allergen knowledge + per-part extensions."""
    entries: list[dict[str, Any]] = []
    shared = originals_dir() / "tools" / "compound-allergens.json"
    if shared.is_file():
        entries.extend(json.loads(shared.read_text())["entries"])
    for shard_path in table_shards("compound-allergens.json", part):
        entries.extend(json.loads(shard_path.read_text()).get("entries", []))
    return entries


def load_rights_manifests(part: str | None = None) -> tuple[dict[str, dict[str, Any]], list[Path]]:
    """Merge all part rights manifests; returns (records, shard_paths)."""
    records: dict[str, dict[str, Any]] = {}
    shards: list[Path] = []
    for shard in table_shards("rights-manifest.json", part):
        shards.append(shard)
        data = json.loads(shard.read_text())
        for ref, rec in data.get("records", {}).items():
            if ref in records:
                raise ValueError(f"rights record {ref!r} defined twice ({shard})")
            records[ref] = rec
    return records, shards


class StrictScanner:
    """Compound-ingredient allergen knowledge layered on the suite's alias table.

    Entries: {"pattern": str (lowercase substring), "classes": [str...],
    "unless": [str...] (skip entry when the ingredient name contains one),
    "note": str}.
    """

    def __init__(self, entries: list[dict[str, Any]]) -> None:
        self.entries = entries

    def classes(self, recipe: dict[str, Any]) -> set[str]:
        found: set[str] = set()
        for line in recipe.get("ingredients", []):
            name = str(line.get("name", "")).strip().lower()
            for e in self.entries:
                if e["pattern"] in name:
                    if any(u in name for u in e.get("unless", [])):
                        continue
                    found |= set(e.get("classes", []))
        return found


STOPWORDS = {"easy", "quick", "healthy", "simple", "best", "the", "a", "an",
             "of", "with", "and", "recipe"}

# Ingredients whose defining nutritional contribution is sodium. If one of
# these is UNMAPPED in nutrition-map.json, the computed sodium under-counts
# and the nutrition block must be flagged `incomplete-salty-unmapped`.
# (substring, lowercase) — shared by tools/nutrition.py and tools/validate.py.
SALTY_PATTERNS = (
    "soy sauce", "fish sauce", "tamari", "miso", "stock", "broth", "bouillon",
    "salt", "bacon", "anchov", "cured", "sausage", "hot dog", "prosciutto",
    "pancetta", "salami", "ham", "cheese", "parmesan", "feta", "pickle",
    "olive", "caper", "fish paste", "shrimp paste", "oyster sauce", "hoisin",
    "sriracha", "hot sauce", "buffalo sauce", "teriyaki", "kimchi",
    "soybean paste", "doubanjiang", "gochujang", "salted",
)


def normalize_title(title: str) -> str:
    t = re.sub(r"[^a-z0-9 ]", " ", title.lower())
    return " ".join(w for w in t.split() if w not in STOPWORDS)


def discover_recipes(part: str) -> tuple[list[tuple[Path, dict[str, Any]]],
                                         list[tuple[Path, str]]]:
    """All recipe files in one part dir. A recipe file is a JSON object with
    rs_version; anything else (shards, indexes) is ignored."""
    recipes: list[tuple[Path, dict[str, Any]]] = []
    bad: list[tuple[Path, str]] = []
    part_dir = originals_dir() / part
    if not part_dir.is_dir():
        return recipes, bad
    for p in sorted(part_dir.rglob("*.json")):
        rel = p.relative_to(part_dir)
        if "tables" in rel.parts:
            continue
        try:
            d = json.loads(p.read_text())
        except json.JSONDecodeError as exc:
            bad.append((p, f"unparseable JSON: {exc}"))
            continue
        if not isinstance(d, dict) or "rs_version" not in d:
            continue
        if not isinstance(d.get("id"), str) or not d["id"]:
            bad.append((p, "recipe object without an id"))
            continue
        recipes.append((p, d))
    return recipes, bad


def resolved_grams(line: dict[str, Any]) -> float | None:
    """Grams a line resolves to, or None (unknown evidence or no conversion)."""
    qty = line.get("qty")
    if not isinstance(qty, dict):
        return None
    kind = qty.get("kind")
    if kind in ("weighed", "source_grams"):
        g = qty.get("grams")
        return float(g) if isinstance(g, (int, float)) and g > 0 else None
    if kind == "household":
        g = qty.get("grams")
        if isinstance(g, (int, float)) and g > 0:
            return float(g)
        v, gpu = qty.get("value"), qty.get("grams_per_unit")
        if isinstance(v, (int, float)) and isinstance(gpu, (int, float)) and v > 0 and gpu > 0:
            return float(v) * float(gpu)
    return None
