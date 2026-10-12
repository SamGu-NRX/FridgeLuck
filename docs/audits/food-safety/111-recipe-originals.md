# Fix list — PR #111 (fleet/fl-recipe-originals — per-cuisine originals (59 recipe files))

Branch `fleet/fl-recipe-originals` · PR head pinned at `ef1d159eec26d5f0c985da052b3517e510efd67a` · linted 2026-10-12 · **59 records, 114 findings**. Linter: `fl-safety-lint` built from the canon branch at `299ff32` (`packages/FLFoodSafety`); this task added no linter code.

## Extraction (provenance)

Each recipe file under `data/recipes/originals/` (cuisine directories; the `tables/` reference tables and `tools/` files are not recipes and were not linted — `tools/compound-allergens.json` is a reference table, `tools/SUITE-PIN.json` a pin manifest) becomes one recipe record with the same mapping as PR #107: `steps[].text` as numbered instructions, `steps[].safety` as `safety_fields`, ingredient names joined. All text verbatim. 59 records.

Extraction scripts (deterministic; run against a checkout of the head above; scratch copies: `extract/kit.py` + `extract/x_data.py` — the per-target script imports the shared kit for the leaf-block HTML extractor, the keyword screen and the record builders):

```python
# ---- kit.py (shared) ----
"""Shared extraction kit for the P5 fix lists (scratch only, never committed).

Provides faithful leaf-block text extraction for HTML mocks, the
food-safety keyword screen used to SELECT which extracted strings become
lint records, and record builders matching data/food-safety/conformance/README.md.
"""
import json, re
from html.parser import HTMLParser

BLOCK = {"p","div","li","h1","h2","h3","h4","h5","h6","section","tr","td","th",
         "ul","ol","table","blockquote","figcaption","dt","dd","main","header","footer","aside","button"}
VOID = {"meta","br","hr","img","input","link","source","area","base","col","embed","track","wbr"}

class LeafExtractor(HTMLParser):
    """Emits the visible text of every block element that contains no nested
    block elements (a leaf block). Inline children merge into the block's
    text; text of nested blocks is emitted by the nested block itself."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []      # [tag, is_block, buf(list), drop, had_block_child]
        self.lines = []
    def handle_starttag(self, tag, attrs):
        if tag in VOID:
            return
        drop = tag in ("style","script","svg","title")
        self.stack.append([tag, tag in BLOCK, [], drop, False])
    def handle_endtag(self, tag):
        for i in range(len(self.stack)-1, -1, -1):
            if self.stack[i][0] == tag:
                frame = self.stack[i:]
                del self.stack[i:]
                elem, is_block, buf, drop, had_block_child = frame[0]
                text = " ".join(" ".join(buf).split())
                if text and is_block and not had_block_child:
                    self.lines.append(text)
                if self.stack and not self.stack[-1][3]:
                    self.stack[-1][2].append(text)
                if is_block or had_block_child:
                    if self.stack:
                        self.stack[-1][4] = True
                return
    def handle_data(self, data):
        if self.stack and not self.stack[-1][3]:
            self.stack[-1][2].append(data)

def leaf_lines(html_text):
    p = LeafExtractor(); p.feed(html_text)
    return p.lines

# The keyword screen: which extracted strings are food-safety-bearing and
# become lint records. Deterministic, documented, applied verbatim strings.
SAFETY_SCREEN = re.compile(r"(?i)(thermometer|°\s*[cf]|\btemperature\b|doneness|\bpink\b|golden|juices|cooked through|browned|opaque|firm|reheat|warm(ed)? (up|through)|microwave|leftover|spoil|slimy|smell|rotten|mold|mould|stale|wilted|limp|too far gone|use.?it.?up|use-soon|last legs|going (off|bad)|gone (off|bad)|thaw|defrost|freez|chill|fridge|refrigerat|pasteuriz|pasteuris|raw egg|food.?safe|safe (minimum|to eat)|use.by|use by|date)")

def records_file(description, records):
    return {"schema_version": 1, "description": description, "records": records}

def recipe_record(file, id, title, ingredients, steps, safety_fields=None):
    rec = {"kind": "recipe", "file": file, "id": id, "title": title,
           "ingredients": ingredients,
           "instructions": "\n".join(f"{i+1}. {s}" for i, s in enumerate(steps))}
    if safety_fields:
        rec["safety_fields"] = {str(i): f for i, f in safety_fields.items()}
    return rec

def copy_record(file, id, field, text):
    return {"kind": "copy", "file": file, "id": id, "field": field, "text": text}

def write(path, doc):
    with open(path, "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
    print(f"{path}: {len(doc['records'])} records")

```

