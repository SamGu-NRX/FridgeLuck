#!/usr/bin/env python3
"""Packet checker for the pantry-2026-10 batch.

The repository's packet checker (data/recipe-sources/world-2026-10/src/
check_packet.py) is packet-specific: it hardcodes the fl-world-NNNN id
sequence, its own manifest path, and its own FNDDS registry. Rather than
fork its logic, this wrapper reuses it directly on adapted record copies:

  * records are re-id'd fl-pantry-NNNN -> fl-world-NNNN (same order), so the
    sequence gate, the suite linter, the FNDDS quantity recompute, the rights
    gate, and the release gates all run unmodified;
  * the manifest passed in is THIS packet's evidence/originals-rights-
    manifest.json, keyed by the same fl-pantry:slug source_refs the records
    carry — the gate therefore validates the pantry packet's own rights
    rows;
  * violations are reported with the real fl-pantry ids.

Extra checks the world checker cannot express are run here against the
pantry fixtures: every record title/keyword names a stocked item and a
non-staple recipe line is stocked (or the dish deliberately uses only
staple lines). Exact cookability is measured, not asserted here — the
numbers live in VALIDATION.md / evidence/reach-after.json, produced by
src/run_reach.py.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG = HERE.parent
WORLD_SRC = PKG.parent / "world-2026-10" / "src"
sys.path.insert(0, str(WORLD_SRC))
sys.path.insert(0, str(HERE))

# Load the repository packet checker by path under a distinct module name:
# this file shares its filename, so a plain `import check_packet` would
# re-import this wrapper.
_spec = importlib.util.spec_from_file_location(
    "world_check_packet", WORLD_SRC / "check_packet.py")
world = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(world)

REACH_FIXTURES = (PKG.parent.parent.parent / "evaluation"
                  / "catalog-reach" / "pantries-v2.json")
# Pantry-independent kitchen staples: excluded from the "signature
# ingredient" half of the pantry-signal gate, because a dish that only
# shares salt and oil with a pantry says nothing about its fit.
STAPLES = {"olive oil", "flour", "butter", "sugar", "eggs", "salt",
           "black pepper", "milk", "onion", "garlic", "rice", "pasta",
           "potatoes", "bread", "canned tomatoes"}


def load_records(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines()
            if line.strip()]


def adapted(records: list[dict]) -> list[dict]:
    """World-checker copies: fl-world-NNNN ids, same order."""
    out = []
    for n, r in enumerate(records, start=1):
        c = dict(r)
        c["id"] = f"fl-world-{n:04d}"
        out.append(c)
    return out


def back(v: list[str], records: list[dict]) -> list[str]:
    """Translate fl-world-NNNN ids in violation strings back to fl-pantry."""
    for i, x in enumerate(v):
        for n, r in enumerate(records, start=1):
            x = x.replace(f"fl-world-{n:04d}", r["id"])
        v[i] = x
    return v


def all_pantry_names(entry: dict) -> set[str]:
    """Every stocked item name, staples included: rice, eggs, and potatoes
    are real pantry identities and legitimately name a dish."""
    names = set()
    for item in entry.get("items", entry.get("ingredients", [])):
        if isinstance(item, str):
            names.add(item.strip().lower())
        elif isinstance(item, dict):
            nm = item.get("name") or item.get("ingredient")
            if nm:
                names.add(str(nm).strip().lower())
    return names


def pantry_names(entry: dict) -> set[str]:
    """Stocked item names with staples stripped, for signature matching."""
    return all_pantry_names(entry) - STAPLES


def _stems(text: str) -> set[str]:
    """Crude singular stems, so 'black beans' matches 'black bean' in a
    title and 'pork chops' matches a 'pork chop' line."""
    out: set[str] = set()
    for w in re.findall(r"[a-z]+", text.lower()):
        if w.endswith("ies") and len(w) > 4:
            out.add(w[:-3] + "y")
        elif re.search(r"(?:[sxz]|ch|sh)es$", w) and len(w) > 3:
            out.add(w[:-2])
        elif w.endswith("oes") and len(w) > 3:
            out.add(w[:-2])
        elif w.endswith("s") and not w.endswith("ss") and len(w) > 2:
            out.add(w[:-1])
        else:
            out.add(w)
    return out


def pantry_signal_checks(records: list[dict], pantries: dict) -> list[str]:
    """Pantry-specific gate: every dish anchors to at least one fixture
    pantry — its title/keywords name a stocked item, and either a
    non-staple recipe line is stocked by that pantry or the dish
    deliberately uses only staple lines. Name-level signal only; exact
    cookability ground truth is src/run_reach.py's measured report."""
    v: list[str] = []
    for r in records:
        dish = _stems(r["title"])
        for k in r.get("keywords", []):
            dish |= _stems(k)
        nonstaple = [_stems(l["name"]) for l in r["ingredients"]
                     if l["name"].lower() not in STAPLES]
        ok = False
        for _, (every, special) in pantries.items():
            stems_all = {s for n in every for s in _stems(n)}
            if not stems_all & dish:
                continue
            stems_special = {s for n in special for s in _stems(n)}
            if not nonstaple or any(ls & stems_special for ls in nonstaple):
                ok = True
                break
        if not ok:
            v.append(f"{r['id']}: no pantry fixture names the dish (title or "
                     f"keyword) or stocks its signature ingredient")
    return v


def run_pantry_check(records: list[dict], manifest: dict,
                     pantries: dict) -> list[str]:
    v = back(world.run_check(adapted(records), manifest), records)
    v.extend(pantry_signal_checks(records, pantries))
    return v


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default=str(PKG / "originals.jsonl"))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    records = load_records(Path(args.corpus))
    manifest = json.loads(
        (PKG / "evidence" / "originals-rights-manifest.json").read_text())
    pantries = {str(entry.get("name", i)): (all_pantry_names(entry),
                                            pantry_names(entry))
                for i, entry in enumerate(json.loads(
                    REACH_FIXTURES.read_text())["pantries"])} \
        if REACH_FIXTURES.is_file() else {}
    if not pantries:
        print("pantry fixtures not found at "
              f"{REACH_FIXTURES}; pantry-signal gate skipped", file=sys.stderr)

    violations = run_pantry_check(records, manifest, pantries)

    canon, _ = world.rs.CanonRulebook.load(None)
    table = world.merged_classification_table()
    veg = sum(1 for r in records if world.is_vegetarian(r, table, canon))
    slots: dict[str, int] = {}
    for r in records:
        for s in r.get("meal_slots", []):
            slots[s] = slots.get(s, 0) + 1

    print(f"checked {len(records)} records (pantry-2026-10)")
    print(f"vegetarian {veg}/{len(records)} "
          f"({veg / max(len(records), 1):.1%}); slots {slots}")
    if violations:
        print(f"FAILED with {len(violations)} violation(s):")
        for x in violations:
            print("  " + x)
        return 1
    print("PASS: rights, quantities, pinned lint, release gates, and "
          "pantry-signal checks all clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
