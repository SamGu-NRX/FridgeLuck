#!/usr/bin/env python3
"""Convert PR #114's reviewed substitution table into the app's shipped JSON.

Reads ``data/substitutions/pairs.json`` (schema 1.1.0, branch
``overhaul/substitution-table``) and the app's bundled ingredient catalog
(``apps/ios/Resources/data.json``), maps every pair endpoint to the app's
Int64 ``ingredients.id`` (exact catalog name, recorded alias, or USDA fdc id),
and writes ``apps/ios/Resources/Substitutions/substitutions-v1.json`` with the
source commit recorded.

Fail-closed rules (SPEC docs/spec/lechef/SPEC.md §6):

- A table ingredient is mapped only on *exact* evidence: normalized key,
  display name, a recorded alias, or an unambiguous fdc-id equality.  No
  fuzzy matching, ever.
- An ingredient whose candidates hit two different app ids is ambiguous and
  is treated as unmapped.
- An unmapped ingredient never enters the shipped file: every pair touching
  it is dropped and counted in the file's ``audit`` section.  ``--strict``
  turns any unmapped ingredient into a non-zero exit instead.
- A ``facts_key`` of null ships ``compositionKnown: false``; the app's
  recheck treats that as "ask the user", never "safe".
- The verdict per role follows SCHEMA.md's ContextRules table exactly;
  ``unknown`` is never upgraded to fit.

The output is deterministic: sorted keys, 2-space indent, trailing newline.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

OUTPUT_SCHEMA_VERSION = "1.0.0"
CONVERTER_PATH = "scripts/substitutions/convert.py"
DEFAULT_OUTPUT = "apps/ios/Resources/Substitutions/substitutions-v1.json"

# Only mass statements scale arithmetically in grams (SCHEMA.md, macro-delta
# method).  Everything else is stated as the kitchen measure, never converted.
SCALING_BASES = {"weight", "weight-cooked"}

_NO_CHANGE = re.compile(r"no\s+change", re.IGNORECASE)


class ConvertError(Exception):
    """Fatal conversion problem (strict mode, validation failure, bad input)."""


def normalize(name: str) -> str:
    """Normalized name for exact matching: trimmed, casefolded, single-spaced."""
    return " ".join(name.strip().casefold().split())


@dataclass(frozen=True)
class Resolution:
    app_id: int
    how: str  # "name" | "alias" | "fdc"


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


class Catalog:
    """The app's bundled 50-ingredient catalog (data.json)."""

    def __init__(self, data: dict) -> None:
        self.name_to_id: dict[str, int] = {}
        self.fdc_to_ids: dict[int, set[int]] = {}
        for raw_id, fields in data["ingredients"].items():
            app_id = int(raw_id)
            display = fields[0]
            self.name_to_id.setdefault(normalize(display), app_id)
            fdc = fields[1]
            if isinstance(fdc, int):
                self.fdc_to_ids.setdefault(fdc, set()).add(app_id)

    def by_display(self, raw_id: int) -> str:
        return str(raw_id)


def resolve_ingredient(
    table_key: str,
    record: dict,
    catalog: Catalog,
) -> Resolution | None:
    """Map one table ingredient to an app id, or None when it fails closed.

    Priority: key/display/alias exact name, then unique fdc-id equality.
    Any ambiguity (two different app ids among the candidates) fails closed.
    """
    candidates: list[str] = [table_key, table_key.replace("_", " ")]
    display = record.get("display")
    if display:
        candidates.append(display)
    candidates.extend(record.get("aliases") or [])

    hits: set[int] = set()
    for candidate in candidates:
        if app_id := catalog.name_to_id.get(normalize(candidate)):
            hits.add(app_id)
    if len(hits) > 1:
        return None  # ambiguous: fail closed
    if len(hits) == 1:
        return Resolution(next(iter(hits)), "name")

    fdc = record.get("fdc_id")
    if isinstance(fdc, int):
        ids = catalog.fdc_to_ids.get(fdc, set())
        if len(ids) == 1:
            return Resolution(next(iter(ids)), "fdc")
        if len(ids) > 1:
            return None  # ambiguous fdc: fail closed
    return None