```python
# ---- x_data.py ----
#!/usr/bin/env python3
"""Extractors for PRs #111 (per-cuisine recipes), #109 (learn cards),
#116 (challenge packs). Faithful verbatim extraction; record shapes per
data/food-safety/conformance/README.md."""
import json, sys, os, subprocess, glob
sys.path.insert(0, os.path.dirname(__file__))
from kit import records_file, recipe_record, copy_record, write

BASE = "/home/user/work/fs-canon-p5"

def rev(ref):
    return subprocess.run(["git", "rev-parse", ref], capture_output=True, text=True,
                          cwd=f"{BASE}/clone").stdout.strip()

def p111():
    ref = "p5/p111"
    sha = rev(ref)
    src = "data/recipes/originals"
    files = sorted(glob.glob(f"{BASE}/targets/p111/data/recipes/originals/**/*.json", recursive=True))
    files = [f for f in files if "/tables/" not in f and "/tools/" not in f]
    records = []
    for path in files:
        r = json.load(open(path))
        steps = [s.get("text", "") for s in r.get("steps", [])]
        safety = {}
        for i, s in enumerate(r.get("steps", [])):
            if isinstance(s.get("safety"), dict):
                safety[i] = s["safety"]
        ingredients = ", ".join(
            ing.get("name", "") for ing in r.get("ingredients", [])
            if isinstance(ing, dict) and ing.get("name"))
        rel = path.replace(f"{BASE}/targets/p111/", "")
        records.append(recipe_record(
            file=src, id=r["id"], title=r.get("title", ""),
            ingredients=ingredients, steps=steps, safety_fields=safety))
    doc = records_file(
        f"PR #111 (fleet/fl-recipe-originals) {src}/**.json - 60 per-cuisine recipe files, steps and per-step safety metadata verbatim",
        records)
    write(f"{BASE}/records/p111-recipe-originals.json", doc)
    print(f"p111: {len(records)} recipe records from {len(files)} files; head {sha}")

def p109():
    ref = "p5/p109"
    sha = rev(ref)
    src = "data/kitchen-knowledge/learn-cards/cards"
    files = sorted(glob.glob(f"{BASE}/targets/p109/{src}/*.json"))
    records = []
    for path in files:
        card = json.load(open(path))["data"]
        for section, body in sorted(card.get("sections", {}).items()):
            if isinstance(body, dict) and isinstance(body.get("text"), str) and body["text"].strip():
                records.append(copy_record(
                    file=src, id=f"{card['id']}#{section}",
                    field=section, text=body["text"]))
        for n, sub in enumerate(card.get("substitutions", [])):
            if isinstance(sub, dict) and isinstance(sub.get("note"), str) and sub["note"].strip():
                records.append(copy_record(
                    file=src, id=f"{card['id']}#substitution-{n}",
                    field="substitution-note", text=sub["note"]))
    doc = records_file(
        f"PR #109 (overhaul/learn-cards) {src}/*.json - all section texts and substitution notes, verbatim",
        records)
    write(f"{BASE}/records/p109-learn-cards.json", doc)
    print(f"p109: {len(records)} copy records from {len(files)} cards; head {sha}")

PACK_TEXT_KEYS = {"tactic", "note", "notes", "distributionNote", "methodNote"}

def _walk(node, path, out, src, packid):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in PACK_TEXT_KEYS and isinstance(v, str) and v.strip():
                stem = ".".join(str(p) for p in path if not isinstance(p, int))
                idx = ".".join(str(p) for p in path if isinstance(p, int))
                key = k if not stem or stem == k else f"{stem}.{k}"
                if idx:
                    key = f"{key}[{idx}]"
                out.append(copy_record(file=src, id=f"{packid}#{key}", field=k, text=v))
            else:
                _walk(v, path + [k], out, src, packid)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, path + [i], out, src, packid)

def p116():
    ref = "p5/p116"
    sha = rev(ref)
    src = "data/kitchen-knowledge/packs"
    records = []
    for name in ["use_it_up_packs", "budget_packs", "food_bank_packs", "seasonal_packs"]:
        d = json.load(open(f"{BASE}/targets/p116/{src}/{name}.json"))["data"]
        n_before = len(records)
        for pack in d.get("packs", []):
            _walk(pack, [], records, src, pack["id"])
        if isinstance(d.get("methodNote"), str) and d["methodNote"].strip():
            records.append(copy_record(file=src, id=f"{name}:data#methodNote",
                                       field="methodNote", text=d["methodNote"]))
        print(f"  {name}: {len(records) - n_before} copy records")
    doc = records_file(
        f"PR #116 (overhaul/challenge-packs) {src}/*.json - all tactic/note/notes/distributionNote/methodNote strings, verbatim",
        records)
    write(f"{BASE}/records/p116-challenge-packs.json", doc)
    print(f"p116: {len(records)} copy records; head {sha}")

if __name__ == "__main__":
    os.makedirs(f"{BASE}/records", exist_ok=True)
    which = sys.argv[1:] or ["111", "109", "116"]
    if "111" in which: p111()
    if "109" in which: p109()
    if "116" in which: p116()

```

## Reproduce the lint

```sh
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json> --json   # machine output
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json>        # human output
```

The `<records.json>` file is `p111-recipe-originals.json` in the canon task's scratch — the extraction output described above (59 records, shape per `data/food-safety/conformance/README.md`). Rerunning the extraction scripts on the same head reproduces it byte-for-byte.

## Findings by kind

| kind | count |
|---|---|
| `appearanceDoneness` | 2 |
| `belowMinimumTemperature` | 1 |
| `flagForReview` | 1 |
| `metadataNotInText` | 30 |
| `missingInternalTemperature` | 31 |
| `missingRestTime` | 3 |
| `missingThermometer` | 7 |
| `reheatingWithoutThermometer` | 8 |
| `timeOnlyCooking` | 31 |

Total: **114 findings** over 59 records.

## Findings

#### 1. `reheatingWithoutThermometer` — data/recipes/originals · ea-chicken-adobo-rice · `instructions[9]`

- **Current text:** “9. Scatter the green onions on top and serve - adobo reheats well, so keep any extra chicken in its sauce.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 2. `appearanceDoneness` — data/recipes/originals · ea-chicken-larb-lettuce-cups · `instructions[1]`

- **Current text:** “1. Toast the jasmine rice in a dry skillet over medium heat, shaking often, for 3 minutes until it smells like popcorn and turns golden in patches.”
- **Trigger phrase:** golden
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Rule:** `thermometer-only-reliable`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 3. `missingInternalTemperature` — data/recipes/originals · ea-chicken-larb-lettuce-cups · `instructions[6]`

- **Current text:** “6. Off the heat, pour the fish-sauce mixture over the chicken and toss so it steams into the meat.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 4. `missingThermometer` — data/recipes/originals · ea-chilled-rice-noodles-herbs-egg · `instructions[3]`

- **Current text:** “3. Beat the eggs. Heat 1 teaspoon of the oil in a small nonstick skillet over medium, pour in a third of the egg, and tilt to coat the pan in a thin layer; cook about 2 minutes until the top looks matte. Eggs are safe at 160°F (71°C).”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 5. `metadataNotInText` — data/recipes/originals · ea-chilled-rice-noodles-herbs-egg · `instructions[3]`

