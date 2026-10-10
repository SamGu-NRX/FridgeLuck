"""M3: independent verification, leak canary, and the final report.

Re-derives every hand witness from the bundled metadata and the source
forward model (never from the witnesses module's literals), runs an active
leak canary (a mutated key that appends the target MUST be flagged), exhibits
the surviving R4 ambiguities in full, measures scale-resolution sensitivity,
and answers the minimum-amount question. Emits report.md + results.json;
tests pin the numbers against the committed files.
"""

from __future__ import annotations

import json
from fractions import Fraction as F
from pathlib import Path

import bundled
import enumerate as en
import schema
import witnesses as W

TOOL_DIR = Path(__file__).resolve().parent
REPORT_MD = TOOL_DIR / "report.md"
RESULTS_JSON = TOOL_DIR / "results.json"

WITNESS_REGIMES = {
    "same_evidence_different_allocations": "R2_identity_and_declared",
    "unknown_recipe_identity": "R1_plate_only",
    "portion_reference_tradeoff": "R3_plus_reference",
    "resolved_by_portion_confirmation": "R4_plus_portion",
}

SENSITIVITY_RESOLUTIONS = (F(1), F(2), F(5), F(10), F(25))


def _bundled_required(recipe_id: int) -> tuple[int, F]:
    for r in bundled.load_bundled_recipes():
        if r["recipe_id"] == recipe_id:
            return r["declared_servings"], r["required_grams"]
    raise AssertionError(f"recipe {recipe_id} not in bundle")


def verify_witnesses_exhaustively(family: list[schema.World]) -> list[dict]:
    """Every witness number re-derived from the bundle + source formula; the
    pair re-confirmed inside the enumerated family's classes."""
    results = []
    for builder in W.ALL_WITNESS_BUILDERS:
        w = builder()
        name = w["name"]
        regime = WITNESS_REGIMES[name]
        a, b = w["worlds"]
        checks = {}

        for label, world in (("a", a), ("b", b)):
            declared, required = _bundled_required(world.recipe_id)
            scale = world.batch_grams / required
            checks[f"{label}_batch_matches_bundle"] = (
                declared == world.declared_servings
                and world.batch_grams == required * scale
                and scale in en.COOK_SCALES
            )
            expect = schema.serving_factor(
                world.consumed_servings, world.portion_multiplier, world.declared_servings
            ) * world.batch_grams
            checks[f"{label}_rendered_matches_formula"] = (
                schema.rendered_plate_grams(world) == expect
            )

        # family-class membership: ambiguity witnesses must collide under the
        # regime's observation key; the resolution witness's two worlds must
        # be SEPARATED by it, with only the confirmed target surviving
        groups = en.group_by_key(family, regime)
        key = schema.observation_key(w["evidence"])
        members = groups[key]
        if name == "resolved_by_portion_confirmation":
            checks["resolved_target_survives_alone"] = (
                a in members and b not in members and en.class_targets(members) == (2,)
            )
        else:
            checks["same_class_in_family"] = a in members and b in members
        checks["distinct_targets"] = a.consumed_servings != b.consumed_servings

        result = schema.classify((a, b), w["evidence"])
        checks["classify_targets_match_hand"] = result.targets == tuple(sorted(w["targets"]))

        results.append(
            {
                "witness": name,
                "regime": regime,
                "targets": list(w["targets"]),
                "arithmetic": list(w["arithmetic"]),
                "checks": checks,
                "all_pass": all(checks.values()),
            }
        )
    if not all(r["all_pass"] for r in results):
        raise AssertionError(f"witness re-derivation failed: {results}")
    return results


def run_leak_canary(family: list[schema.World]) -> dict:
    """The honest key must stay clean; a key that appends the target MUST be
    flagged by find_outcome_leak."""
    kwargs = en.REGIMES["R4_plus_portion"]

    def honest(w):
        return schema.observation_key(schema.evidence_from_world(w, **kwargs))

    def mutated(w):
        return honest(w) + (w.consumed_servings,)

    honest_clean = schema.find_outcome_leak(family, honest, honest) is None
    leak = schema.find_outcome_leak(family, mutated, honest)
    flagged = leak is not None
    return {
        "honest_key_clean": honest_clean,
        "mutated_key_flagged": flagged,
        "leak_witness": (
            {
                "targets": leak["targets"],
                "candidate_keys_distinct": len(set(leak["candidate_keys"])) > 1,
            }
            if leak
            else None
        ),
        "canary_ok": honest_clean and flagged,
    }