def verdict_for(function_status: str | None, ratio_status: str | None) -> str:
    """SCHEMA.md's ContextRules.verdict table. Unknown is never upgraded."""
    if function_status == "sourced" and ratio_status == "sourced":
        return "verified"
    if function_status in (None, "unknown") or ratio_status in (None, "unknown"):
        return "unknown"
    if ratio_status == "conflict":
        return "plausible"
    if ratio_status == "unsupported":
        return "unsupported"
    return "plausible"  # sourced/convention function + convention ratio


def ratio_payload(ratio: dict | None) -> dict | None:
    if ratio is None:
        return None
    basis = ratio.get("basis") or "weight"
    return {
        "value": ratio.get("value"),
        "basis": basis,
        "status": ratio.get("status"),
        "scales": basis in SCALING_BASES,
        "note": ratio.get("note"),
    }


def fits_for_pair(pair: dict) -> tuple[list[dict], list[dict]]:
    """Role fits (primary + supported_also) and functionally excluded roles."""
    fails = pair.get("fails") or []
    primary_fits: list[dict] = []
    excluded: list[dict] = []

    primary_role = pair["role"]
    functional = [f for f in fails if f.get("role") == primary_role and f.get("kind") == "functional"]
    conditional = [
        f for f in fails if f.get("role") == primary_role and f.get("kind") == "conditional"
    ]
    if functional:
        excluded.append(
            {"role": primary_role, "kind": "functional", "why": functional[0].get("why")}
        )
    else:
        primary_fits.append(
            {
                "role": primary_role,
                "verdict": verdict_for(pair.get("function_status"), (pair.get("ratio") or {}).get("status")),
                "functionStatus": pair.get("function_status"),
                "ratio": ratio_payload(pair.get("ratio")),
                "conditionalFor": sorted(
                    {r for f in conditional for r in (f.get("restrictions") or [])}
                ),
            }
        )

    for also in pair.get("supported_also") or []:
        role = also.get("role")
        if role is None:
            continue
        role_functional = [f for f in fails if f.get("role") == role and f.get("kind") == "functional"]
        role_conditional = [f for f in fails if f.get("role") == role and f.get("kind") == "conditional"]
        if role_functional:
            excluded.append(
                {"role": role, "kind": "functional", "why": role_functional[0].get("why")}
            )
            continue
        also_ratio = also.get("ratio")
        # An alternative role never inherits the primary ratio.  A missing
        # ratio row stays "unknown" — never upgraded to fit (SCHEMA.md).
        primary_fits.append(
            {
                "role": role,
                "verdict": verdict_for(also.get("status"), (also_ratio or {}).get("status")),
                "functionStatus": also.get("status"),
                "ratio": ratio_payload(also_ratio),
                "conditionalFor": sorted(
                    {r for f in role_conditional for r in (f.get("restrictions") or [])}
                ),
            }
        )

    return primary_fits, excluded


def recheck_payload(table: dict, substitute_key: str, primary_verdict: str) -> dict:
    record = table["ingredients"][substitute_key]
    classes = record.get("classes") or []
    shared = [c for c in classes if c in table["allergen_classes"]]
    diet = [c for c in classes if c not in table["allergen_classes"]]
    return {
        "verdict": primary_verdict,
        "allergenClasses": shared,
        "dietClasses": diet,
        "allergenNote": record.get("allergen_note"),
        "compositionKnown": record.get("facts_key") is not None,
    }


