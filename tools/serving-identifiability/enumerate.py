"""M2: exact equivalence classes over a finite recipe x cook x portion family.

Enumerates a declared finite family of serving worlds over the bundled
recipes and groups them by the leak-free observation key under four
evidence regimes. Counts are exact (Fraction arithmetic), deterministic,
and committed as enumeration.json; tests re-derive them and re-assert the
four hand witnesses as members of the right classes.

Family (all axes finite, chosen to cover the hand witnesses and the
realistic serving range; see report.md for the modeling rationale):
  recipe      : every bundled recipe (166, hash-bound via bundled.py)
  cook scale  : {1/2, 1, 3/2, 2}  (batch = declared required grams x scale)
  consumed    : {1, 2, 3, 4}      (target; source clamps to >= 1)
  portion     : {1/2, 1, 3/2, 2}  (confirmed multiplier)
  scale       : 5 g kitchen-scale readout resolution

Regimes (observation policies; the study's declared evidence levels):
  R1 plate only                    (no recipe identity, no declared servings)
  R2 + recipe identity + declared  (the confirmation flow's revealed facts)
  R3 + per-serving reference weight
  R4 + confirmed portion multiplier
"""

from __future__ import annotations

import json
from fractions import Fraction as F
from itertools import product
from pathlib import Path

import bundled
import schema
import witnesses as W

ENUM_JSON = Path(__file__).resolve().parent / "enumeration.json"

COOK_SCALES = (F(1, 2), F(1), F(3, 2), F(2))
CONSUMED = (1, 2, 3, 4)
PORTIONS = (F(1, 2), F(1), F(3, 2), F(2))

#: regime name -> evidence_from_world kwargs
REGIMES = {
    "R1_plate_only": {},
    "R2_identity_and_declared": {"reveal_identity": True, "reveal_declared": True},
    "R3_plus_reference": {
        "reveal_identity": True,
        "reveal_declared": True,
        "reveal_reference": True,
    },
    "R4_plus_portion": {
        "reveal_identity": True,
        "reveal_declared": True,
        "reveal_reference": True,
        "reveal_multiplier": True,
    },
}


def key_to_jsonable(key: tuple) -> list:
    """Observation keys hold Fractions; stringify them for JSON output."""
    return [str(x) if isinstance(x, F) else x for x in key]


def build_family() -> list[schema.World]:
    """The full finite family, deterministically ordered."""
    worlds = []
    for recipe in bundled.load_bundled_recipes():
        declared = recipe["declared_servings"]
        for scale, consumed, portion in product(COOK_SCALES, CONSUMED, PORTIONS):
            worlds.append(
                schema.make_world(
                    recipe_id=recipe["recipe_id"],
                    title=recipe["title"],
                    declared_servings=declared,
                    batch_grams=recipe["required_grams"] * scale,
                    consumed_servings=consumed,
                    portion_multiplier=portion,
                )
            )
    return worlds


def group_by_key(worlds: list[schema.World], regime: str) -> dict[tuple, list[schema.World]]:
    """Group worlds by the observation key under the regime's policy."""
    kwargs = REGIMES[regime]
    groups: dict[tuple, list[schema.World]] = {}
    for world in worlds:
        ev = schema.evidence_from_world(world, **kwargs)
        groups.setdefault(schema.observation_key(ev), []).append(world)
    return groups


def class_targets(members: list[schema.World]) -> tuple[int, ...]:
    return tuple(sorted({w.consumed_servings for w in members}))


def summarize_regime(worlds: list[schema.World], regime: str) -> dict:
    groups = group_by_key(worlds, regime)
    ambiguous = {k: v for k, v in groups.items() if len(class_targets(v)) > 1}
    sizes = sorted(len(v) for v in groups.values())
    spreads = [
        max(class_targets(v)) - min(class_targets(v)) for v in ambiguous.values()
    ]
    spreads.sort()
    examples = []
    for key in sorted(ambiguous, key=lambda k: (len(ambiguous[k]), repr(k)))[:5]:
        members = ambiguous[key]
        ev = schema.evidence_from_world(members[0], **REGIMES[regime])
        examples.append(
            {
                "observation": key_to_jsonable(key),
                "members": len(members),
                "targets": list(class_targets(members)),
                "sample_worlds": [
                    {
                        "recipe": f"#{w.recipe_id} {w.title}",
                        "batch_g": str(w.batch_grams),
                        "consumed": w.consumed_servings,
                        "portion": str(w.portion_multiplier),
                        "rendered_g": str(schema.rendered_plate_grams(w)),
                    }
                    for w in sorted(
                        members,
                        key=lambda w: (w.recipe_id, w.consumed_servings, w.portion_multiplier),
                    )[:6]
                ],
            }
        )
    return {
        "keys": len(groups),
        "identifiable_keys": sum(1 for v in groups.values() if len(class_targets(v)) == 1),
        "ambiguous_keys": len(ambiguous),
        "max_class_size": sizes[-1],
        "max_target_spread": spreads[-1] if spreads else 0,
        "ambiguous_examples": examples,
    }


