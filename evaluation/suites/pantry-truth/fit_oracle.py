"""Fit-truth oracle — suite A (pantry-truth).

Implements the SPEC 3.2 pantry-truth semantics (docs/spec/overhaul-20261011)
as a mechanical ledger over the grounded manifest, and the verdict rules the
200-pair audit and the double-count battery apply to production probe output.

SPEC 3.2 rules encoded here (quotes from SPEC.md, Pantry Truth section):
  - "It counts how much of each recipe line is actually covered by stock that
    still exists, across lines, swaps, or several dinners."
  - "9 of 10 · 1 swap" only when nine lines are sufficient; otherwise
    "7 recorded · check eggs and oil" — a count is only claimed for lines with
    quantity evidence behind it.
  - "Never a percentage, never a green check on an unknown amount."
  - "A scan observes — 'Still 2 lemons?' — it does not measure. Recognition
    confidence is not quantity confidence; unknown amounts stay unknown
    (or explicitly need reconfirming) until a receipt or a measure fixes them."
  - Optional garnish is separate from the required-line count.

Line states derived from evidence:
  sufficient        — non-stale, non-estimated lots cover the demand
  covered_by_swap   — an accepted swap's substitute stock covers the demand
  short             — some stock exists but not enough (shortfall recorded)
  quantity_unknown  — presence observed or recognition-estimated only
  needs_reconfirming — evidence exists but is stale past STALE_AFTER_DAYS
  assumed_staple    — a pantry assumption, no lot at all
  missing           — no evidence of any kind

The oracle is intentionally independent of the production code: it reads the
manifest (corpus + synthetic pantry), never the app's fit output, so a pair
verdict is a genuine cross-check of production behavior.
"""

from __future__ import annotations

import math

from manifest_builder import STALE_AFTER_DAYS

# States that count toward the fit-line sufficiency count.
COUNTING_STATES = {"sufficient", "covered_by_swap"}


class LedgerError(Exception):
    """The ledger is inconsistent with the corpus it claims to derive from."""


def build_ledger(manifest: dict, pair: dict) -> dict:
    """Derive the per-required-line truth ledger for one (pantry, recipe) pair."""
    recipe = manifest["recipes"][pair["recipe_id"]]
    lines = []
    for line in recipe["required"]:
        ing_id = line["ingredient_id"]
        demand = float(line["grams"])

        # Accepted swap: the line is covered by the substitute's stock.
        swap = pair.get("swap")
        if swap and swap["original_id"] == ing_id:
            sub_lots = [
                lot for lot in pair["pantry"]["lots"]
                if lot["ingredient_id"] == swap["substitute_id"]
                and lot["evidence_class"] == "purchased_lot"
            ]
            need = demand * swap["ratio"]
            available = sum(lot["remaining_grams"] for lot in sub_lots)
            state = "covered_by_swap" if available >= need else "missing"
            lines.append({
                "ingredient_id": ing_id,
                "demand_grams": demand,
                "state": state,
                "covered_grams": min(available, need) if state == "covered_by_swap" else available,
                "shortfall_grams": max(0.0, need - available) if state != "covered_by_swap" else 0.0,
                "via_swap": True,
                "swap_substitute_id": swap["substitute_id"],
            })
            continue

        lots = [lot for lot in pair["pantry"]["lots"] if lot["ingredient_id"] == ing_id]
        physical = [lot for lot in lots if lot["evidence_class"] in
                    ("purchased_lot", "purchased_lot_short", "estimated_quantity", "stale_lot", "observed_unknown")]
        stale_idx = {
            i for i, lot in enumerate(physical)
            if lot["evidence_class"] == "stale_lot" or lot.get("age_days", 0) >= STALE_AFTER_DAYS
        }
        stale = [lot for i, lot in enumerate(physical) if i in stale_idx]
        fresh = [lot for i, lot in enumerate(physical) if i not in stale_idx]

        if any(lot["evidence_class"] in ("observed_unknown", "estimated_quantity") for lot in physical):
            # Presence observed / recognition-estimated: never quantity evidence.
            state = "quantity_unknown"
            covered, shortfall = 0.0, demand
        elif fresh:
            available = sum(lot["remaining_grams"] for lot in fresh)
            if available >= demand:
                state = "sufficient"
                covered, shortfall = demand, 0.0
            else:
                state = "short"
                covered, shortfall = available, demand - available
        elif stale:
            state = "needs_reconfirming"
            covered, shortfall = 0.0, demand
        elif ing_id in pair["pantry"]["assumptions"]:
            state = "assumed_staple"
            covered, shortfall = 0.0, demand
        else:
            state = "missing"
            covered, shortfall = 0.0, demand

        lines.append({
            "ingredient_id": ing_id,
            "demand_grams": demand,
            "state": state,
            "covered_grams": covered,
            "shortfall_grams": shortfall,
            "via_swap": False,
        })

    # Optional garnish is separate (SPEC): recorded, never in the count.
    optional_ids = [l["ingredient_id"] for l in recipe["optional"]]
    return {
        "pair_id": pair["pair_id"],
        "recipe_id": pair["recipe_id"],
        "servings": recipe["servings"],
        "lines": lines,
        "optional_ids": optional_ids,
        "sufficient_count": sum(1 for l in lines if l["state"] in COUNTING_STATES),
        "total_required": len(lines),
    }


