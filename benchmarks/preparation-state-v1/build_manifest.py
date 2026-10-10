#!/usr/bin/env python3
"""Freeze the preparation-state-v1 manifest from the pinned bundled USDA catalog.

Source of truth: apps/ios/Resources/usda_ingredient_catalog.sqlite (sha256 pinned
in the manifest). Every group and probe is bound to catalog record ids from that
file; no record is invented, and preparation states are extracted only from the
descriptors the source itself establishes in its names.

Preparation-state rule: a record's canonical state set is derived from the
parenthetical descriptor parts of its source name (e.g. "Peaches (Dried,
Sulfured)" -> {dried}). Only unambiguous descriptor tokens are mapped, and the
canonical state is always no more specific than the source text (a source
"Smoked, Cooked" record becomes canonical "cooked"; the verbatim descriptor is
kept in the manifest as provenance).

Probe families (labels are synthetic, built from the frozen records):
  identity       "<base>"                  -> the group's only record
  state          "<surface> <base>"        -> the record whose source establishes that state
  unknown_state  "<surface> <base>"        -> ABSTAIN (no record in the group has that state)

Groups are split train/dev/test deterministically by sha256 of the group id.

Run: python3 build_manifest.py [--out manifest.json]
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

BENCH_ROOT = Path(__file__).resolve().parent
REPO_ROOT = BENCH_ROOT.parents[1]
CATALOG_PATH = REPO_ROOT / "apps" / "ios" / "Resources" / "usda_ingredient_catalog.sqlite"

# Canonical state mapping: only exact (case-insensitive) descriptor parts map.
# Anything not listed leaves the record stateless for that part. Canonical
# states are deliberately coarser than the source wording.
STATE_TOKENS = {
    "raw": "raw",
    "crude": "raw",
    "uncooked": "raw",
    "unprepared": "raw",
    "cooked": "cooked",
    "boiled": "cooked",
    "baked": "cooked",
    "roasted": "cooked",
    "dry roasted": "cooked",
    "smoked": "cooked",
    "microwaved": "cooked",
    "dried": "dried",
    "sun-dried": "dried",
    "dehydrated": "dried",
    "low-moisture": "dried",
    "frozen": "frozen",
    "canned": "canned",
    "canned/bottled": "canned",
}
# Secondary descriptors that refine a state but are not states themselves.
REFINED_TOKENS = {"drained"}

# Surface words used in probe text for each canonical state. The unknown-state
# probe order doubles as the deterministic choice order.
SURFACE = {
    "raw": "raw",
    "cooked": "cooked",
    "dried": "dried",
    "frozen": "frozen",
    "canned": "canned",
}
UNKNOWN_STATE_ORDER = ["cooked", "raw", "dried", "frozen", "canned"]

PAREN_RE = re.compile(r"[()]")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def descriptor_parts(name: str) -> list[str]:
    """Parenthetical descriptor parts, verbatim, in source order."""
    parts: list[str] = []
    for m in re.finditer(r"\(([^)]*)\)", name):
        for part in m.group(1).split(","):
            part = part.strip()
            if part:
                parts.append(part)
    return parts


def canonical_states(name: str) -> tuple[list[str], list[str]]:
    """(canonical states in source order, verbatim descriptor parts)."""
    parts = descriptor_parts(name)
    states: list[str] = []
    for part in parts:
        key = part.lower()
        if key in STATE_TOKENS:
            states.append(STATE_TOKENS[key])
    return states, parts


def base_name(name: str) -> str:
    """Name minus parentheticals, lowercased. Used verbatim as the group id and
    in probe text (production resolvers de-pluralize on their own)."""
    return PAREN_RE.sub("|", name).split("|")[0].strip().lower()


def split_for(group_id: str) -> str:
    digest = hashlib.sha256(group_id.encode("utf-8")).hexdigest()
    bucket = int(digest[:8], 16) % 100
    if bucket < 60:
        return "train"
    if bucket < 80:
        return "dev"
    return "test"


def load_catalog() -> tuple[str, list[dict]]:
    conn = sqlite3.connect(f"file:{CATALOG_PATH}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT id, name, calories, protein, carbs, fat, fiber, sugar, sodium "
            "FROM ingredients ORDER BY id"
        ).fetchall()
    finally:
        conn.close()
    records = [
        {
            "id": r[0],
            "name": r[1],
            "per100g": {
                "calories": r[2],
                "protein": r[3],
                "carbs": r[4],
                "fat": r[5],
                "fiber": r[6],
                "sugar": r[7],
                "sodium": r[8],
            },
        }
        for r in rows
    ]
    return sha256_file(CATALOG_PATH), records


def build() -> dict:
    catalog_sha, records = load_catalog()
    by_base: dict[str, list[dict]] = {}
    for rec in records:
        by_base.setdefault(base_name(rec["name"]), []).append(rec)

    groups: list[dict] = []
    for base in sorted(by_base):
        members = sorted(by_base[base], key=lambda r: r["id"])
        member_entries = []
        for rec in members:
            states, parts = canonical_states(rec["name"])
            member_entries.append(
                {
                    "catalog_id": rec["id"],
                    "name": rec["name"],
                    "descriptor": ", ".join(parts),
                    "states": states,
                }
            )
        stateful = [m for m in member_entries if m["states"]]
        groups.append(
            {
                "group_id": base,
                "base": base,
                "members": member_entries,
                "stateful_member_ids": [m["catalog_id"] for m in stateful],
            }
        )

    # Probes. One probe per distinct canonical state per group; duplicates
    # (two canned variants of one food) are resolved deterministically by id.
    probes: list[dict] = []
    for group in groups:
        base = group["base"]
        gid = group["group_id"]
        split = split_for(gid)

        # State probes: only for states this group establishes exactly once,
        # so the label is unambiguous within the group.
        state_count: dict[str, int] = {}
        for m in group["members"]:
            for s in set(m["states"]):
                state_count[s] = state_count.get(s, 0) + 1
        unique_states = {
            s for s in state_count if state_count[s] == 1 and s in SURFACE
        }

        if len(group["members"]) == 1:
            m = group["members"][0]
            probes.append(
                {
                    "probe_id": f"{gid}::identity",
                    "split": split,
                    "family": "identity",
                    "text": gid,
                    "target": {"record_id": m["catalog_id"], "state": m["states"][0] if m["states"] else None},
                }
            )

        seen_states: set[str] = set()
        for m in group["members"]:
            for s in m["states"]:
                if s not in unique_states or s in seen_states:
                    continue
                seen_states.add(s)
                probes.append(
                    {
                        "probe_id": f"{gid}::state::{s}",
                        "split": split,
                        "family": "state",
                        "text": f"{SURFACE[s]} {gid}",
                        "target": {"record_id": m["catalog_id"], "state": s},
                    }
                )

        # Unknown-state probe: a surface state no member of this group has.
        if state_count:
            unknown = next(
                (s for s in UNKNOWN_STATE_ORDER if s not in state_count), None
            )
            if unknown is not None:
                probes.append(
                    {
                        "probe_id": f"{gid}::unknown_state::{unknown}",
                        "split": split,
                        "family": "unknown_state",
                        "text": f"{SURFACE[unknown]} {gid}",
                        "target": {"record_id": None, "state": unknown},
                    }
                )

    counts = {
        "groups": len(groups),
        "records": len(records),
        "probes": len(probes),
        "probes_by_family": {
            fam: sum(1 for p in probes if p["family"] == fam)
            for fam in ("identity", "state", "unknown_state")
        },
        "probes_by_split": {
            sp: sum(1 for p in probes if p["split"] == sp) for sp in ("train", "dev", "test")
        },
        "groups_by_split": {
            sp: sum(1 for g in groups if split_for(g["group_id"]) == sp)
            for sp in ("train", "dev", "test")
        },
        "probes_by_state": {
            s: sum(1 for p in probes if p["family"] == "state" and p["target"]["state"] == s)
            for s in SURFACE
        },
    }

    manifest = {
        "benchmark": "preparation-state-v1",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "generator": "build_manifest.py",
        "provenance": {
            "catalog_path": str(CATALOG_PATH.relative_to(REPO_ROOT)),
            "catalog_sha256": catalog_sha,
            "repo_commit": _git_head(),
            "state_tokens": STATE_TOKENS,
            "surface_words": SURFACE,
            "notes": (
                "States come only from parenthetical descriptors in the bundled "
                "catalog's own record names; canonical states are coarser than or "
                "equal to the source wording. Probe text is built from the group "
                "base name plus a generic surface word; no target-specific wording "
                "(variety, fat level, pack medium) enters probe text."
            ),
        },
        "counts": counts,
        "groups": groups,
        "probes": probes,
    }
    return manifest


def _git_head() -> str:
    try:
        return subprocess_head()
    except Exception:
        return "unknown"


def subprocess_head() -> str:
    import subprocess

    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True).strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(BENCH_ROOT / "manifest.json"))
    args = ap.parse_args()
    manifest = build()
    path = Path(args.out)
    path.write_text(json.dumps(manifest, indent=1, sort_keys=False) + "\n")
    print(json.dumps(manifest["counts"], indent=1))
    print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