def assert_witnesses_in_enumeration(worlds: list[schema.World]) -> list[dict]:
    """The four hand witnesses must appear as members of enumerated classes."""
    checks = []
    w1 = W.witness_same_evidence_different_allocations()
    w2 = W.witness_unknown_recipe_identity()
    w3 = W.witness_portion_reference_tradeoff()
    w4 = W.witness_resolved_by_portion_confirmation()

    # witness 1 lives in R2 (identity + declared revealed)
    r2 = group_by_key(worlds, "R2_identity_and_declared")
    targets1 = class_targets(r2[schema.observation_key(w1["evidence"])])
    checks.append(
        {
            "witness": "same_evidence_different_allocations",
            "regime": "R2_identity_and_declared",
            "targets_in_class": list(targets1),
            "hand_targets": list(w1["targets"]),
            "ok": set(w1["targets"]).issubset(targets1),
        }
    )

    # witness 2 lives in R1 (plate only)
    r1 = group_by_key(worlds, "R1_plate_only")
    targets2 = class_targets(r1[schema.observation_key(w2["evidence"])])
    checks.append(
        {
            "witness": "unknown_recipe_identity",
            "regime": "R1_plate_only",
            "targets_in_class": list(targets2),
            "hand_targets": list(w2["targets"]),
            "ok": set(w2["targets"]).issubset(targets2),
        }
    )

    # witness 3 lives in R3 (identity + declared + reference)
    r3 = group_by_key(worlds, "R3_plus_reference")
    targets3 = class_targets(r3[schema.observation_key(w3["evidence"])])
    checks.append(
        {
            "witness": "portion_reference_tradeoff",
            "regime": "R3_plus_reference",
            "targets_in_class": list(targets3),
            "hand_targets": list(w3["targets"]),
            "ok": set(w3["targets"]).issubset(targets3),
        }
    )

    # witness 4 lives in R4 and is identifiable
    r4 = group_by_key(worlds, "R4_plus_portion")
    targets4 = class_targets(r4[schema.observation_key(w4["evidence"])])
    checks.append(
        {
            "witness": "resolved_by_portion_confirmation",
            "regime": "R4_plus_portion",
            "targets_in_class": list(targets4),
            "hand_targets": list(w4["targets"]),
            "ok": targets4 == tuple(w4["targets"]),
        }
    )

    failing = [c for c in checks if not c["ok"]]
    if failing:
        raise AssertionError(f"witnesses missing from enumeration: {failing}")
    return checks


def build() -> dict:
    worlds = build_family()

    # structural leak discipline: the observation key is built from the
    # observation fields only; the target never appears (the active canary
    # that flags a mutated key lives in M3's verify.py)
    assert schema.TARGET_FIELD not in schema.OBSERVATION_FIELDS

    witness_checks = assert_witnesses_in_enumeration(worlds)
    recipes = bundled.load_bundled_recipes()
    return {
        "study": "serving-identifiability",
        "milestone": "M2 enumeration",
        "family": {
            "recipes": len(recipes),
            "cook_scales": [str(s) for s in COOK_SCALES],
            "consumed": list(CONSUMED),
            "portions": [str(p) for p in PORTIONS],
            "scale_resolution_g": str(schema.DEFAULT_RESOLUTION),
            "worlds": len(worlds),
        },
        "regimes": {name: summarize_regime(worlds, name) for name in REGIMES},
        "witness_membership": witness_checks,
    }


def main() -> None:
    doc = build()
    ENUM_JSON.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {ENUM_JSON}")
    fam = doc["family"]
    print(
        f"family: {fam['recipes']} recipes x {len(COOK_SCALES)} cook scales "
        f"x {len(CONSUMED)} consumed x {len(PORTIONS)} portions = {fam['worlds']} worlds"
    )
    for name, stats in doc["regimes"].items():
        print(
            f"{name}: {stats['keys']} evidence keys, {stats['identifiable_keys']} identifiable, "
            f"{stats['ambiguous_keys']} ambiguous (max class {stats['max_class_size']} worlds, "
            f"max spread {stats['max_target_spread']} servings)"
        )


if __name__ == "__main__":
    main()