def convert(
    table: dict,
    app_data: dict,
    source_commit: str,
    table_branch: str,
) -> dict:
    catalog = Catalog(app_data)

    referenced: set[str] = set()
    for pair in table["pairs"]:
        referenced.add(pair["original"])
        referenced.add(pair["substitute"])

    resolution: dict[str, Resolution | None] = {}
    for key in referenced:
        resolution[key] = resolve_ingredient(key, table["ingredients"][key], catalog)

    swaps: list[dict] = []
    dropped = 0
    for pair in table["pairs"]:
        original = resolution[pair["original"]]
        substitute = resolution[pair["substitute"]]
        if original is None or substitute is None:
            dropped += 1
            continue

        difference = pair.get("difference") or ""
        if not difference.strip() or _NO_CHANGE.search(difference):
            raise ConvertError(f"pair {pair['id']}: difference must state the change, never 'no change'")
        if not pair.get("source_ids"):
            raise ConvertError(f"pair {pair['id']}: missing source_ids")

        fits, excluded = fits_for_pair(pair)
        if not fits:
            dropped += 1
            continue

        primary_verdict = next(
            (f["verdict"] for f in fits if f["role"] == pair["role"]),
            fits[0]["verdict"],
        )
        swaps.append(
            {
                "pairId": pair["id"],
                "originalId": original.app_id,
                "originalKey": pair["original"],
                "substituteId": substitute.app_id,
                "substituteKey": pair["substitute"],
                "role": pair["role"],
                "fits": fits,
                "excludedRoles": excluded,
                "preparation": pair.get("preparation") or [],
                "difference": difference,
                "sourceIds": list(pair.get("source_ids") or []),
                "recheck": recheck_payload(table, pair["substitute"], primary_verdict),
            }
        )

    swaps.sort(key=lambda s: (s["originalId"], s["substituteId"], s["pairId"]))
    unmapped = sorted(k for k, r in resolution.items() if r is None)
    mapped = sorted((k for k, r in resolution.items() if r is not None), key=str)

    return {
        "schemaVersion": OUTPUT_SCHEMA_VERSION,
        "source": {
            "table": "data/substitutions/pairs.json",
            "tableSchemaVersion": table["schema_version"],
            "tableCreated": table["created"],
            "tableBranch": table_branch,
            "sourceCommit": source_commit,
            "converter": CONVERTER_PATH,
        },
        "roles": list(table["roles"]),
        "allergenClasses": list(table["allergen_classes"]),
        "restrictions": {
            name: {"forbids": sorted(defn.get("forbids") or [])}
            for name, defn in sorted(table["restrictions"].items())
        },
        "audit": {
            "referencedIngredients": len(referenced),
            "mappedIngredients": len(mapped),
            "mappedKeys": mapped,
            "unmappedIngredients": len(unmapped),
            "unmappedKeys": unmapped,
            "pairsTotal": len(table["pairs"]),
            "pairsShipped": len(swaps),
            "pairsDropped": dropped,
        },
        "swaps": swaps,
    }


def validate(document: dict) -> None:
    """Ship-blocking checks on the emitted document."""
    for swap in document["swaps"]:
        if not swap["sourceIds"]:
            raise ConvertError(f"{swap['pairId']}: no sourceIds")
        if _NO_CHANGE.search(swap["difference"]):
            raise ConvertError(f"{swap['pairId']}: difference promises 'no change'")
        if not swap["fits"]:
            raise ConvertError(f"{swap['pairId']}: no role fits")
        recheck = swap["recheck"]
        if not recheck["compositionKnown"] and recheck["allergenClasses"]:
            # Unknown composition must fail closed even when labels claim clean.
            raise ConvertError(
                f"{swap['pairId']}: composition unknown but allergenClasses non-empty"
            )
        for fit in swap["fits"]:
            if fit["role"] not in document["roles"]:
                raise ConvertError(f"{swap['pairId']}: unknown role {fit['role']}")


def dump(document: dict) -> str:
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--table", required=True, type=Path, help="path to pairs.json")
    parser.add_argument("--app-data", required=True, type=Path, help="path to apps/ios/Resources/data.json")
    parser.add_argument("--out", type=Path, default=Path(DEFAULT_OUTPUT))
    parser.add_argument("--source-commit", required=True, help="git commit pairs.json was taken from")
    parser.add_argument("--table-branch", default="overhaul/substitution-table")
    parser.add_argument("--strict", action="store_true", help="fail on any unmapped ingredient")
    args = parser.parse_args(argv)

    table = load_json(args.table)
    app_data = load_json(args.app_data)
    if table.get("schema_version") != "1.1.0":
        raise ConvertError(f"expected pairs.json schema 1.1.0, got {table.get('schema_version')}")

    document = convert(table, app_data, args.source_commit, args.table_branch)

    unmapped = document["audit"]["unmappedIngredients"]
    if args.strict and unmapped:
        print(
            "unmapped ingredients (fail closed): "
            + ", ".join(document["audit"]["unmappedKeys"]),
            file=sys.stderr,
        )
        return 2

    validate(document)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(dump(document), encoding="utf-8")

    audit = document["audit"]
    print(
        f"wrote {args.out}: {audit['pairsShipped']}/{audit['pairsTotal']} pairs, "
        f"{audit['mappedIngredients']}/{audit['referencedIngredients']} ingredients mapped, "
        f"{audit['pairsDropped']} pairs dropped fail-closed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
