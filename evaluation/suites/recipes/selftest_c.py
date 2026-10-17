#!/usr/bin/env python3
"""Part C red-at-base self-tests (PR #88 review: rs.py:288-321 / 532-552, suite.py:158-216).

Four observable checks, driven through the suite's stable entry points
(evaluate_corpus / metric_list / run) exactly the way the runner uses them.
The script exits 0 only when observed behavior matches the REVIEWED-AND-FIXED
contract:

  Q1  a household line citing a NONEXISTENT conversion_ref with positive
      grams present must NOT clear — it is a lint violation AND an
      unresolved line (base cleared it: the nonempty ref string plus grams
      was treated as its own evidence);
  Q2  a weighed line 'covered' by an existing-but-unrelated scale
      measurement must NOT clear — a measurement row must be linked to
      THIS line (base cleared every weighed line on any truthy
      recipe-level scale_measurements flag);
  Q3  a tree carrying only PR #107's originals is scored as PRODUCT DATA
      (rights evidence from its own manifest) — never as the bundled
      baseline (base fell through to the bundled catalog);
  QC  passing control: records whose lines carry their own conversion rows
      and a properly LINKED scale measurement PASS the quantity gates —
      the gates are satisfiable, not vacuously failing.

At the un-fixed base, Q1/Q2/Q3 print `BUG PRESENT` (the observed base
behavior) and the script exits 1; that output is the red-at-base evidence.
After the fix the same script exits 0. The suite's full planted battery is
`suite.py --self-test`; this script is the reviewer's minimal replay.

Real corpus files are never touched: plants run on in-memory records and
temp trees only.
"""

from __future__ import annotations

import copy
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import rs  # noqa: E402
import suite  # noqa: E402
import suite_contract  # noqa: E402


def _good_record(source_ref: str = "test:ok") -> dict:
    """A clean two-line record whose household lines carry their OWN
    conversion-evidence rows (the record-supplied evidence contract)."""
    return {
        "rs_version": "1", "id": "fix-ok", "title": "OK recipe",
        "cuisine": "asian", "meal_slots": ["dinner"], "minutes": 20,
        "servings": 2,
        "ingredients": [
            {"name": "tofu", "qty": {"kind": "household", "value": 1, "unit": "block",
                                     "grams": 350, "conversion_ref": "tofu_block"}},
            {"name": "rice vinegar", "qty": {"kind": "household", "value": 1, "unit": "tbsp",
                                             "grams": 15, "conversion_ref": "rice_vinegar_tbsp"}},
        ],
        "steps": [{"text": "Sear, then serve over rice."}],
        "claims": [],
        "source_ref": source_ref,
        "provenance": "test",
        "conversions": [
            {"ref": "tofu_block", "ingredient": "tofu", "grams_per_unit": 350},
            {"ref": "rice_vinegar_tbsp", "ingredient": "rice vinegar", "grams_per_unit": 15},
        ],
    }


def _manifest_for(source_ref: str = "test:ok") -> dict:
    return {"records": {source_ref: {
        "source_id": source_ref, "source_type": "original", "origin": "test",
        "license": "LicenseRef-FL-Original", "access_date": "2026-10-11",
        "license_evidence": "test fixture",
        "permissions": {"text": True, "images": False, "modification": True,
                        "attribution": True, "caching": True, "offline_use": True},
    }}}


def _derived_metrics(corpus: list[dict], manifest: dict) -> tuple[dict[str, str], dict]:
    """Rights-gate, lint and cover one planted corpus; derive all statuses."""
    allergens = json.loads((Path(__file__).resolve().parent / "allergens.json").read_text())
    book, _desc = rs.CanonRulebook.load(None)
    ev = suite.evaluate_corpus(copy.deepcopy(corpus), copy.deepcopy(manifest),
                               {}, allergens, canon=book,
                               scored_desc="selftest_c planted corpus")
    with tempfile.TemporaryDirectory(prefix="selftest-c-") as td:
        metrics = suite.metric_list(copy.deepcopy(ev), Path(td))
    return {m["id"]: suite_contract.derive_status(m) for m in metrics}, ev


