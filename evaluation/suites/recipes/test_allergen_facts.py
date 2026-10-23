#!/usr/bin/env python3
"""Planted-failure self-tests for the allergen/diet claim verdicts (PR #88 BLOCK).

The BLOCK at base 9e04af4: claims cleared through the fixture alias table
(``allergens.json``) while FLIngredientFacts was unavailable — a tamari-only
recipe with a gluten-free claim cleared because the alias table unconditionally
records only soy (allergens.json:172-173), and known-name composition was never
checked against the canonical facts source. CONTRACTS.md's availability rule
requires every dependent check to fail closed when the canonical source is
absent or incomplete.

These tests pin the corrected behavior:

  B1  PLANT  tamari + gluten-free claim, facts absent  -> HELD (red at base:
      the alias table cleared it; allergens.json:172-173)
  B2  PLANT  certified gluten-free tamari + gluten-free claim, REAL facts
      -> CLEARED through facts (red at base: no facts path existed)
  B3  GUARD  cream cheese + dairy-free claim -> HELD (never disappears from
      the scan; the lead's earlier review)
  B4  PLANT  facts source explicitly absent -> every claim HELD with a reason
      naming FLIngredientFacts (overhaul/ingredient-facts, PR #127)
  B5  PLANT  known compound ingredient with unknown facts (stock cube) and a
      resolvable identity with NO facts row (artisan granola bar) -> HELD
  B6  CONTROL tofu + dairy-free claim -> CLEARED through facts (real facts
      row: milk free with evidence); wrong recorded evidence -> HELD
  B7  GUARD  soy sauce + gluten-free claim -> HELD (real conflict, both sides)

Run protocol (planted-failure: each plant must be RED at base 9e04af4 and
GREEN on the fix branch):

    cd evaluation/suites/recipes
    python3 test_allergen_facts.py          # exit 0 = every case green/skipped

Cases that need the facts-injection API (added by the fix) are SKIPped at
base with the reason printed; the base run must still show B1/B2 FAILING.
Facts data is consumed read-only from the pinned snapshot
``canon/ingredient-facts/`` (branch overhaul/ingredient-facts @ b0deecce,
PR #127 — see canon/ingredient-facts/PROVENANCE.md). Standard library only.
"""

from __future__ import annotations

import copy
import inspect
import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bands  # noqa: E402
import rs  # noqa: E402

SUITE_DIR = Path(__file__).resolve().parent
BASE_SHA = "9e04af496ca99e9edca524a371a6730cb1c16db0"


def _recipe(rid: str, ingredient_names: list[str],
            claims: list[dict[str, Any]]) -> dict[str, Any]:
    """A minimal RS-valid recipe carrying exactly the named ingredients."""
    return {
        "rs_version": "1", "id": rid, "title": f"Allergen probe {rid}",
        "cuisine": "asian", "meal_slots": ["dinner"], "minutes": 15,
        "servings": 2,
        "ingredients": [
            {"name": name, "qty": {"kind": "source_grams", "grams": 100}}
            for name in ingredient_names
        ],
        "steps": [{"text": "Combine and serve."}],
        "claims": copy.deepcopy(claims),
        "source_ref": "test:allergen-facts", "provenance": "test",
    }


def _lint(recipes: list[dict[str, Any]], scanner: "rs.AllergenScanner",
          ) -> dict[str, Any]:
    """Lint through the real pipeline (same entry point the suite uses)."""
    return rs.lint_corpus(
        recipes, cuisines=bands.CUISINE_SET, meal_slots=bands.SLOT_SET,
        # renamed with the record-carried evidence contract: {} is the same
        # empty conversion-evidence set these tests always passed (their
        # allergen/diet assertions are untouched by quantity resolution)
        conversion_rows={}, allergen_scan=scanner, canon=None,
    )


def _default_scanner(table: dict[str, Any]) -> "rs.AllergenScanner":
    """Scanner as the suite constructs it (self-loads the pinned facts)."""
    return rs.AllergenScanner(table)


def _injected_scanner(table: dict[str, Any], facts: Any, reason: str,
                      ) -> "rs.AllergenScanner":
    """Scanner with an injected facts state (fix API; absent at base)."""
    return rs.AllergenScanner(table, facts=facts, facts_reason=reason)


_ABSENT_REASON = ("tried: scored tree data/ingredient-facts (not present); "
                  "pinned snapshot canon/ingredient-facts (not present)")