- **Current text:** “3. Beat the eggs. Heat 1 teaspoon of the oil in a small nonstick skillet over medium, pour in a third of the egg, and tilt to coat the pan in a thin layer; cook about 2 minutes until the top looks matte. Eggs are safe at 160°F (71°C).”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 6. `missingInternalTemperature` — data/recipes/originals · ea-ginger-pork-rice-bowl · `instructions[2]`

- **Current text:** “2. Set a nonstick skillet over medium-high, add the pork, and break it into small crumbles with the spatula. Cook 6 minutes until the crumbles sizzle in their own fat; ground pork is safe at 160°F (71°C).”
- **Why:** 160°f is not an internal reading — the step cooks ground pork with no thermometer-named check
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 7. `metadataNotInText` — data/recipes/originals · ea-ginger-pork-rice-bowl · `instructions[2]`

- **Current text:** “2. Set a nonstick skillet over medium-high, add the pork, and break it into small crumbles with the spatula. Cook 6 minutes until the crumbles sizzle in their own fat; ground pork is safe at 160°F (71°C).”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 8. `missingInternalTemperature` — data/recipes/originals · ea-ginger-pork-rice-bowl · `instructions[3]`

- **Current text:** “3. Stir in the grated ginger and cook 30 seconds - it should smell sharp and sweet, not raw.”
- **Why:** the step cooks ground pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 9. `metadataNotInText` — data/recipes/originals · ea-ginger-pork-rice-bowl · `instructions[6]`

- **Current text:** “6. Beat the eggs with a fork. Pour them into the skillet over medium-low and stir slowly into small soft curds for 2 minutes; they are safe at 160°F (71°C).”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 10. `missingInternalTemperature` — data/recipes/originals · ea-kimchi-tofu-stew · `instructions[6]`

- **Current text:** “6. Turn the heat to medium-low so the stew bubbles gently, drizzle the beaten egg in a slow stream while stirring in one direction, and cook 1 minute; eggs are safe at 160°F (71°C) - if in doubt check with a thermometer, or use pasteurized eggs.”
- **Why:** a thermometer is named but no internal temperature is stated — the check does not count without one
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 11. `metadataNotInText` — data/recipes/originals · ea-kimchi-tofu-stew · `instructions[6]`

- **Current text:** “6. Turn the heat to medium-low so the stew bubbles gently, drizzle the beaten egg in a slow stream while stirring in one direction, and cook 1 minute; eggs are safe at 160°F (71°C) - if in doubt check with a thermometer, or use pasteurized eggs.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 12. `missingInternalTemperature` — data/recipes/originals · ea-korean-spicy-tuna-rice-bowl · `instructions[3]`

- **Current text:** “3. Add the kimchi and cook 2 minutes, scraping, until it stops bubbling hard and smells toasty.”
- **Why:** the step cooks tuna but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 13. `timeOnlyCooking` — data/recipes/originals · ea-korean-spicy-tuna-rice-bowl · `instructions[4]`

- **Current text:** “4. Add the drained tuna in chunks, pour in the sauce, and fold 2 minutes over medium heat so the tuna warms through and drinks the sauce without shredding to paste.”
- **Trigger phrase:** tuna
- **Required change:** Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 14. `reheatingWithoutThermometer` — data/recipes/originals · ea-korean-spicy-tuna-rice-bowl · `instructions[5]`

- **Current text:** “5. Warm the rice in the microwave or in a dry skillet over the tuna pan's residual heat.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 15. `missingThermometer` — data/recipes/originals · ea-korean-spicy-tuna-rice-bowl · `instructions[6]`

- **Current text:** “6. Fry the eggs in the same skillet for 2 minutes, spooning the fat over the tops until the whites are set; they are safe at 160°F (71°C) - use pasteurized eggs if you want the yolks runny.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 16. `metadataNotInText` — data/recipes/originals · ea-korean-spicy-tuna-rice-bowl · `instructions[6]`

- **Current text:** “6. Fry the eggs in the same skillet for 2 minutes, spooning the fat over the tops until the whites are set; they are safe at 160°F (71°C) - use pasteurized eggs if you want the yolks runny.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 17. `missingThermometer` — data/recipes/originals · ea-thai-basil-chicken-egg · `instructions[3]`

- **Current text:** “3. Fry the eggs: heat 1 tablespoon of the oil in a small skillet over medium-high until it sizzles at the edges, slide in both eggs, and spoon the hot oil over them until the whites are set, about 2 minutes. They are safe at 160°F (71°C) - use pasteurized eggs if you want the yolks runny.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 18. `metadataNotInText` — data/recipes/originals · ea-thai-basil-chicken-egg · `instructions[3]`

- **Current text:** “3. Fry the eggs: heat 1 tablespoon of the oil in a small skillet over medium-high until it sizzles at the edges, slide in both eggs, and spoon the hot oil over them until the whites are set, about 2 minutes. They are safe at 160°F (71°C) - use pasteurized eggs if you want the yolks runny.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 19. `timeOnlyCooking` — data/recipes/originals · ea-thai-basil-chicken-egg · `instructions[5]`