def verify_ledger_against_corpus(manifest: dict, ledger: dict) -> None:
    """Independently re-derive line demands from the raw corpus recipe rows.

    Raises LedgerError if the ledger's demands disagree with the corpus the
    manifest was built from — the self-test's planted-ledger-tamper tripwire.
    """
    raw = None
    for arr in manifest.get("_raw_corpus_recipes", []):
        if arr[0] == ledger["recipe_id"]:
            raw = arr
            break
    if raw is None:
        raise LedgerError(f"corpus row for recipe {ledger['recipe_id']} not found")
    corpus_lines = {int(i): float(g) for i, g in raw[4]}
    if len(corpus_lines) != ledger["total_required"]:
        raise LedgerError(
            f"pair {ledger['pair_id']}: ledger has {ledger['total_required']} required "
            f"lines, corpus has {len(corpus_lines)}"
        )
    for line in ledger["lines"]:
        expected = corpus_lines.get(line["ingredient_id"])
        if expected is None:
            raise LedgerError(
                f"pair {ledger['pair_id']}: ingredient {line['ingredient_id']} is not a "
                f"required line of recipe {ledger['recipe_id']} in the corpus"
            )
        if abs(expected - line["demand_grams"]) > 1e-6:
            raise LedgerError(
                f"pair {ledger['pair_id']}: demand for ingredient {line['ingredient_id']} "
                f"is {line['demand_grams']} g in the ledger but {expected} g in the corpus"
            )


def expected_fit_text(manifest: dict, ledger: dict) -> str:
    """The SPEC-shaped fit line the pair's truth implies (for the evidence file).

    "T of T[ · k swap]" when every required line is covered; otherwise
    "S recorded · check n1, n2" naming the non-covered lines. Wording aside,
    a production fit line is correct when it conveys this truth (see
    pair_verdict), not when it matches this string verbatim.
    """
    names = manifest["ingredients"]
    total = ledger["total_required"]
    suff = ledger["sufficient_count"]
    swaps = sum(1 for l in ledger["lines"] if l["state"] == "covered_by_swap")
    if suff == total:
        text = f"{total} of {total}"
        if swaps:
            text += f" · {swaps} swap" if swaps == 1 else f" · {swaps} swaps"
        return text
    check = ", ".join(
        names[l["ingredient_id"]]["name"] for l in ledger["lines"]
        if l["state"] not in COUNTING_STATES
    )
    return f"{suff} recorded · check {check}"


# ---------------------------------------------------------------------------
# Production-side reconstruction (from probe rows) and verdict rules.
# ---------------------------------------------------------------------------

def probe_row_invariants(row: dict) -> None:
    """Structural invariants every production probe row must satisfy.

    The probe reads production scoring (matched/missing are independent SQL
    counts over disjoint line sets), so matched + missing == total always
    holds in production. A tampered or lying probe row breaks it.

    Raises LedgerError on violation.
    """
    if not row.get("found"):
        return
    total = row["total_required"]
    matched = row["matched_required"]
    missing = row["missing_required_count"]
    if matched + missing != total:
        raise LedgerError(
            f"pair {row['pair_id']}: probe row violates matched({matched}) + "
            f"missing({missing}) == total({total})"
        )
    if matched < 0 or missing < 0:
        raise LedgerError(f"pair {row['pair_id']}: negative counts in probe row")
    if row.get("tier") not in ("exact", "nearMatch"):
        raise LedgerError(f"pair {row['pair_id']}: unknown tier {row.get('tier')!r}")


def production_fit_summary(row: dict) -> str:
    r"""The fit surface production renders for a rendered pair (per
    RecipeResultsSections.swift:195 '\(matched)/\(total) required' and the
    'Missing N' / 'Complete match' reasons from RecipeScoring.swift)."""
    if not row.get("found"):
        return "<no card rendered>"
    text = f"{row['matched_required']}/{row['total_required']} required"
    if row["missing_required_count"] == 0:
        text += " · Complete match"
    else:
        text += f" · Missing {row['missing_required_count']}"
    return text


