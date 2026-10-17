#!/usr/bin/env python3
"""Build the review-fixed packet for the 189 agent-fixed catalog recipes.

Packet burst14-fridgeluck-review-fixed (base alpha af856008).

The three earlier amounts packets (amounts-a, amounts-b, rubric) fixed 189
recipes; review.py + findings.json in evaluation/recipe-quality/review-fixed/
audited all of them with the real compiler and rubric audit plus a full hand
read. This file emits data/recipes/fixes/review-fixed.json: the 14 fixes from
that review with one correct answer, each pinned to the base corpus line's
sha256. Fixes flagged changes_rights_pin add ingredient lines (garlic, rice,
butter, bread) that a step already names; fl_revisions derives their pinned
revisions at apply time.

Run:  python3 -I evaluation/recipe-quality/review_fixed.py   (writes the packet)
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "data/recipes/tools"))
sys.path.insert(0, str(HERE))

import compile_bundle as compiler  # noqa: E402
import validate_corpus as vcorpus  # noqa: E402

PACKET = "burst14-fridgeluck-review-fixed"


def base_commit() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                          capture_output=True, text=True, check=True).stdout.strip()


def load_corpus() -> tuple[dict[str, dict], dict[str, bytes]]:
    raws: dict[str, bytes] = {}
    objs: dict[str, dict] = {}
    path = REPO / "data/recipes/corpus.jsonl"
    for line in path.read_bytes().split(b"\n"):
        if not line.strip():
            continue
        obj = json.loads(line)
        fid = obj["id"]
        raws[fid] = line
        objs[fid] = obj
    return objs, raws


def compile_ctx() -> tuple[dict, dict, dict, dict]:
    """(mappings, vocab_by_key, rights_records, rights_ctx) like amounts_b."""
    mappings = json.loads((REPO / "data/ingredients/name-mappings.json")
                          .read_text(encoding="utf-8"))["mappings"]
    vocab = json.loads((REPO / "data/ingredients/vocabulary.json")
                       .read_text(encoding="utf-8"))["entries"]
    vocab_by_key = {e["key"]: e for e in vocab}
    rights = json.loads((REPO / "data/recipes/rights_manifest.json")
                        .read_text(encoding="utf-8"))["records"]
    rights_ctx = vcorpus.load_rights_context()
    return mappings, vocab_by_key, rights, rights_ctx


def conv_table() -> dict[str, float]:
    conv_rows: dict[str, float] = {}
    table = json.loads((REPO / "data/recipes/suite/conversions.json")
                       .read_text(encoding="utf-8"))
    for ref, row in table.get("conversions", table).items():
        conv_rows[ref] = (row.get("grams") or row.get("grams_per_unit")
                          if isinstance(row, dict) else row)
    corpus_tbl = REPO / "data/recipes/conversions.json"
    if corpus_tbl.exists():
        for ref, row in json.loads(corpus_tbl.read_text(encoding="utf-8")) \
                .get("conversions", {}).items():
            conv_rows.setdefault(ref, (row.get("grams") or row.get("grams_per_unit")
                                       if isinstance(row, dict) else row))
    for rec in load_corpus()[0].values():
        for ref, row in (rec.get("conversions") or {}).items():
            conv_rows.setdefault(str(ref).strip(),
                                 (row.get("grams") or row.get("grams_per_unit")
                                  if isinstance(row, dict) else row))
    return conv_rows


# --- the fixes --------------------------------------------------------------
# Each entry: catalog_id -> (changes, ops). Ops mutate a deep copy of the
# corpus record. Line ops match by substring of the ingredient name.
FIX_SPECS: dict[str, tuple[list[dict], list[dict]]] = {
    "rcp-000247": (
        [{"path": "ingredients[almonds].qty",
          "reason": "The line measured 3 tbsp of almonds through the almonds_cup row "
                    "(145 g per cup), shipping 435 g of nuts over two yogurt bowls and "
                    "1,564 kcal a serving. Three tablespoons of toasted almonds is 27 g.",
          "evidence": "developer sizing: 3 tbsp almonds ~ 27 g; kcal 1,564 -> ~444"}],
        [{"op": "set_qty_grams", "name": "almonds", "grams": 27.0,
          "note": "about 3 tablespoons"}]),
    "rcp-000391": (
        [{"path": "servings",
          "reason": "600 g of chuck with the vegetables is a three-plate braise; at two "
                    "servings each plate carries 300 g raw beef, above the 110-225 g "
                    "main-course band. Servings 3 puts it at 200 g.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000397": (
        [{"path": "servings",
          "reason": "500 g of chuck and 168 g of rigatoni feed three at 167 g meat and "
                    "56 g pasta each; at two the meat alone is 250 g a plate.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000401": (
        [{"path": "servings",
          "reason": "500 g of lamb with 200 g of orzo serves three at 167 g meat each; "
                    "at two each plate holds 250 g raw lamb.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000405": (
        [{"path": "servings",
          "reason": "600 g of pork shoulder is 200 g a person at three servings; at two "
                    "it is a 300 g pile of carnitas per plate.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000406": (
        [{"path": "servings",
          "reason": "600 g of pork and 240 g of beans serve three at 200 g meat each; "
                    "at two each bowl carries 300 g raw pork.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000413": (
        [{"path": "servings",
          "reason": "600 g of chuck with 360 ml of coconut milk is a three-plate rendang "
                    "(200 g meat, 120 ml sauce each); at two it is 300 g a plate.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000442": (
        [{"path": "ingredients[pork shoulder].qty",
          "reason": "700 g of pork shoulder against two buns and 210 g of slaw is a "
                    "six-sandwich quantity of meat on a two-sandwich plate; 400 g is "
                    "200 g raw pork a person for the buns the recipe actually shapes.",
          "evidence": "developer sizing: 200 g raw shoulder per pulled-pork sandwich "
                      "serving; buns and slaw already sized for 2"}],
        [{"op": "set_qty_grams", "name": "pork shoulder", "grams": 400.0,
          "note": "about 1 lb"}]),
    "rcp-000443": (
        [{"path": "servings",
          "reason": "500 g of chuck in 360 ml of wine serves three at 167 g each; at "
                    "two each plate is 250 g raw beef.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000444": (
        [{"path": "servings",
          "reason": "600 g of pork and 410 g of hominy serve three at 200 g and 137 g "
                    "each; at two each bowl holds 300 g raw pork.",
          "evidence": "raw-protein band 110-225 g/serving for a main"}],
        [{"op": "servings", "value": 3}]),
    "rcp-000450": (
        [{"path": "servings",
          "reason": "500 g of chuck and six tortillas serve three at 167 g meat and two "
                    "tortillas each; at two each plate is 250 g raw beef.",
          "evidence": "raw-protein band 110-225 g/serving for a main"},
         {"path": "ingredients[garlic]",
          "reason": "Step 0 blends garlic into the sauce but no line held it, so the "
                    "shopping list missed it; three cloves is a standard birria blend.",
          "evidence": "rcp-000450 audit: 'garlic' named in step 0, no line (C1)"}],
        [{"op": "servings", "value": 3},
         {"op": "add_line", "name": "garlic",
          "qty": {"kind": "household", "value": 3, "unit": "cloves",
                  "conversion_ref": "garlic_clove", "grams": 9.0}}]),
    "rcp-000463": (
        [{"path": "ingredients[butter]",
          "reason": "Step 0 softens the onion and chili in butter but no line held it; a "
                    "tablespoon is what the pan needs.",
          "evidence": "rcp-000463 audit: 'butter' used in step 0, no line (C1)"},
         {"path": "ingredients[bread]",
          "reason": "Step 3 serves the bhurji on buttered toast but no bread line "
                    "existed; without the additions a serving sits at ~142 kcal, "
                    "under the energy floor. Two slices is 60 g at the canon's "
                    "30 g per slice.",
          "evidence": "rcp-000463 audit: toast in step 3, no line (C1); "
                      "bread_slice row 30 g/slice"}],
        [{"op": "add_line", "name": "butter",
          "qty": {"kind": "household", "value": 1, "unit": "tbsp",
                  "conversion_ref": "butter_tbsp", "grams": 14.0}},
         {"op": "add_line", "name": "bread",
          "qty": {"kind": "household", "value": 2, "unit": "slices",
                  "conversion_ref": "bread_slice", "grams": 60.0}}]),
    "rcp-000478": (
        [{"path": "minutes",
          "reason": "The recipe's own timers run 5 + 15 + 12 = 32 minutes against a "
                    "25-minute promise; 35 keeps the promise honest and leaves prep "
                    "room.",
          "evidence": "rcp-000478 audit: timer sum 32 min vs 25 min promise (C7)"}],
        [{"op": "minutes", "value": 35}]),
    "rcp-000561": (
        [{"path": "ingredients[basmati rice]",
          "reason": "Step 3 says eat over rice but no line held it, and without it a "
                    "serving sits under the energy floor at 144 kcal; a cup of rice "
                    "for the two of us brings a serving to ~264 kcal at the canon's "
                    "rice energy.",
          "evidence": "rcp-000561 audit: 'rice' named in step 3, no line (C1); kcal "
                      "144.3 below 150 — same pattern as the rcp-000436 rice fix"}],
        [{"op": "add_line", "name": "basmati rice",
          "qty": {"kind": "household", "value": 1, "unit": "cup",
                  "conversion_ref": "dry_rice_cup", "grams": 185.0}}]),
}

RIGHTS_PIN_IDS = {"rcp-000450", "rcp-000463", "rcp-000561"}


def find_line(rec: dict, needle: str) -> int:
    for i, ing in enumerate(rec["ingredients"]):
        if needle in ing["name"].lower():
            return i
    raise SystemExit(f"line not found for {needle!r} in {rec['title']!r}")


def apply_ops(rec: dict, ops: list[dict], conv: dict[str, float]) -> None:
    for o in ops:
        if o["op"] == "servings":
            rec["servings"] = o["value"]
        elif o["op"] == "minutes":
            rec["minutes"] = o["value"]
        elif o["op"] == "set_qty_grams":
            i = find_line(rec, o["name"])
            rec["ingredients"][i]["qty"] = {
                "kind": "source_grams", "grams": o["grams"], "note": o.get("note", "")}
        elif o["op"] == "add_line":
            qty = dict(o["qty"])
            ref = qty.get("conversion_ref")
            if ref not in conv:  # ref missing -> honest grams instead of a broken ref
                qty = {"kind": "source_grams", "grams": qty["grams"]}
            rec["ingredients"].append({"name": o["name"], "qty": qty})
        else:
            raise SystemExit(f"unknown op {o['op']!r}")


def verify(fixes: dict[str, dict], corpus: dict[str, dict],
           mappings: dict[str, dict], vocab_by_key: dict, rights: dict,
           rights_ctx: dict) -> None:
    """Compile every fixed record and print the post-fix plausibility numbers."""
    print(f"{'catalog':<13}{'kcal':>8}{'sodium':>9}{'protein':>9}  title")
    for cid, fix in sorted(fixes.items()):
        labels = {fix["record"]["id"]: compiler.rights_label_for(fix["record"], rights_ctx)}
        compiled = compiler.compile_recipe(fix["record"], mappings, vocab_by_key,
                                           rights, labels)
        n = compiled["nutrition_per_serving"]
        prot = next((i["qty"].get("grams", 0.0) for i in fix["record"]["ingredients"]
                     for key in ("chicken", "beef", "pork", "lamb", "duck")
                     if key in i["name"].lower()), 0.0)
        per = prot / fix["record"]["servings"]
        flag = ""
        if not (150.0 <= n["kcal"] <= 1300.0):
            flag += " KCAL!"
        if n.get("sodium_mg", 0.0) > 2300.0:
            flag += " NA!"
        if per and not (110.0 <= per <= 225.0):
            flag += " PROT!"
        print(f"{cid:<13}{n['kcal']:>8.1f}{n.get('sodium_mg', 0.0):>9.1f}{per:>9.1f}"
              f"  {fix['record']['title'][:40]}{flag}")


def build() -> dict:
    corpus, raws = load_corpus()
    mappings, vocab_by_key, rights, rights_ctx = compile_ctx()
    conv = conv_table()
    cid_by_fid = {fid: vcorpus.catalog_id_for(fid) for fid in corpus}
    fid_by_cid = {cid: fid for fid, cid in cid_by_fid.items()}

    fixes = []
    for cid, (change_list, ops) in FIX_SPECS.items():
        fid = fid_by_cid[cid]
        import copy
        rec = copy.deepcopy(corpus[fid])
        apply_ops(rec, ops, conv)
        fix = {
            "id": fid,
            "catalog_id": cid,
            "before_sha256": hashlib.sha256(raws[fid]).hexdigest(),
            "record": rec,
            "changes": change_list,
        }
        if cid in RIGHTS_PIN_IDS:
            fix["changes_rights_pin"] = True
        fixes.append(fix)

    doc = {"schema": "fridgeluck/corpus-fixes/v1", "packet": PACKET,
           "base_commit": base_commit(), "fixes": fixes}
    out = REPO / "data/recipes/fixes/review-fixed.json"
    out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
                   encoding="utf-8")
    print(f"wrote {out.relative_to(REPO)} with {len(fixes)} fixes")
    verify({f["catalog_id"]: f for f in fixes}, corpus, mappings,
           vocab_by_key, rights, rights_ctx)
    return doc


if __name__ == "__main__":
    build()
