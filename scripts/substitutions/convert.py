#!/usr/bin/env python3
"""Convert PR #114's reviewed substitution table into the app's shipped JSON.

Reads ``data/substitutions/pairs.json`` (schema 1.1.0, branch
``overhaul/substitution-table``) and the canonical ingredient vocabulary
(``data/ingredients/vocabulary.json``, PRs #158/#162), maps every pair
endpoint to a canonical vocabulary key, and writes
``apps/ios/Resources/Substitutions/substitutions-v2.json`` with the source
commit recorded.

App ingredient ids are deliberately NOT in the file: the runtime identity
bridge (``RecipeCatalogIngredientBridge``) maps canonical keys to app
ingredients from exactly the rows hydration wrote, so a shipped swap never
bakes in ids that drift from the installed database.

Fail-closed rules (SPEC docs/spec/lechef/SPEC.md §6):

- A table ingredient maps to a key only on *exact* evidence: normalized key,
  display name, a recorded alias, an unambiguous fdc-id equality, or the
  recorded USDA source-name reference.  No fuzzy matching, ever.
- Any ambiguity — one evidence channel naming two keys, or two channels
  naming different keys — fails closed: the ingredient is unmapped.
- An unmapped ingredient never enters the shipped file: every pair touching
  it is dropped and counted in the file's ``audit`` section.  ``--strict``
  turns any unmapped ingredient into a non-zero exit instead.
- Composition per key comes from the vocabulary's curated classes plus
  #114's facts entries mapped to that key.  ``compositionKnown`` is false
  when neither covers the key, and an unknown composition ships empty
  classes: the app's recheck treats it as "ask the user", never "safe".
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

OUTPUT_SCHEMA_VERSION = "2.0.0"
CONVERTER_PATH = "scripts/substitutions/convert.py"
DEFAULT_TABLE = "data/substitutions/pairs.json"
DEFAULT_VOCABULARY = "data/ingredients/vocabulary.json"
DEFAULT_OUTPUT = "apps/ios/Resources/Substitutions/substitutions-v2.json"

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
    key: str
    how: str  # "name" | "fdc" | "usda_ref"


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def usda_ref_name(fdc_ref: str | None) -> str | None:
    """The USDA source name recorded in a vocabulary ``fdc_ref``.

    ``fdc_ref`` reads like ``"Butter, salted (SR Legacy)"`` and may carry a
    compiler note after the source-name suffix.  Everything from the suffix
    marker onward is stripped; the remainder is the exact source name.  A
    ref without a recognizable suffix (or one that failed closed in the
    compiler) yields None.
    """
    if not fdc_ref:
        return None
    for marker in (" (SR Legacy)", " (FNDDS", " (Foundation", " (Survey"):
        idx = fdc_ref.find(marker)
        if idx > 0:
            return fdc_ref[:idx]
    return None


class Vocabulary:
    """The canonical ingredient vocabulary (data/ingredients/vocabulary.json)."""

    def __init__(self, data: dict) -> None:
        self.entries: list[dict] = sorted(data["entries"], key=lambda e: e["key"])
        self.name_to_keys: dict[str, set[str]] = {}
        self.fdc_to_keys: dict[int, set[str]] = {}
        self.usdaref_to_keys: dict[str, set[str]] = {}
        for entry in self.entries:
            key = entry["key"]
            for name in (key, entry.get("display_name"), *(entry.get("aliases") or [])):
                if name:
                    self.name_to_keys.setdefault(normalize(name), set()).add(key)
            fdc = entry.get("fdc_id")
            if isinstance(fdc, int):
                self.fdc_to_keys.setdefault(fdc, set()).add(key)
            ref_name = usda_ref_name(entry.get("fdc_ref"))
            if ref_name:
                self.usdaref_to_keys.setdefault(normalize(ref_name), set()).add(key)


def _unique_channel(hits: set[str]) -> str | None:
    """One evidence channel's outcome: a key, None (no hit), or ambiguity."""
    if len(hits) > 1:
        raise ConvertError("ambiguous")
    return next(iter(hits)) if hits else None