def pair_verdict(manifest: dict, ledger: dict, row: dict) -> dict:
    """Decide whether production's fit line tells the pair's truth.

    A pair is CORRECT when production rendered the recipe and its fit surface:
      (1) claims exactly the ledger's sufficient count of the required lines
          (counting swap-covered lines as sufficient — SPEC: "across ... swaps"),
      (2) never claims a complete match while any line lacks quantity evidence
          (no green check on an unknown or short amount),
      (3) never renders a percentage (SPEC: "Never a percentage").
    A pair production renders nothing for is INCORRECT (the fit truth is owed
    on every card; the pantry screen still names what to check).
    """
    reasons = []
    if not row.get("found"):
        return {
            "pair_id": ledger["pair_id"],
            "correct": False,
            "reasons": ["production renders no fit line for this pair "
                        "(recipe absent from exact and near-match results)"],
            "ledger": ledger,
            "production": production_fit_summary(row),
            "expected": expected_fit_text(manifest, ledger),
        }
    suff = ledger["sufficient_count"]
    total = ledger["total_required"]
    if row["matched_required"] != suff or row["total_required"] != total:
        reasons.append(
            f"count mismatch: production claims {row['matched_required']} of "
            f"{row['total_required']} required; ledger says {suff} of {total} "
            f"sufficient with quantity evidence"
        )
    if row["missing_required_count"] == 0 and suff < total:
        reasons.append(
            "overclaim: production shows a complete match while "
            f"{total - suff} line(s) lack quantity evidence "
            f"({', '.join(l['state'] for l in ledger['lines'] if l['state'] not in COUNTING_STATES)})"
        )
    joined = " ".join(row.get("ranking_reasons", []))
    if "%" in joined:
        reasons.append("percentage on the fit surface (SPEC forbids)")
    return {
        "pair_id": ledger["pair_id"],
        "correct": not reasons,
        "reasons": reasons,
        "ledger": ledger,
        "production": production_fit_summary(row),
        "expected": expected_fit_text(manifest, ledger),
    }


def plan_double_count(manifest: dict, plan: dict, rows: dict) -> dict:
    """Evaluate one plan scenario for stock double-counting.

    rows: recipe_id -> probe row (production's verdict per dinner, each asked
    independently against the same pantry — the only composition production
    offers; RecommendationEngine.findRecipes composes per-call, with no
    cross-dinner ledger).
    A double-count finding: production calls both dinners makeable (zero
    missing lines each) while the ledger says the shared lot cannot cover
    both dinners' demand.
    """
    shared = plan["shared_lot"]
    ing_id = shared["ingredient_id"]
    demand_total = 0.0
    for rid in plan["recipes"]:
        recipe = manifest["recipes"][rid]
        for line in recipe["required"]:
            if line["ingredient_id"] == ing_id:
                demand_total += float(line["grams"])
    coverable = shared["remaining_grams"] >= demand_total

    both_makeable = all(
        rows.get(rid, {}).get("found") and rows[rid]["missing_required_count"] == 0
        for rid in plan["recipes"]
    )
    anomaly = None
    if not both_makeable and coverable:
        # By construction every non-shared line is fully covered, so a miss
        # means production did not surface the dinner. Verified cause: the
        # baseline ranks exact matches and surfaces 20 (findMakeable limit),
        # so fully-covered dinners can miss the ranked window.
        anomaly = (
            "production did not render one or both dinners although the ledger "
            "covers every line; the baseline ranks exact matches and surfaces 20, "
            "so fully-covered dinners can miss the ranked window "
            "(a coverage-visibility gap, not a double count)"
        )
    finding = both_makeable and not coverable
    return {
        "plan_id": plan["plan_id"],
        "kind": plan["kind"],
        "recipes": plan["recipes"],
        "shared_ingredient_id": ing_id,
        "shared_remaining_grams": shared["remaining_grams"],
        "combined_demand_grams": round(demand_total, 1),
        "coverable": coverable,
        "production_both_makeable": both_makeable,
        "double_count_finding": finding,
        "anomaly": anomaly,
    }


def wilson_interval(successes: int, n: int, z: float = 1.959963984540054) -> tuple[float, float]:
    """Wilson score interval at the given z (95% by default)."""
    if n == 0:
        return (0.0, 0.0)
    p = successes / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, center - half), min(1.0, center + half))