- **Current text:** “5. Add the ground chicken, press it flat against the pan, and let it sear 4 minutes without stirring.”
- **Trigger phrase:** ground chicken
- **Required change:** Cook until a food thermometer in the centre of the patty or the thickest part of the portion reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `ground-poultry-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 20. `missingThermometer` — data/recipes/originals · ea-thai-basil-chicken-egg · `instructions[6]`

- **Current text:** “6. Break the chicken up and stir-fry 3 minutes more; ground chicken is safe at 165°F (74°C) - check the center of the mass.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the centre of the patty or the thickest part of the portion reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-poultry-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 21. `metadataNotInText` — data/recipes/originals · ea-thai-basil-chicken-egg · `instructions[6]`

- **Current text:** “6. Break the chicken up and stir-fry 3 minutes more; ground chicken is safe at 165°F (74°C) - check the center of the mass.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 22. `metadataNotInText` — data/recipes/originals · ea-tomato-egg-stir-fry-rice · `instructions[3]`

- **Current text:** “3. Pour in the eggs, let them puff for a few seconds, then push with the spatula into soft curds. A thermometer reads 160°F (71°C) while the curds still look a little glossy - pull them out at that point.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 23. `missingInternalTemperature` — data/recipes/originals · ea-tomato-egg-stir-fry-rice · `instructions[6]`

- **Current text:** “6. Add the tomato wedges and stir-fry for 2 minutes, then add the rest of the salt and all the sugar; keep the pieces moving so they release juice but hold shape.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 24. `timeOnlyCooking` — data/recipes/originals · ea-vietnamese-caramel-pork-eggs · `instructions[3]`

- **Current text:** “3. Add the pork chunks and turn to coat in the syrup; sear 3 minutes, turning once.”
- **Trigger phrase:** pork
- **Required change:** Cook until a food thermometer in the thickest part of the cut, away from bone, fat or gristle reads 63 °C (145 °F), then rest 3 minutes — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 25. `missingThermometer` — data/recipes/originals · ea-vietnamese-caramel-pork-eggs · `instructions[5]`

- **Current text:** “5. Meanwhile boil the eggs: 9 minutes in salted water, then chill under cold running water and peel. Eggs are safe at 160°F (71°C) - at 9 minutes the yolks are just fully set.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 26. `metadataNotInText` — data/recipes/originals · ea-vietnamese-caramel-pork-eggs · `instructions[5]`

- **Current text:** “5. Meanwhile boil the eggs: 9 minutes in salted water, then chill under cold running water and peel. Eggs are safe at 160°F (71°C) - at 9 minutes the yolks are just fully set.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 27. `missingThermometer` — data/recipes/originals · ea-vietnamese-caramel-pork-eggs · `instructions[6]`

- **Current text:** “6. Cover and simmer the pork gently for 25 minutes, stirring now and then. Pork is safe at 145°F (63°C) with a 3-minute rest, and a long simmer goes far past that - what you are watching for is the sauce turning brick-dark and glossy.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 28. `metadataNotInText` — data/recipes/originals · ea-vietnamese-caramel-pork-eggs · `instructions[6]`

- **Current text:** “6. Cover and simmer the pork gently for 25 minutes, stirring now and then. Pork is safe at 145°F (63°C) with a 3-minute rest, and a long simmer goes far past that - what you are watching for is the sauce turning brick-dark and glossy.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 29. `timeOnlyCooking` — data/recipes/originals · ea-vietnamese-caramel-pork-eggs · `instructions[7]`

- **Current text:** “7. Halve the eggs and nestle them in the sauce; simmer uncovered 5 minutes so they drink up color.”
- **Trigger phrase:** eggs
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 30. `timeOnlyCooking` — data/recipes/originals · ea-weeknight-japanese-curry · `instructions[5]`

- **Current text:** “5. Add the chicken pieces and toss 2 minutes to coat and seal the outsides.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 31. `missingThermometer` — data/recipes/originals · ea-weeknight-japanese-curry · `instructions[6]`

- **Current text:** “6. Add the carrots, potatoes, and water, scraping the bottom; bring to a simmer, cover, and cook 15 minutes at a lazy bubble. Chicken is safe at 165°F (74°C) - check a thick piece.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 32. `metadataNotInText` — data/recipes/originals · ea-weeknight-japanese-curry · `instructions[6]`

- **Current text:** “6. Add the carrots, potatoes, and water, scraping the bottom; bring to a simmer, cover, and cook 15 minutes at a lazy bubble. Chicken is safe at 165°F (74°C) - check a thick piece.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 33. `reheatingWithoutThermometer` — data/recipes/originals · ea-weeknight-japanese-curry · `instructions[9]`

- **Current text:** “9. Serve in deep plates over the rice with green onions scattered on top; the curry reheats even better the next day and freezes for a month.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 34. `metadataNotInText` — data/recipes/originals · eu-american-goulash · `instructions[1]`

- **Current text:** “1. Brown the beef hard in a dry pot over medium-high heat, breaking it into crumbles, for 6 minutes. Ground beef is safe at 160°F (71°C) - spot-check the thickest clump with a thermometer.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 35. `timeOnlyCooking` — data/recipes/originals · eu-chicken-cacciatore-polenta · `instructions[1]`

- **Current text:** “1. Season the chicken chunks with half the salt and the pepper. Heat the oil in a deep skillet over medium-high and brown them for 5 minutes, turning twice - color here is seasoning, not doneness.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 36. `timeOnlyCooking` — data/recipes/originals · eu-chicken-cacciatore-polenta · `instructions[2]`

- **Current text:** “2. Lift the chicken out. Cook the onion and bell pepper in the same pan for 5 minutes, then add the garlic and cook 30 seconds more.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 37. `missingInternalTemperature` — data/recipes/originals · eu-chicken-cacciatore-polenta · `instructions[3]`

- **Current text:** “3. Add the mushrooms and cook for 5 minutes, until they release their liquid and it boils away.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 38. `missingInternalTemperature` — data/recipes/originals · eu-chicken-cacciatore-polenta · `instructions[7]`

- **Current text:** “7. Cook the polenta at a bare simmer for 20 minutes, whisking often - it grabs the pot, so reach the bottom corners.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 39. `flagForReview` — data/recipes/originals · eu-mushroom-barley-skillet · `instructions[6]`

- **Current text:** “6. Taste for salt and pepper, shower with the chives, and serve straight from the pot. Leftovers keep four days; loosen with a splash of water when reheating.”
- **Why:** the step names a protein ("6. Taste for salt and pepper, shower with the chives, and serve straight from the pot. Leftovers keep four days; loosen with a splash of water when reheating.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 40. `reheatingWithoutThermometer` — data/recipes/originals · eu-mushroom-barley-skillet · `instructions[6]`

- **Current text:** “6. Taste for salt and pepper, shower with the chives, and serve straight from the pot. Leftovers keep four days; loosen with a splash of water when reheating.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 41. `timeOnlyCooking` — data/recipes/originals · eu-oven-salmon-green-beans · `instructions[2]`

- **Current text:** “2. Roast the beans alone for 8 minutes so they blister while the salmon waits.”
- **Trigger phrase:** salmon
- **Required change:** Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 42. `missingRestTime` — data/recipes/originals · eu-pork-tenderloin-apples-sage · `instructions[3]`

- **Current text:** “3. Turn and cook 3 minutes more. Pork whole cuts are safe at 145°F (63°C) with a short rest - check a thick medallion with a thermometer.”
- **Why:** the class requires a 3-minute rest (rule whole-cut-pork-145-rest-3) that the text does not state
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 43. `metadataNotInText` — data/recipes/originals · eu-pork-tenderloin-apples-sage · `instructions[3]`

- **Current text:** “3. Turn and cook 3 minutes more. Pork whole cuts are safe at 145°F (63°C) with a short rest - check a thick medallion with a thermometer.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 44. `missingInternalTemperature` — data/recipes/originals · eu-pork-tenderloin-apples-sage · `instructions[4]`

- **Current text:** “4. Move the pork to a plate and let it rest while the apples cook.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 45. `timeOnlyCooking` — data/recipes/originals · eu-sheet-pan-chicken-potatoes-thyme · `instructions[2]`

- **Current text:** “2. Roast the potatoes alone for 15 minutes so they get a head start on the chicken.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 46. `timeOnlyCooking` — data/recipes/originals · eu-spanish-potato-onion-tortilla · `instructions[4]`

- **Current text:** “4. Let the mixture sit for 10 minutes - the potatoes drink some egg and the wedges hold together better.”
- **Trigger phrase:** egg
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 47. `missingInternalTemperature` — data/recipes/originals · eu-spanish-potato-onion-tortilla · `instructions[6]`

- **Current text:** “6. Cook for 5 minutes, drawing the edges in with a spatula once or twice, until the bottom is deep brown and the top is barely wet.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 48. `missingInternalTemperature` — data/recipes/originals · eu-spanish-potato-onion-tortilla · `instructions[7]`

- **Current text:** “7. Slide the tortilla onto a plate, set the pan over it, and flip both together in one confident motion; slide it back in to cook the soft side for 3 minutes.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 49. `metadataNotInText` — data/recipes/originals · eu-spanish-potato-onion-tortilla · `instructions[8]`

- **Current text:** “8. An egg dish is safe at 160°F (71°C) - check the center with a thermometer; the middle should be just set and still tender.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 50. `missingInternalTemperature` — data/recipes/originals · la-chicken-tinga-tostadas · `instructions[2]`

- **Current text:** “2. Bake the tortillas for 10 minutes, flipping once, until crisp and blistered at the edges. Hold them warm; they crisp further as they cool.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 51. `missingInternalTemperature` — data/recipes/originals · la-chicken-tinga-tostadas · `instructions[3]`

- **Current text:** “3. While the tortillas bake, heat the rest of the oil in a large skillet over medium heat. Cook the onion with a pinch of salt for 5 minutes, stirring a few times, until it softens and slumps.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 52. `timeOnlyCooking` — data/recipes/originals · la-chicken-tinga-tostadas · `instructions[7]`

- **Current text:** “7. Lift the chicken out and shred it with two forks while the sauce bubbles hard, uncovered, for 3-4 minutes to thicken.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 53. `timeOnlyCooking` — data/recipes/originals · la-chicken-tinga-tostadas · `instructions[8]`

- **Current text:** “8. Return the shredded chicken to the skillet and simmer 2 minutes so it drinks the sauce. Pull out the bay leaf and season with salt.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 54. `missingRestTime` — data/recipes/originals · la-cochinita-pibil · `instructions[4]`

- **Current text:** “4. Return the pork and any escaped marinade to the pot, clamp on the lid, and braise 3 hours. Pork shoulder is safe at 145°F (63°C), but a low braise takes it far past — check the thickest chunk on a thermometer.”
- **Why:** the class requires a 3-minute rest (rule whole-cut-pork-145-rest-3) that the text does not state
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 55. `metadataNotInText` — data/recipes/originals · la-cochinita-pibil · `instructions[4]`

- **Current text:** “4. Return the pork and any escaped marinade to the pot, clamp on the lid, and braise 3 hours. Pork shoulder is safe at 145°F (63°C), but a low braise takes it far past — check the thickest chunk on a thermometer.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 56. `missingRestTime` — data/recipes/originals · la-flank-steak-chimichurri · `instructions[4]`

- **Current text:** “4. Heat the grill pan over high heat until it just smokes. Lay the steak down and leave it alone for 4-5 minutes, then flip and cook 3-4 more. Flank steak is safe at 145°F (63°C) — check the thick end on a thermometer.”
- **Why:** the class requires a 3-minute rest (rule whole-cut-red-145-rest-3) that the text does not state
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 57. `metadataNotInText` — data/recipes/originals · la-flank-steak-chimichurri · `instructions[4]`

- **Current text:** “4. Heat the grill pan over high heat until it just smokes. Lay the steak down and leave it alone for 4-5 minutes, then flip and cook 3-4 more. Flank steak is safe at 145°F (63°C) — check the thick end on a thermometer.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 58. `reheatingWithoutThermometer` — data/recipes/originals · la-frijoles-negros · `instructions[2]`

- **Current text:** “2. Warm the oil in the pot over medium heat. Cook the pepper and onion for 8 minutes, scraping the bottom, until the onion is translucent and sweet.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 59. `missingInternalTemperature` — data/recipes/originals · la-lomo-saltado · `instructions[2]`

- **Current text:** “2. Pat the beef strips dry and season them with half the salt and all the black pepper. Dry beef sears; wet beef steams.”
- **Why:** the step cooks steak but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 60. `metadataNotInText` — data/recipes/originals · la-lomo-saltado · `instructions[4]`

- **Current text:** “4. Wipe the skillet, add the last tbsp of oil, and raise the heat to high. When the oil shimmers, add the beef in one uncrowded layer. Sear 2 minutes, turning once. Beef strips are safe at 145°F (63°C) — spot-check the thickest strip on a thermometer.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 61. `missingInternalTemperature` — data/recipes/originals · la-red-chilaquiles-fried-eggs · `instructions[2]`

- **Current text:** “2. Cook the salsa with half the salt in a skillet over medium heat for 8 minutes, until it darkens and smells roasted rather than tinny.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 62. `missingInternalTemperature` — data/recipes/originals · la-red-chilaquiles-fried-eggs · `instructions[5]`

- **Current text:** “5. Fry the eggs in the last of the oil over medium heat until the whites are fully set but the yolk still moves. Eggs are safe at 160°F (71°C) on a thermometer — check one if your pan runs cool.”
- **Why:** a thermometer is named but no internal temperature is stated — the check does not count without one
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 63. `metadataNotInText` — data/recipes/originals · la-red-chilaquiles-fried-eggs · `instructions[5]`

- **Current text:** “5. Fry the eggs in the last of the oil over medium heat until the whites are fully set but the yolk still moves. Eggs are safe at 160°F (71°C) on a thermometer — check one if your pan runs cool.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 64. `missingInternalTemperature` — data/recipes/originals · la-sheet-pan-pork-pastor · `instructions[4]`

- **Current text:** “4. Spread the pork and pineapple out — crowded pieces steam instead of char — and roast 14 minutes. Pork tenderloin is safe at 145°F (63°C); pull the pan and check a thick medallion on a thermometer.”
- **Why:** a thermometer is named but no internal temperature is stated — the check does not count without one
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 65. `metadataNotInText` — data/recipes/originals · la-sheet-pan-pork-pastor · `instructions[4]`

- **Current text:** “4. Spread the pork and pineapple out — crowded pieces steam instead of char — and roast 14 minutes. Pork tenderloin is safe at 145°F (63°C); pull the pan and check a thick medallion on a thermometer.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 66. `metadataNotInText` — data/recipes/originals · me-beef-kofte-rice-pilaf · `instructions[6]`

- **Current text:** “6. Heat the oil in the skillet over medium-high. Cook the kofte in a single layer for 9 minutes, turning every few minutes, until they crust dark brown outside. Beef is safe at 160°F (71°C); check a thicker kofte with a thermometer.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 67. `timeOnlyCooking` — data/recipes/originals · me-cilbir-yogurt-eggs · `instructions[2]`

- **Current text:** “2. Toss the red onion with the sumac and a pinch of salt in a small dish and let it macerate for 10 minutes while the eggs poach; it loses its raw bite.”
- **Trigger phrase:** eggs
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 68. `timeOnlyCooking` — data/recipes/originals · me-cilbir-yogurt-eggs · `instructions[4]`

- **Current text:** “4. While the eggs poach, melt the butter in the small skillet with the paprika and chili flakes for 1 minute, until it foams and smells nutty - pull it early; burnt paprika turns bitter.”
- **Trigger phrase:** eggs
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 69. `missingInternalTemperature` — data/recipes/originals · me-harissa-shakshuka · `instructions[3]`

- **Current text:** “3. Stir in the harissa, cumin, and smoked paprika and fry for 30 seconds, stirring constantly, until the paste darkens a shade and smells dusty-sweet rather than raw.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 70. `missingInternalTemperature` — data/recipes/originals · me-harissa-shakshuka · `instructions[8]`

- **Current text:** “8. Scatter the feta and parsley over the pan and carry it to the table as is - the feta softens from the steam rather than melting.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 71. `timeOnlyCooking` — data/recipes/originals · me-kuku-sabzi-herb-frittata · `instructions[4]`

- **Current text:** “4. Heat the oil in the ovenproof skillet over medium heat for 2 minutes, then pour in the egg mixture and spread it level.”
- **Trigger phrase:** egg
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 72. `missingInternalTemperature` — data/recipes/originals · me-kuku-sabzi-herb-frittata · `instructions[5]`

- **Current text:** “5. Cook for 4 minutes, until the edges set and lift easily with a spatula while the center still moves.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 73. `belowMinimumTemperature` — data/recipes/originals · me-kuku-sabzi-herb-frittata · `instructions[6]`

- **Current text:** “6. Transfer the pan to the oven and bake for 12 minutes, until the center is just set and puffed. The center reads 160°F (71°C) on a thermometer.”
- **Trigger phrase:** 160°f
- **Why:** 160°f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160°f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 74. `metadataNotInText` — data/recipes/originals · me-kuku-sabzi-herb-frittata · `instructions[6]`

- **Current text:** “6. Transfer the pan to the oven and bake for 12 minutes, until the center is just set and puffed. The center reads 160°F (71°C) on a thermometer.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 75. `timeOnlyCooking` — data/recipes/originals · me-moroccan-chicken-lemon-olives · `instructions[1]`

- **Current text:** “1. Season the chicken with half the salt and the black pepper. Brown it in the oil in the deep skillet over medium-high for 6 minutes, turning - the bits that stick will season the sauce. Move to a plate.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 76. `timeOnlyCooking` — data/recipes/originals · me-moroccan-chicken-lemon-olives · `instructions[3]`

- **Current text:** “3. Add the crushed tomatoes and stock and scrape the pan bottom clean. Nestle the chicken back in with any juices, cover, and simmer on medium-low for 8 minutes.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 77. `timeOnlyCooking` — data/recipes/originals · me-sheet-pan-chicken-shawarma · `instructions[2]`

- **Current text:** “2. Toss the chicken strips in the marinade to coat every surface and let them sit on the counter for 15 minutes while the oven heats.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 78. `timeOnlyCooking` — data/recipes/originals · me-sheet-pan-chicken-shawarma · `instructions[3]`

- **Current text:** “3. Spread the chicken in one uncrowded layer on the sheet pan and drag the onion slices through the leftover marinade and onto the pan. Roast for 20 minutes total, turning once halfway, until the edges char in places.”
- **Trigger phrase:** leftover
- **Required change:** Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 79. `metadataNotInText` — data/recipes/originals · me-sheet-pan-chicken-shawarma · `instructions[4]`

- **Current text:** “4. Chicken is safe at 165°F (74°C); check the thickest strip with a thermometer before pulling the pan.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 80. `missingInternalTemperature` — data/recipes/originals · me-tomato-bulgur-pilaf · `instructions[2]`

- **Current text:** “2. Add the green pepper and cook for 3 minutes more.”
- **Why:** the step cooks fried egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 81. `missingInternalTemperature` — data/recipes/originals · me-tomato-bulgur-pilaf · `instructions[6]`

- **Current text:** “6. Serve warm or at room temperature; it packs for lunch as is, or top a bowl with a fried egg and call it dinner.”
- **Why:** the step cooks fried egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 82. `reheatingWithoutThermometer` — data/recipes/originals · me-turkish-red-lentil-soup · `instructions[1]`

- **Current text:** “1. Warm the oil in the soup pot over medium heat. Cook the onion and carrots with a pinch of the salt for 8 minutes, until the onion is translucent and the carrot has softened.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 83. `reheatingWithoutThermometer` — data/recipes/originals · me-weeknight-koshari · `instructions[6]`

- **Current text:** “6. Warm the chickpeas through in the pot with a ladle of the sauce.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 84. `missingInternalTemperature` — data/recipes/originals · rw-chilli-con-carne-black-beans · `instructions[7]`

- **Current text:** “7. Simmer partially covered for 15 minutes, stirring twice, until thickened enough that a spoon leaves a brief trail.”
- **Why:** the step cooks ground beef but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 85. `metadataNotInText` — data/recipes/originals · rw-chilli-con-carne-black-beans · `instructions[8]`

- **Current text:** “8. Take the pan off the heat and check the beef crumb at its thickest with a thermometer: it must read 160°F (71°C) - ground beef's FSIS safe minimum.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 86. `reheatingWithoutThermometer` — data/recipes/originals · rw-chipotle-black-bean-burrito-bowls · `instructions[4]`

- **Current text:** “4. Build the beans in the same skillet: warm the oil over medium heat, cook the garlic for 30 seconds, add the drained beans and the glaze, and simmer for 3-4 minutes, pressing a few beans against the pan so the sauce thickens and clings.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 87. `timeOnlyCooking` — data/recipes/originals · rw-crispy-soy-potatoes-with-tuna-yogurt · `instructions[1]`

- **Current text:** “1. Prick each potato all over with a fork and microwave on full power for 10 minutes, turning once, until a paring knife slides in without resistance.”
- **Trigger phrase:** microwave
- **Required change:** Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 88. `timeOnlyCooking` — data/recipes/originals · rw-crispy-soy-potatoes-with-tuna-yogurt · `instructions[4]`

- **Current text:** “4. Bake the potatoes cut-side-up on a tray for 12 minutes until the edges crisp and the soy glaze darkens; keep an eye after minute 10, glaze can go from lacquered to burnt fast.”
- **Trigger phrase:** bake
- **Required change:** Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 89. `timeOnlyCooking` — data/recipes/originals · rw-crispy-soy-potatoes-with-tuna-yogurt · `instructions[5]`

- **Current text:** “5. While the potatoes bake, warm the vegetable oil in a skillet and wilt the spinach for 1 minute, tossing with the remaining teaspoon of soy. Pile it on a plate; it should still be glossy green, not collapsed to a thread.”
- **Trigger phrase:** bake
- **Required change:** Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 90. `metadataNotInText` — data/recipes/originals · rw-ginger-egg-fried-rice · `instructions[3]`

- **Current text:** “3. Pour in the eggs and let them puff for a few seconds, then push gently with the spatula into soft curds. If you check with a thermometer, the eggs are safe at 160°F (71°C) — they will look just set, still glossy.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 91. `timeOnlyCooking` — data/recipes/originals · rw-lime-poached-chicken-salad · `instructions[1]`

- **Current text:** “1. Poach the chicken: lay the breasts in a skillet just wide enough to hold them, add water to come halfway up their sides, and bring it to the barest simmer over medium-low heat. Cover and cook gently for 10-12 minutes, flipping once.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 92. `metadataNotInText` — data/recipes/originals · rw-lime-poached-chicken-salad · `instructions[2]`

- **Current text:** “2. The chicken is done when an instant-read thermometer pushed into the thickest part reads 165°F / 74°C. Lift it out and rest it on a board for 5 minutes, then shred with two forks; it should pull apart in soft curls.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 93. `missingInternalTemperature` — data/recipes/originals · rw-sesame-lime-chicken-salad-with-edamame · `instructions[1]`

- **Current text:** “1. Lay the chicken in a pan just wide enough to hold it, add water to cover by a thumb's width with the grated ginger, and bring to the barest simmer over medium heat - bubbles should barely break the surface.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 94. `missingInternalTemperature` — data/recipes/originals · rw-sesame-lime-chicken-salad-with-edamame · `instructions[3]`

- **Current text:** “3. Lift the chicken out to rest on a plate and pour off the poaching water - it carries no flavour worth keeping. Cook the edamame in boiling water for 4 minutes and drain.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 95. `missingInternalTemperature` — data/recipes/originals · rw-sheet-pan-satay-chicken-strips · `instructions[1]`

- **Current text:** “1. Heat the oven to 220°C (425°F) and line a sheet pan with parchment. Cut the chicken into strips about 2 cm wide so they cook evenly.”
- **Why:** 220°c is not an internal reading — the step cooks chicken with no thermometer-named check
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 96. `timeOnlyCooking` — data/recipes/originals · rw-sheet-pan-satay-chicken-strips · `instructions[3]`

- **Current text:** “3. Toss the chicken strips in the marinade and let them sit while the oven finishes heating, at least 5 minutes.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 97. `timeOnlyCooking` — data/recipes/originals · rw-sheet-pan-satay-chicken-strips · `instructions[4]`

- **Current text:** “4. Spread the strips out with space between them and bake for 10 to 12 minutes - they should take a light patchy brown at the edges.”
- **Trigger phrase:** bake
- **Required change:** Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 98. `metadataNotInText` — data/recipes/originals · rw-sheet-pan-satay-chicken-strips · `instructions[5]`

- **Current text:** “5. Check the thickest strip with a thermometer: it must read 165°F (74°C), the FSIS safe minimum for poultry. Return to the oven in 2-minute bursts if it falls short.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 99. `missingInternalTemperature` — data/recipes/originals · rw-sheet-pan-satay-chicken-strips · `instructions[6]`

- **Current text:** “6. While the chicken rests, scrape any leftover marinade into a small pan and boil it hard for 2 full minutes - raw-marinade drips are not a sauce until they have boiled.”
- **Why:** the step cooks leftover but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 100. `missingInternalTemperature` — data/recipes/originals · rw-sheet-pan-satay-chicken-strips · `instructions[8]`

- **Current text:** “8. Serve the strips on the cucumber with the boiled marinade drizzled over and the remaining lime in wedges for zesting.”
- **Why:** the step cooks leftover but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 101. `missingInternalTemperature` — data/recipes/originals · rw-skillet-taco-salad-tortilla-crisps · `instructions[1]`

- **Current text:** “1. Heat the oven to 200°C / 400°F. Brush the tortillas with half the oil, cut them into 2 cm strips, spread them on a sheet pan, and bake 4-5 minutes, turning once, until gold and crisp. They stiffen as they cool.”
- **Why:** 200°c is not an internal reading — the step cooks bake with no thermometer-named check
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 102. `appearanceDoneness` — data/recipes/originals · rw-skillet-taco-salad-tortilla-crisps · `instructions[3]`

- **Current text:** “3. Brown the beef: heat the remaining oil in a skillet over medium-high heat, add the beef and garlic, and break it up as it cooks, 6-8 minutes, until no pink remains and the crumbles are sizzling in their own fat.”
- **Trigger phrase:** no pink
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Rule:** `thermometer-only-reliable`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 103. `metadataNotInText` — data/recipes/originals · rw-skillet-taco-salad-tortilla-crisps · `instructions[4]`

- **Current text:** “4. Check the beef with an instant-read thermometer: 160°F / 71°C in the thickest clump. Browning alone can't tell you this - ground beef must reach 160°F to be safe.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS safe minimum internal temperature table), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 104. `timeOnlyCooking` — data/recipes/originals · sa-bengali-egg-curry · `instructions[3]`

- **Current text:** “3. Heat the oil in a skillet over medium. Slide the eggs in and turn them for about 2 minutes until the surfaces blister and pick up a light crust; lift them out with a slotted spoon. Timer: 2 minutes.”
- **Trigger phrase:** eggs
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 105. `missingInternalTemperature` — data/recipes/originals · sa-bengali-egg-curry · `instructions[8]`

- **Current text:** “8. Pour in the water and bring to a simmer; the gravy should be loose enough to spoon. Slip the eggs in gently.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 106. `timeOnlyCooking` — data/recipes/originals · sa-bengali-egg-curry · `instructions[9]`

- **Current text:** “9. Simmer 4 minutes so the eggs drink the gravy, spooning it over them once. Timer: 4 minutes.”
- **Trigger phrase:** eggs
- **Required change:** Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 107. `missingInternalTemperature` — data/recipes/originals · sa-chicken-aloo-keema · `instructions[5]`

- **Current text:** “5. Stir in the cumin, coriander, turmeric, cayenne, and all but a pinch of the salt; cook 30 seconds so the spices coat the meat.”
- **Why:** the step cooks ground poultry but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 108. `metadataNotInText` — data/recipes/originals · sa-chicken-aloo-keema · `instructions[8]`

- **Current text:** “8. Check doneness: take the pan off heat and spot-check the thickest crumble with a thermometer — 165°F (74°C) minimum.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 109. `timeOnlyCooking` — data/recipes/originals · sa-chicken-pulao-with-peas · `instructions[6]`

- **Current text:** “6. Add the chicken and turn the pieces in the aromatics about 3 minutes so every face loses its raw look.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 110. `metadataNotInText` — data/recipes/originals · sa-chicken-pulao-with-peas · `instructions[11]`

- **Current text:** “11. Lift one of the largest chicken pieces and check it with a thermometer — 165°F (74°C) minimum at the thickest point.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 111. `timeOnlyCooking` — data/recipes/originals · sa-sri-lankan-coconut-chicken-curry · `instructions[1]`

- **Current text:** “1. Rub the chicken with the coriander, turmeric, cayenne, and half the salt; set aside while you start the base (10 minutes is enough).”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 112. `timeOnlyCooking` — data/recipes/originals · sa-sri-lankan-coconut-chicken-curry · `instructions[5]`

- **Current text:** “5. Add the chicken with all its rub and cook about 5 minutes, turning the pieces, until their outsides whiten and the spices toast. Timer: 5 minutes.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 113. `timeOnlyCooking` — data/recipes/originals · sa-sri-lankan-coconut-chicken-curry · `instructions[7]`

- **Current text:** “7. Cover partially and simmer about 15 minutes, stirring once, until the curry thickens to a thin-gravy coat and the chicken is firm through. Timer: 15 minutes.”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 114. `metadataNotInText` — data/recipes/originals · sa-sri-lankan-coconut-chicken-curry · `instructions[8]`

- **Current text:** “8. Check a large piece with a thermometer — 165°F (74°C) minimum at the thickest point.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/