def resolve_key(
    table_key: str,
    record: dict,
    vocab: Vocabulary,
) -> Resolution | None:
    """Map one table ingredient to a canonical key, or None when it fails closed.

    Evidence channels: exact names (key/display/aliases), fdc-id equality,
    and the recorded USDA source-name reference.  Every channel must be
    unambiguous, and the channels that resolve must agree; anything else
    fails closed.
    """
    candidates: list[str] = [table_key, table_key.replace("_", " ")]
    display = record.get("display")
    if display:
        candidates.append(display)
    candidates.extend(record.get("aliases") or [])

    name_hits: set[str] = set()
    for candidate in candidates:
        name_hits |= vocab.name_to_keys.get(normalize(candidate), set())
    fdc_hits: set[str] = set()
    fdc = record.get("fdc_id")
    if isinstance(fdc, int):
        fdc_hits = vocab.fdc_to_keys.get(fdc, set())
    ref_hits: set[str] = set()
    ref_name = usda_ref_name(record.get("usda_name"))
    if ref_name:
        ref_hits = vocab.usdaref_to_keys.get(normalize(ref_name), set())

    resolved: list[Resolution] = []
    for hits, how in ((name_hits, "name"), (fdc_hits, "fdc"), (ref_hits, "usda_ref")):
        try:
            outcome = _unique_channel(hits)
        except ConvertError:
            return None  # ambiguous channel: fail closed
        if outcome is not None:
            resolved.append(Resolution(outcome, how))

    if not resolved:
        return None
    if len({r.key for r in resolved}) > 1:
        return None  # channels disagree: fail closed
    return resolved[0]


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


def build_compositions(
    table: dict,
    vocab: Vocabulary,
    resolution: dict[str, Resolution | None],
) -> dict[str, dict]:
    """Per-key composition from the vocabulary's classes plus #114's facts.

    For every vocabulary key: the vocabulary covers the key when its curated
    classes are more than ``["unknown"]``; #114's facts cover it when at least
    one mapped registry entry carries a non-null ``facts_key``.  Either source
    alone makes the composition known; neither fails closed to unknown with
    empty classes.  Classes ship as the union of the covering sources, split
    into allergen classes (the table's allergen set) and diet extensions.
    """
    facts_by_key: dict[str, list[dict]] = {}
    for table_key, record in sorted(table["ingredients"].items()):
        resolved = resolution.get(table_key)
        if resolved is None:
            continue
        facts_by_key.setdefault(resolved.key, []).append(record)

    compositions: dict[str, dict] = {}
    for entry in vocab.entries:
        key = entry["key"]
        vocab_classes = [c for c in entry.get("classes") or [] if c != "unknown"]
        facts_entries = facts_by_key.get(key, [])
        covered_facts = [e for e in facts_entries if e.get("facts_key")]
        composition_known = bool(vocab_classes) or bool(covered_facts)

        classes: set[str] = set(vocab_classes)
        for record in covered_facts:
            classes.update(record.get("classes") or [])
        note = next(
            (r.get("allergen_note") for r in covered_facts if r.get("allergen_note")),
            None,
        )

        allergen = [c for c in table["allergen_classes"] if c in classes]
        diet = sorted(classes.difference(table["allergen_classes"]))
        compositions[key] = {
            "allergenClasses": allergen,
            "dietClasses": diet,
            "compositionKnown": composition_known,
            "allergenNote": note,
        }
    return compositions


def recheck_payload(compositions: dict[str, dict], substitute_key: str, primary_verdict: str) -> dict:
    composition = compositions[substitute_key]
    return {
        "verdict": primary_verdict,
        "allergenClasses": list(composition["allergenClasses"]),
        "dietClasses": list(composition["dietClasses"]),
        "allergenNote": composition["allergenNote"],
        "compositionKnown": composition["compositionKnown"],
    }


