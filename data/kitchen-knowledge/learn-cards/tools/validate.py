#!/usr/bin/env python3
"""Validate learn cards, index, and sources against the binding schema.

Exit 0 = green. Stdlib only. Run from repo root:
  python3 data/kitchen-knowledge/learn-cards/tools/validate.py
"""
import json
import os
import re
import sys

import rulebook as _rulebook

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
CARDS = os.path.join(ROOT, "cards")

ALLOWED_NUTRIENTS = {
    "energyKcal", "proteinG", "carbohydrateG", "sugarG", "fiberG", "fatG",
    "saturatedFatG", "sodiumMg", "potassiumMg", "calciumMg", "ironMg",
    "vitaminCMg", "vitaminARaeMcg", "folateMcg",
}
SECTIONS = ["whatItIs", "historyNote", "howToChoose", "storage", "useItUp"]
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FOOD_SAFETY_PATH = "data/food-safety/rules.json"

# The referenced rulebook, resolved once in main(): the id set every
# storage.foodSafetyRef ruleIds entry must come from.
RULEBOOK = {"ids": set(), "src": "unloaded"}

errors = []
def err(msg):
    errors.append(msg)

def check(cond, msg):
    if not cond:
        err(msg)

def check_numberish(key, v, card_id):
    if key == "energyKcal":
        check(isinstance(v, (int, float)), f"{card_id}: energyKcal not numeric: {v!r}")
        return
    check(isinstance(v, (int, float)) and not isinstance(v, bool),
          f"{card_id}: nutrient {key} not numeric: {v!r}")
    if isinstance(v, float):
        check(round(v, 2) == v, f"{card_id}: nutrient {key} has more than 2 decimals: {v!r}")

def validate_card(path):
    card_id = os.path.basename(path)[:-5]
    try:
        with open(path, encoding="utf-8") as f:
            card = json.load(f)
    except json.JSONDecodeError as e:
        err(f"{card_id}: invalid JSON: {e}")
        return None

    check(card.get("schemaVersion") == 1, f"{card_id}: schemaVersion must be 1")
    check(card.get("kind") == "learn-card", f"{card_id}: kind must be learn-card")
    check(bool(DATE_RE.match(str(card.get("retrieved", "")))),
          f"{card_id}: retrieved must be YYYY-MM-DD")
    data = card.get("data") or {}
    check(data.get("id") == card_id, f"{card_id}: data.id mismatch")
    check(isinstance(data.get("displayName"), str) and data["displayName"],
          f"{card_id}: displayName required")
    check(isinstance(data.get("isCore"), bool), f"{card_id}: isCore must be bool")
    check(isinstance(data.get("category"), str) and data["category"],
          f"{card_id}: category required")

    sources = data.get("sources") or {}
    check(isinstance(sources, dict) and len(sources) >= 1,
          f"{card_id}: sources map required")
    for sid, src in sources.items():
        check(isinstance(sid, str) and sid, f"{card_id}: bad source id {sid!r}")
        for field in ("title", "publisher", "url", "retrieved", "licence"):
            check(isinstance(src.get(field), str) and src[field].strip(),
                  f"{card_id}: source {sid} missing/empty {field}")
        url = src.get("url", "")
        check(url.startswith("http://") or url.startswith("https://"),
              f"{card_id}: source {sid} url not http(s): {url!r}")
        check(bool(DATE_RE.match(src.get("retrieved", ""))),
              f"{card_id}: source {sid} retrieved not YYYY-MM-DD")

    sections = data.get("sections") or {}
    for name in SECTIONS:
        sec = sections.get(name)
        check(isinstance(sec, dict), f"{card_id}: section {name} missing")
        if isinstance(sec, dict):
            check(isinstance(sec.get("text"), str) and sec["text"].strip(),
                  f"{card_id}: section {name} text empty")
            cites = sec.get("citations")
            check(isinstance(cites, list), f"{card_id}: section {name} citations must be a list")
            if isinstance(cites, list):
                for c in cites:
                    check(c in sources, f"{card_id}: section {name} citation {c!r} not in sources")
            if name == "historyNote":
                check(bool(cites), f"{card_id}: historyNote needs >=1 citation")
            if name == "storage":
                ref = sec.get("foodSafetyRef") or {}
                check(ref.get("path") == FOOD_SAFETY_PATH,
                      f"{card_id}: storage.foodSafetyRef.path must be {FOOD_SAFETY_PATH}")
                check(isinstance(ref.get("note"), str) and ref["note"].strip(),
                      f"{card_id}: storage.foodSafetyRef.note required")
                # Fail closed: cited rules must exist in the rulebook, and a
                # storage text that invokes the rulebook must cite at least
                # one resolvable rule id (unbacked attribution is a failure).
                ids = ref.get("ruleIds")
                check(isinstance(ids, list) and all(isinstance(i, str) for i in ids),
                      f"{card_id}: storage.foodSafetyRef.ruleIds must be a list of rule ids")
                if isinstance(ids, list):
                    for rid in ids:
                        check(rid in RULEBOOK["ids"],
                              f"{card_id}: storage.foodSafetyRef rule id {rid!r} does not "
                              f"resolve in the rulebook ({RULEBOOK['src']})")
                if "rulebook" in (sec.get("text") or "").lower():
                    check(bool(ids),
                          f"{card_id}: storage text invokes the rulebook without a "
                          "resolvable ruleIds entry — unbacked attribution")

    subs = data.get("substitutions")
    check(isinstance(subs, list), f"{card_id}: substitutions must be a list")
    if isinstance(subs, list):
        for s in subs:
            check(isinstance(s.get("substitute"), str) and s["substitute"],
                  f"{card_id}: substitution missing substitute")
            check(isinstance(s.get("ratio"), str) and s["ratio"],
                  f"{card_id}: substitution missing ratio")
            check(isinstance(s.get("note"), str) and s["note"],
                  f"{card_id}: substitution missing note")
            for c in s.get("citations", []):
                check(c in sources, f"{card_id}: substitution citation {c!r} not in sources")

    nut = data.get("nutritionPer100g")
    if nut is not None:
        fid = nut.get("fdcId")
        check(isinstance(fid, int) and not isinstance(fid, bool) and fid > 0,
              f"{card_id}: fdcId must be a positive integer")
        check(nut.get("fdcDescription"), f"{card_id}: fdcDescription required")
        check(nut.get("fdcDataType") == "SR Legacy",
              f"{card_id}: fdcDataType must be SR Legacy")
        check(nut.get("sourceId") in sources,
              f"{card_id}: nutritionPer100g.sourceId not in sources")
        nutrients = nut.get("nutrients") or {}
        keys = set(nutrients)
        check(keys <= ALLOWED_NUTRIENTS,
              f"{card_id}: nutrient keys outside the allowed 14: {sorted(keys - ALLOWED_NUTRIENTS)}")
        check("energyKcal" in keys, f"{card_id}: energyKcal required")
        for k, v in nutrients.items():
            check_numberish(k, v, card_id)
    return card