def exhibit_r4_ambiguities(family: list[schema.World]) -> list[dict]:
    """All surviving R4 ambiguity classes, every member in full."""
    groups = en.group_by_key(family, "R4_plus_portion")
    exhibits = []
    for key, members in groups.items():
        targets = en.class_targets(members)
        if len(targets) <= 1:
            continue
        exhibits.append(
            {
                "observation": en.key_to_jsonable(key),
                "targets": list(targets),
                "worlds": [
                    {
                        "recipe": f"#{w.recipe_id} {w.title}",
                        "declared_servings": w.declared_servings,
                        "cook_scale": str(w.batch_grams / _bundled_required(w.recipe_id)[1]),
                        "batch_g": str(w.batch_grams),
                        "consumed": w.consumed_servings,
                        "portion": str(w.portion_multiplier),
                        "rendered_g": str(schema.rendered_plate_grams(w)),
                        "observed_g": str(schema.observed_plate_grams(w)),
                    }
                    for w in members
                ],
            }
        )
    exhibits.sort(key=lambda e: e["observation"])
    return exhibits


def resolution_sensitivity(family: list[schema.World]) -> list[dict]:
    """R4 ambiguity as the scale readout coarsens/finens.

    Worlds whose readout rounds to zero at a given resolution have no valid
    plate observation there (make_evidence refuses a non-positive plate) and
    are counted as unmeasurable instead of grouped.
    """
    rows = []
    for res in SENSITIVITY_RESOLUTIONS:
        kwargs = dict(en.REGIMES["R4_plus_portion"])
        kwargs["scale_resolution_g"] = res
        groups: dict[tuple, list[schema.World]] = {}
        unmeasurable = 0
        for w in family:
            if schema.observed_plate_grams(w, res) <= 0:
                unmeasurable += 1
                continue
            ev = schema.evidence_from_world(w, **kwargs)
            groups.setdefault(schema.observation_key(ev), []).append(w)
        ambiguous = {k: v for k, v in groups.items() if len(en.class_targets(v)) > 1}
        rows.append(
            {
                "resolution_g": str(res),
                "keys": len(groups),
                "ambiguous_keys": len(ambiguous),
                "ambiguous_worlds": sum(len(v) for v in ambiguous.values()),
                "unmeasurable_worlds": unmeasurable,
            }
        )
    return rows


def one_g_clause(sensitivity: list[dict]) -> str:
    """Data-driven 1 g sentence — never hardcode the outcome here."""
    exact = [r for r in sensitivity if r["resolution_g"] == "1"][0]
    if exact["ambiguous_keys"] == 0:
        return "; at 1 g resolution the measurable family is fully identifiable"
    return (
        f"; at 1 g resolution {exact['ambiguous_keys']} keys "
        f"({exact['ambiguous_worlds']} worlds) remain ambiguous"
    )


def minimum_amount(regimes: dict, sensitivity: list[dict]) -> dict:
    """The smallest evidence set that renders servings identifiable."""
    by_res = {r["resolution_g"]: r for r in sensitivity}
    return {
        "per_regime_identifiable_share": {
            name: [
                stats["identifiable_keys"],
                stats["keys"],
                stats["ambiguous_worlds"],
            ]
            for name, stats in regimes.items()
        },
        "decisive_observation": (
            "portion_multiplier: R3 -> R4 collapses ambiguous keys by ~3 orders "
            "of magnitude and cuts ambiguous worlds to the readout floor"
        ),
        "residual_at_5g": {
            "ambiguous_keys": by_res["5"]["ambiguous_keys"],
            "ambiguous_worlds": by_res["5"]["ambiguous_worlds"],
            "unmeasurable_worlds": by_res["5"]["unmeasurable_worlds"],
            "cause": "5 g readout rounds plates a few grams apart onto one step",
        },
        "identifiable_at_1g": {
            "ambiguous_keys": by_res["1"]["ambiguous_keys"],
            "ambiguous_worlds": by_res["1"]["ambiguous_worlds"],
            "unmeasurable_worlds": by_res["1"]["unmeasurable_worlds"],
            "note": one_g_clause(sensitivity).lstrip("; "),
        },
        "one_g_clause": one_g_clause(sensitivity),
    }


