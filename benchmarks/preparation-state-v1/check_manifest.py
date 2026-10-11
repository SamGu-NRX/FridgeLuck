#!/usr/bin/env python3
"""Validate the frozen preparation-state-v1 manifest.

Checks group splits, synthetic labels, and unknown-state targets against the
pinned bundled USDA catalog. Read-only: opens the catalog with mode=ro and
never writes to it.

Run: python3 check_manifest.py [--manifest manifest.json]
Exit 0 if every check passes, 1 otherwise (diagnostics on stderr/stdout).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parent
REPO_ROOT = BENCH_ROOT.parents[1]
DEFAULT_MANIFEST = BENCH_ROOT / "manifest.json"

FAMILIES = ("identity", "state", "unknown_state")
SPLITS = ("train", "dev", "test")
MIN_GROUPS = 150
NUTRIENTS = ("calories", "protein", "carbs", "fat", "fiber", "sugar", "sodium")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_catalog_rows(catalog_path: Path) -> dict[int, dict]:
    conn = sqlite3.connect(f"file:{catalog_path}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT id, name, calories, protein, carbs, fat, fiber, sugar, sodium FROM ingredients"
        ).fetchall()
    finally:
        conn.close()
    return {
        r[0]: {
            "name": r[1],
            "per100g": dict(zip(NUTRIENTS, r[2:])),
        }
        for r in rows
    }


def check(manifest: dict, catalog_path: Path) -> list[str]:
    """Return a list of violation strings; empty means the manifest passes."""
    errors: list[str] = []
    add = errors.append

    prov = manifest.get("provenance", {})
    groups = manifest.get("groups", [])
    probes = manifest.get("probes", [])

    # --- provenance pin -----------------------------------------------------
    pinned_sha = prov.get("catalog_sha256")
    if not pinned_sha:
        add("provenance.catalog_sha256 missing")
    elif not catalog_path.exists():
        add(f"pinned catalog not found at {catalog_path}")
    else:
        actual_sha = sha256_file(catalog_path)
        if actual_sha != pinned_sha:
            add(
                "pinned catalog sha256 mismatch: manifest "
                f"{pinned_sha} != actual {actual_sha}"
            )
        else:
            rows = load_catalog_rows(catalog_path)

            # --- groups bound to source records -----------------------------
            if len(groups) < MIN_GROUPS:
                add(f"group count {len(groups)} below floor {MIN_GROUPS}")
            seen_group_ids: set[str] = set()
            for g in groups:
                gid = g.get("group_id", "<missing>")
                if gid in seen_group_ids:
                    add(f"duplicate group_id {gid!r}")
                seen_group_ids.add(gid)
                members = g.get("members", [])
                if not members:
                    add(f"group {gid!r} has no members")
                for m in members:
                    cid = m.get("catalog_id")
                    row = rows.get(cid) if rows else None
                    if row is None:
                        add(f"group {gid!r} member {cid} not in pinned catalog")
                        continue
                    if m.get("name") != row["name"]:
                        add(
                            f"group {gid!r} member {cid} name drift: "
                            f"manifest {m.get('name')!r} != catalog {row['name']!r}"
                        )
                    # Nutrient values are deliberately not copied into the
                    # manifest: the pinned catalog stays the single source of
                    # truth, read at analysis time. A stateful member must carry
                    # at least one canonical (probeable) state.
                    canonical = set(prov.get("surface_words", {}).values())
                    stateful = bool(m.get("states"))
                    if stateful and not (set(m["states"]) & canonical):
                        add(f"group {gid!r} member {cid} has only non-canonical states")

            # --- splits ------------------------------------------------------
            split_groups: dict[str, set[str]] = {sp: set() for sp in SPLITS}
            for p in probes:
                sp = p.get("split")
                gid = p.get("probe_id", "<unknown>")
                if sp not in SPLITS:
                    add(f"probe {gid!r} has invalid split {sp!r}")
                else:
                    split_groups[sp].add(p["probe_id"])
            all_ids = [p.get("probe_id") for p in probes]
            if len(all_ids) != len(set(all_ids)):
                add("duplicate probe_id values")

            # --- probes: synthetic labels and unknown targets ----------------
            group_by_base = {g["group_id"]: g for g in groups}
            member_ids_by_group = {
                g["group_id"]: {m["catalog_id"] for m in g["members"]} for g in groups
            }
            states_by_group: dict[str, dict[int, set[str]]] = {}
            for g in groups:
                states_by_group[g["group_id"]] = {
                    m["catalog_id"]: set(m.get("states", [])) for m in g["members"]
                }
            surface = prov.get("surface_words", {})
            state_pat = re.compile(r"^([a-z]+) (.+)$")

            for p in probes:
                pid = p.get("probe_id", "<unknown>")
                fam = p.get("family")
                text = p.get("text", "")
                target = p.get("target", {})
                m = state_pat.match(text)
                if fam in ("state", "unknown_state"):
                    if not m:
                        add(f"probe {pid!r} text {text!r} is not '<surface> <base>'")
                        continue
                    surface_word, base = m.group(1), m.group(2)
                    # Specificity guard: only the canonical surface word and the
                    # base name may appear; finer source descriptors must not.
                    if surface_word not in surface.values():
                        add(f"probe {pid!r} uses non-canonical state word {surface_word!r}")
                    if base not in group_by_base:
                        add(f"probe {pid!r} base {base!r} is not a frozen group")
                        continue
                    g = group_by_base[base]
                    if p.get("split") and text and not _group_in_split(g, p["split"]):
                        add(
                            f"probe {pid!r} split {p['split']} does not match its "
                            "group's split"
                        )
                    rid = target.get("record_id")
                    state = target.get("state")
                    if fam == "state":
                        if rid is None:
                            add(f"state probe {pid!r} must have a record target")
                            continue
                        if rid not in member_ids_by_group[base]:
                            add(
                                f"state probe {pid!r} target {rid} is outside its "
                                f"group {base!r} (synthetic label must stay in-group)"
                            )
                        if surface_word != surface.get(state):
                            add(f"state probe {pid!r} surface word does not match target state")
                        if state not in states_by_group[base].get(rid, set()):
                            add(
                                f"state probe {pid!r} target {rid} does not establish "
                                f"state {state!r} in the source"
                            )
                        same_state = [
                            other
                            for other, ss in states_by_group[base].items()
                            if state in ss and other != rid
                        ]
                        if same_state:
                            add(
                                f"state probe {pid!r} state {state!r} is not unique in "
                                f"group {base!r}: also {same_state}"
                            )
                    else:  # unknown_state
                        if rid is not None:
                            add(
                                f"unknown-state probe {pid!r} must abstain (record_id "
                                f"null), got {rid}"
                            )
                        if state not in surface.values():
                            add(f"unknown-state probe {pid!r} non-canonical state {state!r}")
                        members_with_state = [
                            cid for cid, ss in states_by_group[base].items() if state in ss
                        ]
                        if members_with_state:
                            add(
                                f"unknown-state probe {pid!r} invalid: group {base!r} "
                                f"does establish {state!r} ({members_with_state})"
                            )
                elif fam == "identity":
                    if text not in group_by_base:
                        add(f"identity probe {pid!r} text {text!r} is not a frozen group")
                        continue
                    if p.get("split") and not _group_in_split(group_by_base[text], p["split"]):
                        add(
                            f"probe {pid!r} split {p['split']} does not match its "
                            "group's split"
                        )
                    rid = target.get("record_id")
                    if rid is None:
                        add(f"identity probe {pid!r} must have a record target")
                    elif len(group_by_base[text]["members"]) != 1:
                        add(
                            f"identity probe {pid!r} group {text!r} is not single-member; "
                            "target would be ambiguous"
                        )
                else:
                    add(f"probe {pid!r} has unknown family {fam!r}")

    return errors


def _group_in_split(group: dict, split: str) -> bool:
    # The split is a pure function of the group id; recompute it the same way
    # build_manifest.py does.
    digest = hashlib.sha256(group["group_id"].encode("utf-8")).hexdigest()
    bucket = int(digest[:8], 16) % 100
    expected = "train" if bucket < 60 else ("dev" if bucket < 80 else "test")
    return split == expected


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    ap.add_argument("--catalog", default=None)
    args = ap.parse_args()

    manifest_path = Path(args.manifest)
    manifest = json.loads(manifest_path.read_text())
    catalog_arg = args.catalog
    if catalog_arg is None:
        rel = manifest.get("provenance", {}).get("catalog_path")
        catalog_arg = str(REPO_ROOT / rel) if rel else None
    if not catalog_arg:
        print("no catalog path: manifest provenance missing", file=sys.stderr)
        return 1

    errors = check(manifest, Path(catalog_arg))
    counts = manifest.get("counts", {})
    print("counts:", json.dumps(counts, sort_keys=True))
    if errors:
        print(f"FAIL: {len(errors)} violation(s)", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"OK: {counts.get('groups')} groups, {counts.get('probes')} probes verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