def main():
    # Storage references must resolve, or the dependent claim fails (closed):
    # load the referenced rulebook up front — in-tree, else the reviewed branch.
    try:
        rb, src = _rulebook.load(ROOT)
        RULEBOOK["ids"] = _rulebook.rule_ids(rb)
        RULEBOOK["src"] = src
    except _rulebook.Unresolvable as e:
        err(f"referenced safety rulebook could not be loaded: {e}")

    files = sorted(f for f in os.listdir(CARDS) if f.endswith(".json"))
    cards = {}
    for fn in files:
        c = validate_card(os.path.join(CARDS, fn))
        if c is not None:
            cards[c["data"]["id"]] = c
    check(len(cards) == len(files), "some cards failed to parse (id collisions?)")

    idx_path = os.path.join(ROOT, "index.json")
    check(os.path.exists(idx_path), "index.json missing")
    idx = None
    if os.path.exists(idx_path):
        try:
            with open(idx_path, encoding="utf-8") as f:
                idx = json.load(f)
        except json.JSONDecodeError as e:
            err(f"index.json: invalid JSON: {e}")
    if idx is not None:
        check(idx.get("schemaVersion") == 1, "index.json: schemaVersion must be 1")
        check(idx.get("kind") == "learn-card-index", "index.json: kind must be learn-card-index")
        check(bool(DATE_RE.match(str(idx.get("retrieved", "")))),
              "index.json: retrieved must be YYYY-MM-DD")
        d = idx.get("data") or {}
        entries = d.get("cards") or []
        ids = [e.get("id") for e in entries]
        check(ids and sorted(ids) == sorted(cards),
              "index.json: cards[] must match cards/*.json exactly")
        check(len(ids) == len(set(ids)), "index.json: duplicate ids")
        for e in entries:
            cid = e.get("id")
            if cid in cards:
                src = cards[cid]["data"]
                for field in ("displayName", "isCore", "category"):
                    check(e.get(field) == src.get(field),
                          f"index.json {cid}: {field} mismatch with card")
                nut = src.get("nutritionPer100g") or {}
                check(e.get("fdcId") == nut.get("fdcId"),
                      f"index.json {cid}: fdcId mismatch with card")
                check(isinstance(e.get("frequencyInBundledRecipes"), int),
                      f"index.json {cid}: frequencyInBundledRecipes must be int")
        cov = d.get("coverage") or {}
        check(isinstance(cov.get("cardsWritten"), int), "index coverage.cardsWritten required")
        check(isinstance(cov.get("note"), str) and cov["note"],
              "index coverage.note required (records corpus and any refusals)")
        cards_without = sorted(
            cid for cid, c in cards.items() if "nutritionPer100g" not in c["data"])
        listed = sorted(cov.get("missingNutrition") or [])
        check(listed == cards_without,
              f"index coverage.missingNutrition {listed} != cards without nutrition {cards_without}")

    # Universe conservation: every seed-corpus line's frequency lands on
    # exactly one card. A counting regression (an earlier build looked up
    # exact-name frequencies at core-card init AND again in the seed loop,
    # double-counting 1862 units) inflates the sum and fails here.
    universe_path = os.path.join(HERE, "universe.json")
    check(os.path.exists(universe_path), "universe.json missing (run universe.py)")
    if os.path.exists(universe_path):
        try:
            sys.path.insert(0, HERE)
            import universe as _universe
            seed = _universe.load_seed()
            with open(universe_path, encoding="utf-8") as f:
                u = json.load(f)
            card_sum = sum(c.get("frequencyInSeedCorpus", 0)
                           for c in (u.get("cards") or {}).values())
            corpus_sum = sum(seed.values())
            check(card_sum == corpus_sum,
                  f"universe.json: card seed-corpus frequencies sum to {card_sum}, "
                  f"but the corpus carries {corpus_sum} — a frequency is counted "
                  f"more than once or dropped (counting regression)")
        except Exception as e:  # noqa: BLE001 — validator must not crash on import
            err(f"universe.json: conservation check could not run: {e}")

    if errors:
        for e in errors:
            print("FAIL:", e)
        print(f"\n{len(errors)} problem(s)")
        sys.exit(1)
    print(f"validate: OK — {len(cards)} cards, all checks green")

if __name__ == "__main__":
    main()