def build() -> dict:
    family = en.build_family()
    regimes = {name: en.summarize_regime(family, name) for name in en.REGIMES}
    witness_verification = verify_witnesses_exhaustively(family)
    canary = run_leak_canary(family)
    if not canary["canary_ok"]:
        raise AssertionError(f"leak canary failed: {canary}")
    r4_exhibits = exhibit_r4_ambiguities(family)
    sensitivity = resolution_sensitivity(family)
    minimum = minimum_amount(regimes, sensitivity)
    return {
        "study": "serving-identifiability",
        "milestone": "M3 verification + report",
        "family_worlds": len(family),
        "regimes": regimes,
        "witness_verification": witness_verification,
        "leak_canary": canary,
        "r4_surviving_ambiguities": r4_exhibits,
        "resolution_sensitivity_r4": sensitivity,
        "minimum_amount": minimum,
    }


_MD_TEMPLATE = """# Serving identifiability study - report

Question: on `feat/meal-photo-confirmation-v1`, the meal log records
**servingsConsumed** (`MealFinalizationViewModel.servings`), and the inventory
model scales each required ingredient by
`consumed * portion / max(declared, 1)` (`InventoryRepository.servingFactor`).
If a photo of the plate is all an observer effectively holds, which
consumed-servings values could have produced it? Exact `Fraction` arithmetic
throughout; family of {worlds} worlds (166 bundled recipes x cook scales
{{1/2, 1, 3/2, 2}} x consumed {{1..4}} x portions {{1/2, 1, 3/2, 2}}),
kitchen-scale readout at 5 g steps, ties up.

## Evidence regimes

| regime | evidence | keys | identifiable | ambiguous keys | ambiguous worlds |
|---|---|---|---|---|---|
{regime_rows}

The ambiguous-key count is not monotone in evidence (refinement splits one
ambiguous parent into children that can each remain ambiguous); the sound
invariants - identifiable keys never decrease, ambiguous-world count never
grows - hold by construction and are test-enforced.

## Hand witnesses, verified exhaustively

{witness_rows}

Each witness was re-derived here from the bundled metadata and the source
formula (`servingFactor`), then re-confirmed as one class of the enumerated
family under its regime: identical available evidence, different serving
allocations.

## The surviving R4 ambiguities (dish + declared + reference + portion confirmed)

Even with the recipe known, the per-serving reference weight of this cook
measured, and the portion multiplier confirmed, {r4_ambiguous} observation
keys remain ambiguous:

{r4_exhibits}

Cause: the 5 g readout rounds rendered plates that are a few grams apart onto
the same step. Finer readouts dissolve them:

| scale resolution | R4 ambiguous keys | R4 ambiguous worlds | unmeasurable (reads 0 g) |
|---|---|---|---|
{sensitivity_rows}

At coarse readouts some legitimately tiny plates round to zero grams - no
valid plate observation exists for those worlds at that resolution
(`make_evidence` refuses a non-positive plate), so they are counted
unmeasurable rather than grouped.

## Leak canary

The observation key is built from observation fields only. The active canary:
a mutated key builder that appends `consumed_servings` MUST be flagged by
`schema.find_outcome_leak` - honest key clean: {honest_clean}; mutated key
flagged: {mutated_flagged}. The detector is exercised on every `verify.py`
run, not just in unit tests.

## Minimum amount (answer)

The **confirmed portion multiplier** is the decisive observation: adding it
(R3 -> R4) collapses ambiguity by roughly three orders of magnitude at the key
level and cuts ambiguous worlds to the readout floor. With portion confirmed,
the only residual is the 5 g readout artifact (the exhibits above){one_g_clause}.
Recipe identity and declared
servings alone (R2) leave the cook-size x portion trade-off wide open - the
same plate is one serving of a double cook or two servings of a single cook -
which is exactly witness 1. A per-serving reference weight (R3) pins the
realized batch but not the (servings x portion) product - witness 3.

This answers the study's question for the declared finite family. It does not
claim the app's UI communicates any of this; it bounds what any plate-based
estimate could know.

## Threats to validity

- The family bounds cook scale to {{1/2..2}} and consumed to {{1..4}}; witnesses
  outside the grid may exist, none inside it were missed by construction of
  the partition (grouping is exact).
- The 5 g scale and the reference-weight availability are constructed
  observation-model choices, documented in `schema.py`; the sensitivity table
  prices them.
- `batch_grams` comes from the bundle's required-ingredient grams; the app
  scales required ingredients only (`MealBreakdownContent.make`), so optional
  swaps are out of scope by source definition.

## Handoff

- `results.json` carries every number in this report, machine-readable.
- Regenerate: `python3 tools/serving-identifiability/verify.py` (self-verifying:
  witness re-derivation and the canary abort the run on failure).
- Suite: `python3 -m pytest tools/serving-identifiability/tests -q`.
"""