def case_q1() -> bool:
    """(i) household line: nonexistent conversion_ref WITH grams present."""
    r = _good_record()
    r["ingredients"][0]["qty"] = {"kind": "household", "value": 1, "unit": "block",
                                  "grams": 350, "conversion_ref": "nonexistent_ref"}
    st, ev = _derived_metrics([r], _manifest_for())
    lint_ok = st["food_safety_linter_pass"] == "fail"
    unresolved_ok = st["lines_with_quantity_evidence"] == "fail"
    return lint_ok and unresolved_ok


def case_q2() -> bool:
    """(ii) weighed line 'covered' by an existing-but-unrelated measurement."""
    r = _good_record()
    r["ingredients"][0]["qty"] = {"kind": "weighed", "grams": 350}
    # a REAL measurement row — of the OTHER line, not this one
    r["provenance"] = {"scale_measurements": [{"ingredient": "rice vinegar", "grams": 15}]}
    st, ev = _derived_metrics([r], _manifest_for())
    lint_ok = st["food_safety_linter_pass"] == "fail"
    unresolved_ok = st["lines_with_quantity_evidence"] == "fail"
    return lint_ok and unresolved_ok


def case_qc() -> bool:
    """(iv) passing control: record-carried rows + a properly linked scale
    measurement must PASS the quantity gates (gates are satisfiable)."""
    r = _good_record()
    r["ingredients"].append({"name": "butter",
                             "qty": {"kind": "weighed", "grams": 14}})
    r["provenance"] = {"scale_measurements": [{"ingredient": "butter", "grams": 14}]}
    st, ev = _derived_metrics([r], _manifest_for())
    return (st["food_safety_linter_pass"] == "pass"
            and st["lines_with_quantity_evidence"] == "pass")


def case_q3() -> bool:
    """(iii) an originals-only tree is scored as PRODUCT DATA, not baseline."""
    with tempfile.TemporaryDirectory(prefix="selftest-c-orig-") as td:
        root = Path(td) / "repo"
        (root / "data" / "recipes" / "originals").mkdir(parents=True)
        (root / "apps" / "ios" / "Resources").mkdir(parents=True)
        # the bundled catalog IS present — the exact review scenario
        (root / "apps" / "ios" / "Resources" / "data.json").write_text(json.dumps({
            "recipes": [["bundled-1", "Some Bundled Dish", 20, 2, [], [], "Cook it."]],
        }))
        rec = _good_record("test:orig-1")
        rec["id"] = "fl-original-9999"
        rec.pop("conversions")  # written separately below
        (root / "data" / "recipes" / "originals" / "originals.jsonl").write_text(
            json.dumps(rec) + "\n")
        (root / "data" / "recipes" / "originals" / "rights_manifest.json").write_text(
            json.dumps(_manifest_for("test:orig-1")) + "\n")
        with tempfile.TemporaryDirectory(prefix="selftest-c-out-") as od:
            results = suite.run(Path(od), root)
    m0 = results["metrics"][0]
    scored_product = ("originals.jsonl" in str(m0.get("detail", "")))
    return m0.get("value") == 1 and scored_product


def main() -> int:
    cases = [("Q1 household nonexistent ref + grams present stops clearing", case_q1),
             ("Q2 weighed line stops clearing on an unrelated measurement", case_q2),
             ("QC passing control (record rows + linked scale row) holds", case_qc),
             ("Q3 originals-only tree scored as product data", case_q3)]
    failures = 0
    for label, fn in cases:
        try:
            ok = fn()
        except Exception as exc:  # a crashing check is a failed check
            ok = False
            print(f"  {label}: ERROR {type(exc).__name__}: {exc}")
        if not ok:
            failures += 1
        print(f"  {label}: "
              + ("correct" if ok else "BUG PRESENT (observed base behavior)"))
    print(f"selftest_c: {len(cases) - failures}/{len(cases)} match the fixed contract"
          + (" (red at base — this is the captured evidence)" if failures else ""))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