def main() -> int:
    table = json.loads((SUITE_DIR / "allergens.json").read_text())
    has_injection = "facts" in inspect.signature(
        rs.AllergenScanner.__init__).parameters
    facts, facts_desc = (None, "")
    if has_injection:
        facts, facts_desc = rs.FLIngredientFacts.load()

    results: list[tuple[str, bool, str]] = []

    def case(name: str, ok: bool, detail: str, skipped: str | None = None) -> None:
        results.append((name, bool(ok), detail, skipped))

    gf_claim = [{"claim": "gluten-free", "evidence": {"conflicts": []}}]
    df_claim = [{"claim": "dairy-free", "evidence": {"conflicts": []}}]
    vegan_claim = [{"claim": "vegan", "evidence": {"conflicts": []}}]

    # B1 PLANT: tamari-only recipe with a gluten-free claim. The alias table
    # records only soy (allergens.json:172-173), so at base the claim cleared
    # with no composition evidence. Facts (absent OR present) must HOLD it.
    scanner = _default_scanner(table)
    report = _lint([_recipe("b1-tamari", ["tamari"], gf_claim)], scanner)
    held = report["unchecked_claims"] == 1
    reason = json.dumps(report["stripped_detail"])
    case("B1 tamari gluten-free claim held without facts composition",
         held, f"unchecked={report['unchecked_claims']} detail={reason[:220]}")

    # B2 PLANT/CONTROL: the certified gluten-free tamari FORM carries real
    # label evidence in the facts dataset — this claim may clear, and only
    # through facts. At base no facts path existed (red either way).
    scanner = _default_scanner(table)
    report = _lint([_recipe("b2-tamari-gf", ["gluten-free tamari"], gf_claim)],
                   scanner)
    cleared = (report["unchecked_claims"] == 0
               and report["stripped_claims"] == 0)
    case("B2 certified gluten-free tamari clears through facts",
         cleared, f"unchecked={report['unchecked_claims']} "
                  f"stripped={report['stripped_claims']} detail="
                  f"{json.dumps(report['stripped_detail'])[:220]}")

    # B3 GUARD (the lead's earlier review): an ingredient name with no alias
    # must not disappear from the allergen scan. Cream cheese + dairy-free is
    # HELD at base (alias-unknown) and on the branch (facts: milk contains).
    scanner = _default_scanner(table)
    report = _lint([_recipe("b3-cream-cheese", ["cream cheese"], df_claim)],
                   scanner)
    detail = json.dumps(report["stripped_detail"])
    case("B3 cream-cheese dairy-free claim stays held (scan surface)",
         report["unchecked_claims"] == 1 and "cream cheese" in detail,
         f"unchecked={report['unchecked_claims']} detail={detail[:220]}")

    # B4 PLANT (fix API): facts source explicitly absent -> every claim held,
    # reason naming the canonical source.
    if has_injection:
        scanner = _injected_scanner(table, None, _ABSENT_REASON)
        verdict = scanner.verify_claim(
            _recipe("b4-absent", ["tofu"], df_claim), df_claim[0])
        ok = (verdict is not True and "FLIngredientFacts" in str(verdict)
              and "overhaul/ingredient-facts" in str(verdict))
        case("B4 absent facts source holds claims, reason names the source",
             ok, f"verdict={str(verdict)[:220]}")
    else:
        case("B4 absent facts source holds claims, reason names the source",
             False, "skipped at base: facts-injection API not present "
                    "(this is the fix under test)", skipped=_ABSENT_REASON)

    # B5 PLANT (fix API): known compound composition with unknown facts, and a
    # resolvable identity with NO facts row — both must hold, never clear.
    if has_injection and facts is not None:
        scanner = _default_scanner(table)
        report = _lint([
            _recipe("b5-stock-cube", ["stock cube"], df_claim),
            _recipe("b5-granola", ["artisan granola bar"], vegan_claim),
        ], scanner)
        detail = json.dumps(report["stripped_detail"])
        ok = (report["unchecked_claims"] == 2 and "stock cube" in detail
              and "artisan granola bar" in detail)
        case("B5 compound-unknown facts and facts-row-less identity hold claims",
             ok, f"unchecked={report['unchecked_claims']} detail={detail[:260]}")
    else:
        case("B5 compound-unknown facts and facts-row-less identity hold claims",
             False, "skipped at base: pinned FLIngredientFacts not loadable "
                    "without the fix", skipped="facts API/dataset absent")

    # B6 CONTROL (fix API): real facts row with milk free + evidence clears a
    # dairy-free claim; misrecorded evidence conflicts are held.
    if has_injection and facts is not None:
        scanner = _default_scanner(table)
        tofu = _recipe("b6-tofu", ["tofu"], df_claim)
        verdict = scanner.verify_claim(tofu, df_claim[0])
        wrong = _recipe("b6-wrong", ["tofu"],
                        [{"claim": "dairy-free",
                          "evidence": {"conflicts": ["allergen:milk"]}}])
        verdict_wrong = scanner.verify_claim(wrong, wrong["claims"][0])
        ok = verdict is True and verdict_wrong is not True
        case("B6 facts-backed claim clears; disagreeing evidence held",
             ok, f"clear verdict={verdict} wrong-evidence verdict="
                 f"{str(verdict_wrong)[:180]}")
    else:
        case("B6 facts-backed claim clears; disagreeing evidence held",
             False, "skipped at base: pinned FLIngredientFacts not loadable "
                    "without the fix", skipped="facts API/dataset absent")

    # B7 GUARD: a real conflict (soy sauce carries gluten) holds the claim on
    # both sides — the rewire must never soften a true conflict.
    scanner = _default_scanner(table)
    report = _lint([_recipe("b7-soy-sauce", ["soy sauce"], gf_claim)], scanner)
    detail = json.dumps(report["stripped_detail"])
    case("B7 soy-sauce gluten conflict holds the claim",
         report["unchecked_claims"] == 1, f"detail={detail[:220]}")

    passed = sum(1 for _, ok, _, _ in results if ok)
    failed = sum(1 for _, ok, _, skip in results if not ok and skip is None)
    skipped = sum(1 for _, ok, _, skip in results if not ok and skip is not None)
    for name, ok, detail, skip in results:
        state = "PASS" if ok else ("SKIP" if skip is not None else "FAIL")
        print(f"  {state}  {name}: {detail}")
    print(f"allergen-facts verdict self-tests: {passed} passed, {failed} failed, "
          f"{skipped} skipped (base {BASE_SHA[:7]} must show B1/B2 FAILING; "
          f"the fix branch must show every case PASS with no skips)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