def render_markdown(doc: dict) -> str:
    regimes = doc["regimes"]
    regime_rows = "\n".join(
        f"| {name} | {name.split('_', 1)[1].replace('_', ' + ')} | {s['keys']} | "
        f"{s['identifiable_keys']} | {s['ambiguous_keys']} | {s['ambiguous_worlds']} |"
        for name, s in regimes.items()
    )
    witness_rows = "\n".join(
        f"- **{r['witness']}** ({r['regime']}): targets {r['targets']} - "
        + "; ".join(r["arithmetic"])
        + f". Re-derived: {'PASS' if r['all_pass'] else 'FAIL'}."
        for r in doc["witness_verification"]
    )
    r4_exhibits = "\n".join(
        f"{i + 1}. observation (plate, identity, declared) = "
        f"({ex['observation'][0]} g, recipe {ex['observation'][1]}, declared {ex['observation'][2]}) - targets {ex['targets']}: "
        + "; ".join(
            f"#{w['recipe']} cook x{w['cook_scale']}, batch {w['batch_g']} g, t={w['consumed']}, "
            f"portion {w['portion']}, renders {w['rendered_g']} g, reads {w['observed_g']} g"
            for w in ex["worlds"]
        )
        for i, ex in enumerate(doc["r4_surviving_ambiguities"])
    )
    sensitivity_rows = "\n".join(
        f"| {r['resolution_g']} g | {r['ambiguous_keys']} | {r['ambiguous_worlds']} | "
        f"{r['unmeasurable_worlds']} |"
        for r in doc["resolution_sensitivity_r4"]
    )
    canary = doc["leak_canary"]
    return _MD_TEMPLATE.format(
        worlds=doc["family_worlds"],
        regime_rows=regime_rows,
        witness_rows=witness_rows,
        r4_ambiguous=len(doc["r4_surviving_ambiguities"]),
        r4_exhibits=r4_exhibits,
        sensitivity_rows=sensitivity_rows,
        one_g_clause=doc["minimum_amount"]["one_g_clause"],
        honest_clean=canary["honest_key_clean"],
        mutated_flagged=canary["mutated_key_flagged"],
    )


def main() -> None:
    doc = build()
    RESULTS_JSON.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    REPORT_MD.write_text(render_markdown(doc), encoding="utf-8")
    print(f"wrote {RESULTS_JSON} and {REPORT_MD}")
    for name, stats in doc["regimes"].items():
        print(
            f"{name}: {stats['keys']} keys, {stats['identifiable_keys']} identifiable, "
            f"{stats['ambiguous_keys']} ambiguous, {stats['ambiguous_worlds']} ambiguous worlds"
        )
    print(f"R4 survivors: {len(doc['r4_surviving_ambiguities'])}")
    for r in doc["resolution_sensitivity_r4"]:
        print(f"resolution {r['resolution_g']} g: {r['ambiguous_keys']} ambiguous keys")
    print(f"canary: {doc['leak_canary']['canary_ok']}")


if __name__ == "__main__":
    main()