def convert(
    table: dict,
    vocab: Vocabulary,
    source_commit: str,
    table_branch: str,
) -> dict:
    referenced: set[str] = set()
    for pair in table["pairs"]:
        referenced.add(pair["original"])
        referenced.add(pair["substitute"])

    resolution: dict[str, Resolution | None] = {}
    for key in referenced:
        resolution[key] = resolve_key(key, table["ingredients"][key], vocab)

    compositions = build_compositions(table, vocab, resolution)

    swaps: list[dict] = []
    dropped = 0
    seen_offers: set[tuple[str, str, str]] = set()
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
        if original.key == substitute.key:
            # Distinct reviewed endpoints merged into one canonical key (e.g.
            # two canned-fish forms sharing an fdc row) — a self-swap is not a
            # substitution; drop it and count it.
            dropped += 1
            continue
        offer = (original.key, substitute.key, pair["role"])
        if offer in seen_offers:
            # Canonicalization merged two distinct reviewed endpoints (say
            # chicken and chicken_breast) into one key: identical endpoints
            # and primary role are one offer, not two. First pairId wins.
            dropped += 1
            continue
        seen_offers.add(offer)

        primary_verdict = next(
            (f["verdict"] for f in fits if f["role"] == pair["role"]),
            fits[0]["verdict"],
        )
        swaps.append(
            {
                "pairId": pair["id"],
                "originalKey": original.key,
                "substituteKey": substitute.key,
                "role": pair["role"],
                "fits": fits,
                "excludedRoles": excluded,
                "preparation": pair.get("preparation") or [],
                "difference": difference,
                "sourceIds": list(pair.get("source_ids") or []),
                "recheck": recheck_payload(compositions, substitute.key, primary_verdict),
            }
        )

    swaps.sort(key=lambda s: (s["originalKey"], s["substituteKey"], s["pairId"]))
    unmapped = sorted(k for k, r in resolution.items() if r is None)
    mapped = sorted((k for k, r in resolution.items() if r is not None))
    known_substitutes = sum(1 for s in swaps if s["recheck"]["compositionKnown"])

    return {
        "schemaVersion": OUTPUT_SCHEMA_VERSION,
        "source": {
            "table": DEFAULT_TABLE,
            "tableSchemaVersion": table["schema_version"],
            "tableCreated": table["created"],
            "tableBranch": table_branch,
            "sourceCommit": source_commit,
            "vocabulary": DEFAULT_VOCABULARY,
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
            "compositionKnownSubstitutes": known_substitutes,
        },
        "compositions": compositions,
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
        for endpoint in (swap["originalKey"], swap["substituteKey"]):
            if endpoint not in document["compositions"]:
                raise ConvertError(f"{swap['pairId']}: endpoint {endpoint} has no composition")
        recheck = swap["recheck"]
        if not recheck["compositionKnown"] and (recheck["allergenClasses"] or recheck["dietClasses"]):
            # Unknown composition must fail closed even when labels claim clean.
            raise ConvertError(
                f"{swap['pairId']}: composition unknown but classes non-empty"
            )
        for fit in swap["fits"]:
            if fit["role"] not in document["roles"]:
                raise ConvertError(f"{swap['pairId']}: unknown role {fit['role']}")

    for key, composition in document["compositions"].items():
        if not composition["compositionKnown"] and (
            composition["allergenClasses"] or composition["dietClasses"]
        ):
            raise ConvertError(f"composition {key}: unknown but classes non-empty")


def dump(document: dict) -> str:
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--table", required=True, type=Path, help="path to pairs.json")
    parser.add_argument("--vocabulary", required=True, type=Path, help="path to data/ingredients/vocabulary.json")
    parser.add_argument("--out", type=Path, default=Path(DEFAULT_OUTPUT))
    parser.add_argument("--source-commit", required=True, help="git commit pairs.json was taken from")
    parser.add_argument("--table-branch", default="overhaul/substitution-table")
    parser.add_argument("--strict", action="store_true", help="fail on any unmapped ingredient")
    args = parser.parse_args(argv)

    table = load_json(args.table)
    vocab = Vocabulary(load_json(args.vocabulary))
    if table.get("schema_version") != "1.1.0":
        raise ConvertError(f"expected pairs.json schema 1.1.0, got {table.get('schema_version')}")

    document = convert(table, vocab, args.source_commit, args.table_branch)

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
        f"{audit['mappedIngredients']}/{audit['referencedIngredients']} ingredients mapped to canonical keys, "
        f"{audit['compositionKnownSubstitutes']} swaps with known substitute composition, "
        f"{audit['pairsDropped']} pairs dropped fail-closed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
