# Fix list — PR #107 (overhaul/original-recipes — 101-original corpus (originals.jsonl))

Branch `overhaul/original-recipes` · PR head pinned at `607ef996e685ed250c0c0036690736587fddf728` · linted 2026-10-12 · **401 records, 322 findings**. Linter: `fl-safety-lint` built from the canon branch at `299ff32` (`packages/FLFoodSafety`); this task added no linter code.

## Extraction (provenance)

Every record of `data/recipes/originals/originals.jsonl` becomes one recipe record: `steps[].text` join as newline-numbered instructions (`1. …`), each step's structured `safety` object becomes `safety_fields[zero-based step index]`, ingredient names join into `ingredients`. All text verbatim from the branch head; nothing reworded. 401 records (231 carry safety_fields).

Extraction scripts (deterministic; run against a checkout of the head above; scratch copies: `extract/kit.py` + `extract/x_corpus.py` — the per-target script imports the shared kit for the leaf-block HTML extractor, the keyword screen and the record builders):

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
# ---- x_corpus.py ----
#!/usr/bin/env python3
"""Extract recipe records from the RS JSONL corpora (PRs #107, #113).

Faithful mapping: every record becomes one recipe record. steps[] join as
newline-numbered instructions ("1. ..."), each step's structured `safety`
object (if present) becomes safety_fields[zero-based index]. Text is quoted
verbatim; nothing is fixed or reworded.
"""
import json, sys, os, subprocess
sys.path.insert(0, os.path.dirname(__file__))
from kit import records_file, recipe_record, write

def extract(jsonl_path, src_label, out_path, ref, description):
    sha = subprocess.run(["git", "rev-parse", ref], capture_output=True, text=True,
                         cwd="/home/user/work/fs-canon-p5/clone").stdout.strip()
    records = []
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            steps = [s.get("text", "") for s in r.get("steps", [])]
            safety = {}
            for i, s in enumerate(r.get("steps", [])):
                if isinstance(s.get("safety"), dict):
                    safety[i] = s["safety"]
            ingredients = ", ".join(
                ing.get("name", "") for ing in r.get("ingredients", [])
                if isinstance(ing, dict) and ing.get("name"))
            records.append(recipe_record(
                file=src_label, id=r["id"], title=r.get("title", ""),
                ingredients=ingredients, steps=steps, safety_fields=safety))
    doc = records_file(description, records)
    write(out_path, doc)
    n_safety = sum(1 for r in records if r.get("safety_fields"))
    print(f"{out_path}: {len(records)} recipe records from {src_label} "
          f"({n_safety} with safety_fields; head {sha})")

if __name__ == "__main__":
    base = "/home/user/work/fs-canon-p5"
    os.makedirs(f"{base}/records", exist_ok=True)
    extract(f"{base}/targets/p107/data/recipes/originals/originals.jsonl",
            "data/recipes/originals/originals.jsonl",
            f"{base}/records/p107-original-recipes.json",
            "p5/p107",
            "PR #107 (overhaul/original-recipes) originals.jsonl - steps and per-step safety metadata verbatim")
    extract(f"{base}/targets/p113/data/recipes/corpus.jsonl",
            "data/recipes/corpus.jsonl",
            f"{base}/records/p113-recipe-corpus-v2.json",
            "p5/p113",
            "PR #113 (fleet/fl-recipe-corpus-v2) corpus.jsonl - 428-record corpus, steps and per-step safety metadata verbatim")

```

## Reproduce the lint

```sh
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json> --json   # machine output
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json>        # human output
```

The `<records.json>` file is `p107-original-recipes.json` in the canon task's scratch — the extraction output described above (401 records, shape per `data/food-safety/conformance/README.md`). Rerunning the extraction scripts on the same head reproduces it byte-for-byte.

Field convention: `instructions[N]` is the Nth numbered line of the extracted instructions string; for a source `steps[]` array the zero-based array index is N−1 (verified against `fl-original-0026`, a 4-step record whose reheat step is line 4 and array index 3).

## Findings by kind

| kind | count |
|---|---|
| `appearanceDoneness` | 2 |
| `belowMinimumTemperature` | 12 |
| `flagForReview` | 11 |
| `metadataNotInText` | 143 |
| `missingInternalTemperature` | 106 |
| `missingRestTime` | 2 |
| `missingThermometer` | 22 |
| `rawEggNoWarning` | 4 |
| `reheatingWithoutThermometer` | 19 |
| `timeOnlyCooking` | 1 |

Total: **322 findings** over 401 records.

## Findings

#### 1. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0003 · `instructions[1]`

- **Current text:** “1. Whisk the flour, sugar, baking powder and salt in a large bowl.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 2. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0004 · `instructions[4]`

- **Current text:** “4. Bake until puffed and the centres read 160 °F on an instant-read thermometer.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 3. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0004 · `instructions[4]`

- **Current text:** “4. Bake until puffed and the centres read 160 °F on an instant-read thermometer.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 4. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0004 · `instructions[5]`

- **Current text:** “5. Rest 2 minutes, run a thin knife around each muffin and lift out. Reheat any extras to 165 °F before serving.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 5. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0004 · `instructions[5]`

- **Current text:** “5. Rest 2 minutes, run a thin knife around each muffin and lift out. Reheat any extras to 165 °F before serving.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 6. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0005 · `instructions[3]`

- **Current text:** “3. Meanwhile, warm the tortillas in a dry pan or wrapped in foil in the oven and set aside.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 7. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0005 · `instructions[5]`

- **Current text:** “5. Load the tortillas with the scramble, shower with cheddar and a few drops of hot sauce, and fold. Reheat any second-round tacos to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 8. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0005 · `instructions[5]`

- **Current text:** “5. Load the tortillas with the scramble, shower with cheddar and a few drops of hot sauce, and fold. Reheat any second-round tacos to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 9. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0006 · `instructions[4]`

- **Current text:** “4. Spread in the pan and bake until set in the centre and an instant-read thermometer reads 160 °F.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 10. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0006 · `instructions[4]`

- **Current text:** “4. Spread in the pan and bake until set in the centre and an instant-read thermometer reads 160 °F.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 11. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0006 · `instructions[5]`

- **Current text:** “5. Cool 10 minutes before cutting into squares; wrap extras and reheat to 165 °F on busy mornings.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 12. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0006 · `instructions[5]`

- **Current text:** “5. Cool 10 minutes before cutting into squares; wrap extras and reheat to 165 °F on busy mornings.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 13. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0007 · `instructions[3]`

- **Current text:** “3. Bake until the custard is set and an instant-read thermometer in the centre reads 160 °F.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 14. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0007 · `instructions[3]`

- **Current text:** “3. Bake until the custard is set and an instant-read thermometer in the centre reads 160 °F.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 15. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0007 · `instructions[4]`

- **Current text:** “4. Spoon into portions and pour a little more warm maple syrup over each. Leftover squares reheat to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 16. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0007 · `instructions[4]`

- **Current text:** “4. Spoon into portions and pour a little more warm maple syrup over each. Leftover squares reheat to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 17. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0008 · `instructions[2]`

- **Current text:** “2. Bake the potato layer alone until it just starts to colour at the edges.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 18. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0008 · `instructions[5]`

- **Current text:** “5. Bake until the centre reads 160 °F on an instant-read thermometer and the top is lightly puffed.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 19. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0008 · `instructions[5]`

- **Current text:** “5. Bake until the centre reads 160 °F on an instant-read thermometer and the top is lightly puffed.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 20. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0008 · `instructions[6]`

- **Current text:** “6. Rest 10 minutes, cut into squares, and serve. Reheat portions to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 21. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0008 · `instructions[6]`

- **Current text:** “6. Rest 10 minutes, cut into squares, and serve. Reheat portions to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 22. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0014 · `instructions[4]`

- **Current text:** “4. Pan-fry in the remaining oil over medium heat, flipping once, until crusty and an instant-read thermometer in a patty centre reads 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 23. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0014 · `instructions[5]`

- **Current text:** “5. Serve on buns with pickles and mustard. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 24. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0014 · `instructions[5]`

- **Current text:** “5. Serve on buns with pickles and mustard. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 25. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0015 · `instructions[5]`

- **Current text:** “5. Ladle into bowls and finish with sliced green onions. Reheat leftovers to a full simmer, 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 26. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0015 · `instructions[5]`

- **Current text:** “5. Ladle into bowls and finish with sliced green onions. Reheat leftovers to a full simmer, 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 27. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0016 · `instructions[5]`

- **Current text:** “5. Reheat leftovers to a full simmer, 165 °F, before serving.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 28. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0016 · `instructions[5]`

- **Current text:** “5. Reheat leftovers to a full simmer, 165 °F, before serving.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 29. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0017 · `instructions[5]`

- **Current text:** “5. Reheat any extras to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 30. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0017 · `instructions[5]`

- **Current text:** “5. Reheat any extras to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 31. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0018 · `instructions[5]`

- **Current text:** “5. Add the noodles and cook until just tender, then taste for salt. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 32. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0018 · `instructions[5]`

- **Current text:** “5. Add the noodles and cook until just tender, then taste for salt. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 33. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0023 · `instructions[2]`

- **Current text:** “2. Sear the steak hard, undisturbed, then flip and add the butter, garlic and rosemary, basting as the butter foams.”
- **Why:** the step cooks steak but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 34. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0023 · `instructions[3]`

- **Current text:** “3. Take the steak off at 140 °F on an instant-read thermometer — it climbs to the 145 °F FSIS minimum as it rests — and rest it on a board.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 35. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0024 · `instructions[2]`

- **Current text:** “2. Sear the chicken in a hot oiled skillet, then flip and cook through to 165 °F on an instant-read thermometer. Move to a board and slice.”
- **Why:** a thermometer is named but no internal temperature is stated — the check does not count without one
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 36. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0024 · `instructions[2]`

- **Current text:** “2. Sear the chicken in a hot oiled skillet, then flip and cook through to 165 °F on an instant-read thermometer. Move to a board and slice.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 37. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0024 · `instructions[3]`

- **Current text:** “3. Steam or blanch the broccoli until bright and just tender.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 38. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0025 · `instructions[2]`

- **Current text:** “2. Sear in a screaming-hot cast-iron skillet with a film of oil, about three minutes a side, until the thickest part reads 145 °F on an instant-read thermometer.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 39. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0026 · `instructions[3]`

- **Current text:** “3. Nestle the thighs among the potatoes and roast until the chicken reads 165 °F at the thickest point and the potatoes are crusty.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 40. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0026 · `instructions[3]`

- **Current text:** “3. Nestle the thighs among the potatoes and roast until the chicken reads 165 °F at the thickest point and the potatoes are crusty.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 41. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0026 · `instructions[4]`

- **Current text:** “4. Rest five minutes, scatter thyme over the pan and serve straight from it. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 42. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0026 · `instructions[4]`

- **Current text:** “4. Rest five minutes, scatter thyme over the pan and serve straight from it. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 43. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0027 · `instructions[2]`

- **Current text:** “2. Lay the sausages on top and roast, turning everything once halfway, until the sausages read 160 °F on an instant-read thermometer and the cabbage is charred at the fringes.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 44. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0027 · `instructions[2]`

- **Current text:** “2. Lay the sausages on top and roast, turning everything once halfway, until the sausages read 160 °F on an instant-read thermometer and the cabbage is charred at the fringes.”
- **Why:** the step names a protein ("2. Lay the sausages on top and roast, turning everything once halfway, until the sausages read 160 °F on an instant-read thermometer and the cabbage is charred at the fringes.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 45. `timeOnlyCooking` — data/recipes/originals/originals.jsonl · fl-original-0028 · `instructions[3]`

- **Current text:** “3. Form into a loaf on a lined sheet pan and bake 20 minutes.”
- **Trigger phrase:** bake
- **Required change:** Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 46. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0028 · `instructions[4]`

- **Current text:** “4. Stir the ketchup with the brown sugar and brush half over the loaf; bake until the centre reads 160 °F on an instant-read thermometer, glazing again halfway.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 47. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0028 · `instructions[4]`

- **Current text:** “4. Stir the ketchup with the brown sugar and brush half over the loaf; bake until the centre reads 160 °F on an instant-read thermometer, glazing again halfway.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 48. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0028 · `instructions[5]`

- **Current text:** “5. Rest 10 minutes before slicing. Reheat slices to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 49. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0028 · `instructions[5]`

- **Current text:** “5. Rest 10 minutes before slicing. Reheat slices to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 50. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0030 · `instructions[1]`

- **Current text:** “1. Brown the beef with the diced onion in a wide pot, breaking it up, until no longer pink and an instant-read thermometer reads 160 °F.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 51. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0030 · `instructions[4]`

- **Current text:** “4. Fold in the corn, warm through, and season with salt and pepper. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 52. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0030 · `instructions[4]`

- **Current text:** “4. Fold in the corn, warm through, and season with salt and pepper. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 53. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0031 · `instructions[5]`

- **Current text:** “5. Rest five minutes on the rack so the crust stays crisp. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 54. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0031 · `instructions[5]`

- **Current text:** “5. Rest five minutes on the rack so the crust stays crisp. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 55. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0032 · `instructions[4]`

- **Current text:** “4. Simmer gently until the chops read 145 °F on an instant-read thermometer, then rest them 3 minutes — the temperature holds at the FSIS minimum — and swirl the butter into the pan sauce.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 56. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0033 · `instructions[3]`

- **Current text:** “3. Stir in the chili powder, cumin and smoked paprika, then the tomatoes; half-cover and simmer so the flavours melt together.”
- **Why:** the step cooks ground beef but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 57. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0033 · `instructions[5]`

- **Current text:** “5. Serve with shredded cheddar and pickled jalapeños; reheated bowls go to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 58. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0033 · `instructions[5]`

- **Current text:** “5. Serve with shredded cheddar and pickled jalapeños; reheated bowls go to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 59. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0034 · `instructions[4]`

- **Current text:** “4. Braise until a fork twists into the meat with no resistance and an instant-read thermometer reads well past the 145 °F FSIS minimum for beef.”
- **Trigger phrase:** 145 °f
- **Why:** 145 °f is below the class minimum 165 °F (74 °C) for leftovers (rule leftovers-reheat-165)
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — 145 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 60. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0034 · `instructions[4]`

- **Current text:** “4. Braise until a fork twists into the meat with no resistance and an instant-read thermometer reads well past the 145 °F FSIS minimum for beef.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 61. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0034 · `instructions[6]`

- **Current text:** “6. Rest the roast, whisk the cornstarch into the skimmed pan liquid to make gravy, and serve in wide slices. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 62. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0034 · `instructions[6]`

- **Current text:** “6. Rest the roast, whisk the cornstarch into the skimmed pan liquid to make gravy, and serve in wide slices. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 63. `missingRestTime` — data/recipes/originals/originals.jsonl · fl-original-0035 · `instructions[2]`

- **Current text:** “2. Line the slow cooker with the sliced onions and lay the pork on top; cover and cook on low until the meat collapses when prodded and an instant-read thermometer reads far past the 145 °F FSIS minimum for fresh pork.”
- **Why:** the class requires a 3-minute rest (rule whole-cut-pork-145-rest-3) that the text does not state
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 64. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0035 · `instructions[2]`

- **Current text:** “2. Line the slow cooker with the sliced onions and lay the pork on top; cover and cook on low until the meat collapses when prodded and an instant-read thermometer reads far past the 145 °F FSIS minimum for fresh pork.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 65. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0035 · `instructions[3]`

- **Current text:** “3. Lift the pork out, skim the fat from the cooking liquid, and reduce the liquid on the stove with the vinegar into a sharp jus.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 66. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0035 · `instructions[4]`

- **Current text:** “4. Shred the pork with two forks, moisten with the jus, and pile onto toasted buns. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 67. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0035 · `instructions[4]`

- **Current text:** “4. Shred the pork with two forks, moisten with the jus, and pile onto toasted buns. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 68. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0036 · `instructions[1]`

- **Current text:** “1. Season the thighs and sear in an oiled skillet until well browned; remove.”
- **Why:** the step cooks reheat leftovers but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 69. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0036 · `instructions[4]`

- **Current text:** “4. Scatter the cheddar over, cover until melted, and serve with the chips crushed over the top. Reheat leftovers to 165 °F.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 70. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0036 · `instructions[4]`

- **Current text:** “4. Scatter the cheddar over, cover until melted, and serve with the chips crushed over the top. Reheat leftovers to 165 °F.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 71. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0040 · `instructions[1]`

- **Current text:** “1. Warm the turkey slices in a covered pan with a splash of stock until steaming and 165 °F on an instant-read thermometer.”
- **Why:** a thermometer is named but no internal temperature is stated — the check does not count without one
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 72. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0040 · `instructions[1]`

- **Current text:** “1. Warm the turkey slices in a covered pan with a splash of stock until steaming and 165 °F on an instant-read thermometer.”
- **Why:** the record's safety field states class leftovers at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 73. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0041 · `instructions[2]`

- **Current text:** “2. Whisk the cornmeal, flour, sugar, baking powder and salt; beat in the milk and egg.”
- **Why:** the step cooks egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 74. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0041 · `instructions[3]`

- **Current text:** “3. Pour into the hot skillet and bake until a skewer comes out clean and the centre reads 160 °F on an instant-read thermometer.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 75. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0041 · `instructions[3]`

- **Current text:** “3. Pour into the hot skillet and bake until a skewer comes out clean and the centre reads 160 °F on an instant-read thermometer.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 76. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0050 · `instructions[4]`

- **Current text:** “4. Stir in the beans to warm through, check the beef reads 160 °F on a thermometer, season and serve.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 77. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0054 · `instructions[4]`

- **Current text:** “4. Stir the remaining yogurt and the cream into the sauce off the boil, tuck in the charred chicken, warm through and serve with rice.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 78. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0055 · `instructions[3]`

- **Current text:** “3. Deglaze with the tomatoes and stock, add the honey and apricots, then return the chicken, cover, and braise gently.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 79. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0055 · `instructions[4]`

- **Current text:** “4. Scatter in the olives for the last stretch so they stay bright; confirm the chicken reads 165 °F on a thermometer.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 80. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0056 · `instructions[2]`

- **Current text:** “2. Meanwhile warm the remaining oil with the sliced garlic and chili flakes over low heat until the garlic barely turns blonde, then pour in the tomatoes and simmer into a glossy, spicy sauce.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 81. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0057 · `instructions[3]`

- **Current text:** “3. Add the beef and brown it through, breaking clumps, until a thermometer reads 160 °F.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 82. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0060 · `instructions[2]`

- **Current text:** “2. Warm the stock with the garlic; whisk the miso and soy sauce in a ladleful of hot broth until smooth, then pour it back — never boil the miso hard or it goes flat.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 83. `rawEggNoWarning` — data/recipes/originals/originals.jsonl · fl-original-0061 · `instructions[1]`

- **Current text:** “1. Beat the eggs with the milk, turmeric, finely diced onion, chili and chopped cilantro until uniform and frothy.”
- **Required change:** Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-egg-recipes-pasteurized`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 84. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0061 · `instructions[2]`

- **Current text:** “2. Melt the butter in a nonstick skillet and pour in the eggs; cook over medium-low, lifting the edges and tilting the pan so the raw egg runs underneath.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 85. `rawEggNoWarning` — data/recipes/originals/originals.jsonl · fl-original-0061 · `instructions[2]`

- **Current text:** “2. Melt the butter in a nonstick skillet and pour in the eggs; cook over medium-low, lifting the edges and tilting the pan so the raw egg runs underneath.”
- **Required change:** Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-egg-recipes-pasteurized`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 86. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0061 · `instructions[3]`

- **Current text:** “3. Fold when the center just sets — a thermometer in the thickest part reads 160 °F — and slide onto plates.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 87. `appearanceDoneness` — data/recipes/originals/originals.jsonl · fl-original-0068 · `instructions[2]`

- **Current text:** “2. Fry the onion in the oil until golden, then the garlic, ginger and garam masala until fragrant.”
- **Trigger phrase:** golden
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Rule:** `thermometer-only-reliable`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 88. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0068 · `instructions[3]`

- **Current text:** “3. Stir in the spinach purée and simmer gently so the color stays green and the rawness cooks off.”
- **Why:** the step cooks reheat but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 89. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0068 · `instructions[4]`

- **Current text:** “4. Off the heat, whisk in the yogurt, then fold in the seared paneer cubes and warm through — a boil would toughen the cheese.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 90. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0073 · `instructions[3]`

- **Current text:** “3. Bake until the center is set and puffed, with a thermometer reading 160 °F.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 91. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0073 · `instructions[3]`

- **Current text:** “3. Bake until the center is set and puffed, with a thermometer reading 160 °F.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 92. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0076 · `instructions[4]`

- **Current text:** “4. Bake at 425 °F until bubbling at the edges and blistered gold on top; rest briefly and finish with basil.”
- **Why:** 425 °f is not an internal reading — the step cooks bake with no thermometer-named check
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 93. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0078 · `instructions[4]`

- **Current text:** “4. Boil the pan sauce down hard, spoon it over the chicken and rest a few minutes before serving.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 94. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0080 · `instructions[1]`

- **Current text:** “1. Brown the chicken hard in the oil and set aside; cook the onion in the same pot until it catches gold edges.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 95. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0080 · `instructions[3]`

- **Current text:** “3. Cover and braise on the lowest simmer until the chicken reads 165 °F and yields easily to a fork.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 96. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0080 · `instructions[3]`

- **Current text:** “3. Cover and braise on the lowest simmer until the chicken reads 165 °F and yields easily to a fork.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 97. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0084 · `instructions[4]`

- **Current text:** “4. Warm the pitas, line them with shredded lettuce and tomato, spoon in the crisp chickpeas and drown the seam in tahini sauce.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 98. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0088 · `instructions[2]`

- **Current text:** “2. Scramble the eggs slowly in the butter, folding from the edges, pulling the pan off the heat before they look done — carryover finishes them.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 99. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0088 · `instructions[3]`

- **Current text:** “3. Check the eggs read 160 °F, then fold in most of the sauce and pile onto warmed tortillas with the rest of the sauce, cheddar and cilantro over.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 100. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0090 · `instructions[2]`

- **Current text:** “2. Squeeze the chorizo from its skins into the pan and cook until the fat runs red-orange and the meat crisps into crumbles.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 101. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0090 · `instructions[4]`

- **Current text:** “4. Warm the tortillas, fill with the scramble and finish with cilantro and lime.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 102. `missingRestTime` — data/recipes/originals/originals.jsonl · fl-original-0094 · `instructions[3]`

- **Current text:** “3. Cover and braise on the lowest heat until the pork reads 145 °F with a thermometer and shreds under a fork.”
- **Why:** the class requires a 3-minute rest (rule whole-cut-pork-145-rest-3) that the text does not state
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 103. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0094 · `instructions[3]`

- **Current text:** “3. Cover and braise on the lowest heat until the pork reads 145 °F with a thermometer and shreds under a fork.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 104. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0094 · `instructions[4]`

- **Current text:** “4. Meanwhile cook the rice. Shred the pork into the citrus pan sauce and serve over the rice with the cooking lime halves squeezed over.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 105. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0095 · `instructions[1]`

- **Current text:** “1. Reheat the rice and divide between warm bowls.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 106. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0095 · `instructions[2]`

- **Current text:** “2. Scramble the eggs in the butter over low heat, dragging constantly into soft curds, pulling the pan off the heat while they still glisten.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 107. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0095 · `instructions[3]`

- **Current text:** “3. Check 160 °F with a thermometer, then spoon the eggs over the rice and finish with soy, scallions and sesame oil.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 108. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0099 · `instructions[1]`

- **Current text:** “1. Brown the beef hard in the oil without stirring too much, so crusty edges form; a thermometer should read 160 °F.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 109. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0102 · `instructions[3]`

- **Current text:** “3. Boil the pasta one minute short of the package time, drain, and fold it into the sauce with the tuna in rough flakes and the peas straight from the freezer.”
- **Why:** the step cooks tuna but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 110. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0102 · `instructions[4]`

- **Current text:** “4. Top with the cheddar and bake until the edges bubble and the cheese runs lacquered.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 111. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0102 · `instructions[4]`

- **Current text:** “4. Top with the cheddar and bake until the edges bubble and the cheese runs lacquered.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 112. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0105 · `instructions[1]`

- **Current text:** “1. Lower the chicken into a pan of barely simmering water, cover, and let it poach gently off the boil.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 113. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0105 · `instructions[2]`

- **Current text:** “2. Check the thickest breast with a food thermometer at 165 °F before lifting it out to rest; the poaching liquid stays behind as a light stock.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 114. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0107 · `instructions[2]`

- **Current text:** “2. Cook the eggplant cubes in that bacon fat over real heat, stirring only when they catch, until they collapse into softness.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 115. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0107 · `instructions[2]`

- **Current text:** “2. Cook the eggplant cubes in that bacon fat over real heat, stirring only when they catch, until they collapse into softness.”
- **Why:** the step names a protein ("2. Cook the eggplant cubes in that bacon fat over real heat, stirring only when they catch, until they collapse into softness.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 116. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0109 · `instructions[3]`

- **Current text:** “3. Beat the eggs with salt, pour them over the vegetables, and cook on the lowest heat, lifting the edges as they set so the raw egg runs underneath.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 117. `rawEggNoWarning` — data/recipes/originals/originals.jsonl · fl-original-0109 · `instructions[3]`

- **Current text:** “3. Beat the eggs with salt, pour them over the vegetables, and cook on the lowest heat, lifting the edges as they set so the raw egg runs underneath.”
- **Required change:** Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-egg-recipes-pasteurized`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 118. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0109 · `instructions[4]`

- **Current text:** “4. Set the pan under the broiler for the last stretch, watching it rise and souffle.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 119. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0111 · `instructions[4]`

- **Current text:** “4. Sear the chicken in the rest of the oil over medium-high heat, deeply crusted outside, then move the pan off the flame and let it finish gently.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 120. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0111 · `instructions[5]`

- **Current text:** “5. A food thermometer in the thickest piece should read 165 °F before the chicken rests; slice it across the grain and plate against the beans and guacamole.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 121. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0113 · `instructions[3]`

- **Current text:** “3. Add the chicken in thick slices and sear hard on one side, then turn when the crust releases easily.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 122. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0118 · `instructions[5]`

- **Current text:** “5. Shred the chicken roughly into the sauce, toss with the cooked rigatoni and a splash of pasta water, and finish with lemon zest and parsley.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 123. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0119 · `instructions[1]`

- **Current text:** “1. Season the chicken with salt and half the cumin; sear it in the oil in a wide pan until a deep crust builds, then lift it out.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 124. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0121 · `instructions[1]`

- **Current text:** “1. Get the pan properly hot, add the oil, and sear the chicken strips flat in one layer without moving them for a full minute.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 125. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0121 · `instructions[2]`

- **Current text:** “2. Toss until the pieces lose their pink raw look — a food thermometer should read 165 °F at the thickest point — then lift them out.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 126. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0122 · `instructions[3]`

- **Current text:** “3. Griddle the skewers on real heat, turning once, until the crust blisters and a food thermometer reads 165 °F at the thickest point.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 127. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0123 · `instructions[2]`

- **Current text:** “2. Let the mushrooms sit undisturbed in that fat until they squeak and sear, then stir and let them do it again.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 128. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0124 · `instructions[5]`

- **Current text:** “5. Set the cutlets into the sauce, top with the mozzarella and parmesan, cover, and let the cheese melt into a molten blanket while the chicken settles at 165 °F on a food thermometer.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 129. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0125 · `instructions[2]`

- **Current text:** “2. Rub the chicken with the curry powder and salt and sear in the oil over strong heat, turning when the crust takes hold.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 130. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0125 · `instructions[3]`

- **Current text:** “3. Check the thickest piece with a food thermometer for 165 °F, then rest it five minutes before slicing thin.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 131. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0126 · `instructions[3]`

- **Current text:** “3. Cook in the oil over medium-high heat until deeply crusted and a food thermometer reads 165 °F; rest five minutes.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 132. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0126 · `instructions[4]`

- **Current text:** “4. Warm the tortillas in the empty pan, stacking them under a towel to steam soft.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 133. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0127 · `instructions[5]`

- **Current text:** “5. Return the chicken with the peas, warm through, and serve over the rice with the green onion tops scattered.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 134. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0129 · `instructions[1]`

- **Current text:** “1. Toss the mango, avocado, cucumber and onion whites with the lime juice and salt; let the salsa sit while the fish cooks.”
- **Why:** the step cooks fish but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 135. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0129 · `instructions[2]`

- **Current text:** “2. Pat the cod very dry, season, and sear in the oil over medium-high without moving it, letting the underside build a crust.”
- **Why:** the step cooks cod but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 136. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0129 · `instructions[3]`

- **Current text:** “3. Turn once and finish until the fillets flake in thick petals and read 145 °F on a food thermometer at the centre.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 137. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0130 · `instructions[3]`

- **Current text:** “3. Add the crab with a ladle of pasta water and fold it through warm; it needs heat, not cooking.”
- **Why:** the step cooks crab but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the thickest piece reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-shellfish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 138. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0130 · `instructions[3]`

- **Current text:** “3. Add the crab with a ladle of pasta water and fold it through warm; it needs heat, not cooking.”
- **Why:** the record's safety field states class flesh_shellfish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the thickest piece reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-shellfish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 139. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0134 · `instructions[3]`

- **Current text:** “3. Set the cod fillets into the sauce and poach gently, spooning the curry over, until the flakes part in thick petals and read 145 °F at the centre.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 140. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0134 · `instructions[3]`

- **Current text:** “3. Set the cod fillets into the sauce and poach gently, spooning the curry over, until the flakes part in thick petals and read 145 °F at the centre.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 141. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0135 · `instructions[4]`

- **Current text:** “4. Return the thighs and turn them in the glaze over low heat until lacquered and reading 165 °F on a food thermometer.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 142. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0137 · `instructions[1]`

- **Current text:** “1. Season the duck legs hard and sear them in the oil in a heavy pot until the skin renders and turns amber; lift them out.”
- **Why:** the step cooks duck but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 143. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0137 · `instructions[3]`

- **Current text:** “3. Return the duck with the tomatoes, stock and thyme, cover, and braise on the lowest heat until the meat gives up on the bone.”
- **Why:** the step cooks duck but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 144. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0137 · `instructions[4]`

- **Current text:** “4. Lift out the duck, shred the meat, skim the fat from the sauce, and return the meat with the swede; simmer until the swede slumps into the gravy.”
- **Why:** the step cooks duck but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 145. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0137 · `instructions[4]`

- **Current text:** “4. Lift out the duck, shred the meat, skim the fat from the sauce, and return the meat with the swede; simmer until the swede slumps into the gravy.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 146. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0138 · `instructions[3]`

- **Current text:** “3. Scatter the peas over, then the shrimp on top of the rice in one layer, and re-cover; the steam does the cooking.”
- **Why:** the step cooks shrimp but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the thickest piece reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-shellfish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 147. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0138 · `instructions[4]`

- **Current text:** “4. Check the shrimp at 145 °F with a food thermometer — they should be opaque and just curled; overdone shrimp are a crime against the dish.”
- **Why:** the record's safety field states class flesh_shellfish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the thickest piece reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-shellfish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 148. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0139 · `instructions[1]`

- **Current text:** “1. Crisp the bacon in the oil in a wide pan until it leans dark and the fat has rendered; lift out, keep the fat.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 149. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0140 · `instructions[2]`

- **Current text:** “2. Scramble the eggs in the hot oiled pan until they are just set in soft curds; slide out.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 150. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0140 · `instructions[2]`

- **Current text:** “2. Scramble the eggs in the hot oiled pan until they are just set in soft curds; slide out.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 151. `missingThermometer` — data/recipes/originals/originals.jsonl · fl-original-0141 · `instructions[5]`

- **Current text:** “5. Bake the salmon at 400 °F until it flakes and reads 145 °F at the centre of the thickest fillet.”
- **Why:** an internal temperature at or above the minimum is stated, but no food thermometer is named in the text
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — a stated temperature counts only when a thermometer verifies it. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 152. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0141 · `instructions[5]`

- **Current text:** “5. Bake the salmon at 400 °F until it flakes and reads 145 °F at the centre of the thickest fillet.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 153. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0146 · `instructions[4]`

- **Current text:** “4. Pour in the milk at the end and let it bubble into the sauce — the old trick that rounds the acidity.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 154. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0146 · `instructions[5]`

- **Current text:** “5. Toss with the fresh-cooked tagliatelle and eat with parmesan if you keep it.”
- **Why:** the step cooks ground beef but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 155. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0147 · `instructions[1]`

- **Current text:** “1. Season the chicken with cumin, paprika and salt; cook in the oil until crusty outside and 165 °F on a food thermometer inside. Rest, then dice.”
- **Why:** a thermometer is named but no internal temperature is stated — the check does not count without one
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 156. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0147 · `instructions[1]`

- **Current text:** “1. Season the chicken with cumin, paprika and salt; cook in the oil until crusty outside and 165 °F on a food thermometer inside. Rest, then dice.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 157. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0147 · `instructions[3]`

- **Current text:** “3. Warm the rice with the lime juice and salt.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 158. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0148 · `instructions[4]`

- **Current text:** “4. Scramble the eggs in the empty half of the pan until barely set.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 159. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0148 · `instructions[4]`

- **Current text:** “4. Scramble the eggs in the empty half of the pan until barely set.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 160. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0149 · `instructions[2]`

- **Current text:** “2. Season the chicken and sear it in an ovenproof pan over medium-high, two or three minutes a side; lift out and rest it, then cut in thick slices.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 161. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0149 · `instructions[4]`

- **Current text:** “4. Tuck the chicken slices into the pasta, cover with mozzarella, and bake until the top blisters and bubbles.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 162. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0149 · `instructions[4]`

- **Current text:** “4. Tuck the chicken slices into the pasta, cover with mozzarella, and bake until the top blisters and bubbles.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 163. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0149 · `instructions[5]`

- **Current text:** “5. Let it stand ten minutes or the bake will slide; it firms as it cools.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 164. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0158 · `instructions[3]`

- **Current text:** “3. Slide the pan under the broiler until the frittata puffs and a food thermometer at the centre reads 160 °F.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 165. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0160 · `instructions[2]`

- **Current text:** “2. Fry the chipotle and cumin in the pan, add the stock, quinoa and beans, and nestle the chicken back in.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 166. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0160 · `instructions[3]`

- **Current text:** “3. Simmer, covered, until the quinoa curls its little tails and a food thermometer through the thickest breast reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 167. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0161 · `instructions[2]`

- **Current text:** “2. Warm the garlic and chili flakes in the oil, add the tomatoes, and let the sauce lose its raw edge and gloss.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 168. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0169 · `instructions[3]`

- **Current text:** “3. Return the beef, add the garlic, the stock and the cornstarch slaked in a little cold stock, and simmer to a gravy that clings.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 169. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0170 · `instructions[3]`

- **Current text:** “3. Pour in the stock, return the thighs skin-up, and simmer covered until the grains swell and a food thermometer beside the bone reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 170. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0171 · `instructions[1]`

- **Current text:** “1. Brown the beef in the oil in a wide pan, letting it sit undisturbed long enough to crust, then push it aside and soften the pepper and green onions.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 171. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0176 · `instructions[3]`

- **Current text:** “3. Bake until the sausages have taken colour and a food thermometer through one reads 160 °F, tucking the bread in for the last five minutes.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 172. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0176 · `instructions[3]`

- **Current text:** “3. Bake until the sausages have taken colour and a food thermometer through one reads 160 °F, tucking the bread in for the last five minutes.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 173. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0178 · `instructions[3]`

- **Current text:** “3. Fry the patties in the oil, four or five minutes a side, until a food thermometer at the centre reads 145 °F.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 174. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0183 · `instructions[2]`

- **Current text:** “2. Warm the sliced garlic and chili in the oil, add the tomatoes, and cook until the sauce loses its raw edge.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 175. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0185 · `instructions[1]`

- **Current text:** “1. Brown the sausage meat in the oil, breaking it into pebbles, until the fat runs clear.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 176. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0185 · `instructions[2]`

- **Current text:** “2. Soften the green onions and garlic in the sausage fat, add the tomatoes, and cook down ten minutes.”
- **Why:** the step names a protein ("2. Soften the green onions and garlic in the sausage fat, add the tomatoes, and cook down ten minutes.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 177. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0186 · `instructions[1]`

- **Current text:** “1. Start the rice in salted water; cover and cook while the fish rests seasoned on the counter.”
- **Why:** the step cooks fish but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 178. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0186 · `instructions[2]`

- **Current text:** “2. Sear the fillets skin-down in half the oil, pressing flat, then turn once and cook until a food thermometer at the centre reads 145 °F.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 179. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0187 · `instructions[3]`

- **Current text:** “3. Boil the edamame three minutes and drain; slice the tomatoes and halve the cucumber lengthwise, then into moons.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 180. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0195 · `instructions[1]`

- **Current text:** “1. Prick the potatoes, rub with salt, and bake directly on the rack until a skewer slides through with no resistance.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 181. `appearanceDoneness` — data/recipes/originals/originals.jsonl · fl-original-0200 · `instructions[3]`

- **Current text:** “3. Scatter the bread crumbs over, drizzle with a little more oil, and bake until the top is deeply golden and the lentils have drunk the liquid.”
- **Trigger phrase:** golden
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Rule:** `thermometer-only-reliable`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 182. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0203 · `instructions[3]`

- **Current text:** “3. Braise at a lazy simmer until a food thermometer in the thickest thigh reads 165 °F and the potatoes are tender.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 183. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0209 · `instructions[4]`

- **Current text:** “4. Pan-fry the burgers until a food thermometer at the centre of each reads 145 °F, then rest them briefly and serve in the toasted buns with the slaw heaped on.”
- **Trigger phrase:** 145 °f
- **Why:** 145 °f is below the class minimum 160 °F (71 °C) for meat_ground (rule ground-meat-160)
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — 145 °f is below the class minimum 160 °F (71 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 184. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0209 · `instructions[4]`

- **Current text:** “4. Pan-fry the burgers until a food thermometer at the centre of each reads 145 °F, then rest them briefly and serve in the toasted buns with the slaw heaped on.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 185. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0210 · `instructions[4]`

- **Current text:** “4. Return the chicken, add the noodles, and toss hard until everything is coated and steaming; finish with the sesame oil and sliced green onions.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 186. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0212 · `instructions[2]`

- **Current text:** “2. Lay the fillets in a shallow dish, pour over the soy sauce, lime, ginger, garlic and chili, and steam the parcel over the simmering rice pot until a food thermometer in the thickest fillet reads 145 °F.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 187. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0218 · `instructions[2]`

- **Current text:** “2. Stir in the flour, cook a minute, then whisk in the stock gradually into a smooth sauce; return the chicken and add the thyme.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 188. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0218 · `instructions[4]`

- **Current text:** “4. Tip the filling into a small baking dish, lay the pastry over, crimp the edge, cut two steam slits, and bake until the crust is deep gold and risen.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 189. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0224 · `instructions[3]`

- **Current text:** “3. Pan the haddock skin-side down in the oil until the flesh turns opaque and a food thermometer at the centre reads 145 °F; finish with lemon zest.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 190. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0225 · `instructions[2]`

- **Current text:** “2. Lift the meat out, soften the onion quarters in the fat, and tuck the carrots, potatoes and tomatoes around the roast with water to come halfway up the sides.”
- **Why:** the step names a protein ("2. Lift the meat out, soften the onion quarters in the fat, and tuck the carrots, potatoes and tomatoes around the roast with water to come halfway up the sides.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 191. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0225 · `instructions[3]`

- **Current text:** “3. Cover the pot and let it murmur in a low oven, turning the roast once, until the meat relaxes when pressed and a food thermometer in the thick end reads 145 °F.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 192. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0225 · `instructions[3]`

- **Current text:** “3. Cover the pot and let it murmur in a low oven, turning the roast once, until the meat relaxes when pressed and a food thermometer in the thick end reads 145 °F.”
- **Why:** the step names a protein ("3. Cover the pot and let it murmur in a low oven, turning the roast once, until the meat relaxes when pressed and a food thermometer in the thick end reads 145 °F.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 193. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0227 · `instructions[1]`

- **Current text:** “1. Brown the beef hard in a dry pot, breaking it only twice, then push it aside and soften the diced onion in the rendered fat.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 194. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0227 · `instructions[3]`

- **Current text:** “3. Simmer half-covered, stirring now and then, until the fat rises and the sauce turns brick red.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 195. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0228 · `instructions[1]`

- **Current text:** “1. Sear the seasoned thighs in half the butter in a wide pot, add the stock and carrot coins, and simmer until the chicken is just done.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 196. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0228 · `instructions[1]`

- **Current text:** “1. Sear the seasoned thighs in half the butter in a wide pot, add the stock and carrot coins, and simmer until the chicken is just done.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 197. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0231 · `instructions[2]`

- **Current text:** “2. Cook the finely chopped onion, carrot and celery in the same pot until they slump, return the meat, and pour the tomatoes over with water to barely cover.”
- **Why:** the step names a protein ("2. Cook the finely chopped onion, carrot and celery in the same pot until they slump, return the meat, and pour the tomatoes over with water to barely cover.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 198. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0231 · `instructions[3]`

- **Current text:** “3. Keep the pot at a shiver, half-covered, for the long haul, topping up when the sauce sinks below the meat, until the chuck shreds under a fork's pull.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 199. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0232 · `instructions[2]`

- **Current text:** “2. Sauté the quartered mushrooms and pepper strips in the drippings until they take colour at the edges.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 200. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0235 · `instructions[2]`

- **Current text:** “2. Return the lamb with the tomatoes and oregano, cover, and braise until the cubes bend when pinched.”
- **Why:** the step cooks lamb but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 201. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0235 · `instructions[2]`

- **Current text:** “2. Return the lamb with the tomatoes and oregano, cover, and braise until the cubes bend when pinched.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 202. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0235 · `instructions[3]`

- **Current text:** “3. Stir the orzo straight into the lamb sauce with hot water to loosen, and bake uncovered until the orzo swells and the top sets.”
- **Why:** the step cooks lamb but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 203. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0236 · `instructions[2]`

- **Current text:** “2. Brown the thighs in the pot, add half a cup of water, cover, and cook gently until a food thermometer at the bone reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 204. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0238 · `instructions[3]`

- **Current text:** “3. Wilt the spinach through in armfuls, season with lemon and salt, and eat with bread and a fried egg if you want one.”
- **Why:** the step cooks fried egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 205. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0239 · `instructions[2]`

- **Current text:** “2. Squeeze the orange and lime over, tuck the squashed halves into the pot, add a cup of water, cover, and braise low until the pork collapses when shouldered with a fork.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 206. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0239 · `instructions[2]`

- **Current text:** “2. Squeeze the orange and lime over, tuck the squashed halves into the pot, add a cup of water, cover, and braise low until the pork collapses when shouldered with a fork.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 207. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0240 · `instructions[3]`

- **Current text:** “3. Simmer covered until the pork shreds under pressure from a spoon and the broth has gone pale green and rich.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 208. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0240 · `instructions[3]`

- **Current text:** “3. Simmer covered until the pork shreds under pressure from a spoon and the broth has gone pale green and rich.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 209. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0241 · `instructions[3]`

- **Current text:** “3. Return the thighs, spoon the sauce over, and simmer covered until a food thermometer reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 210. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0242 · `instructions[4]`

- **Current text:** “4. Serve the beans over the rice with lime, and a fried egg on top if you are hungry.”
- **Why:** the step cooks fried egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 211. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0243 · `instructions[2]`

- **Current text:** “2. Brown the shanks in a little oil, add a cup of water, cover tightly, and braise very gently, turning once, until the meat retreats from the bone.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 212. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0247 · `instructions[2]`

- **Current text:** “2. Add the beef and turn it in the spice base, then pour in the rest of the coconut milk and bring to a bare simmer.”
- **Why:** the step names a protein ("2. Add the beef and turn it in the spice base, then pour in the rest of the coconut milk and bring to a bare simmer.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 213. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0247 · `instructions[3]`

- **Current text:** “3. Cook uncovered on the lowest heat, stirring from the bottom now and then, for a long time — until the coconut oil has fried the beef dark and the sauce is almost dry.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 214. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0247 · `instructions[3]`

- **Current text:** “3. Cook uncovered on the lowest heat, stirring from the bottom now and then, for a long time — until the coconut oil has fried the beef dark and the sauce is almost dry.”
- **Why:** the step names a protein ("3. Cook uncovered on the lowest heat, stirring from the bottom now and then, for a long time — until the coconut oil has fried the beef dark and the sauce is almost dry.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 215. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0248 · `instructions[1]`

- **Current text:** “1. Bring the stock with the ginger to a bare simmer and poach the whole breast gently, lid on, turning off the heat halfway, until a food thermometer in the middle reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 216. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0250 · `instructions[3]`

- **Current text:** “3. Stir the tomatoes with the brown sugar and pour over; cover with foil and bake until a food thermometer in the centre of a roll reads 160 °F and the rice is tender.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 217. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0250 · `instructions[3]`

- **Current text:** “3. Stir the tomatoes with the brown sugar and pour over; cover with foil and bake until a food thermometer in the centre of a roll reads 160 °F and the rice is tender.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 218. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0251 · `instructions[3]`

- **Current text:** “3. Stir the mustard with half a cup of water, return the chops, cover, and braise gently until a food thermometer in the thick end reads 145 °F.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 219. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0255 · `instructions[1]`

- **Current text:** “1. Warm the oil with the garlic and rosemary until fragrant, then add the diced tomato and cook down to a rough sauce.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 220. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0256 · `instructions[4]`

- **Current text:** “4. Bake again until hot through, crumble the feta over, and eat with lemon and oregano.”
- **Why:** the step cooks stuffed but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the stuffing and the innermost part of the poultry reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11)
- **Rule:** `stuffed-poultry-stuffing-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 221. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0257 · `instructions[1]`

- **Current text:** “1. Poach the breast in salted water with half the onion until a food thermometer reads 165 °F, then shred it.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 222. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0266 · `instructions[3]`

- **Current text:** “3. Slip the thighs back in and simmer until a food thermometer reads 165 °F and the sauce has body.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 223. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0269 · `instructions[3]`

- **Current text:** “3. Cook on low, lifting the edges and letting the egg run beneath, until the base sets and the top is still wet.”
- **Why:** the step cooks egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 224. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0269 · `instructions[4]`

- **Current text:** “4. Finish under the broiler until it puffs and a food thermometer in the middle reads 160 °F; rest, slice, and eat warm or at room temperature.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 225. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0274 · `instructions[1]`

- **Current text:** “1. Boil the eggs for nine minutes, cool under the tap, and peel.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 226. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0274 · `instructions[4]`

- **Current text:** “4. Halve the eggs into the sauce, warm them through until a food thermometer reads 160 °F, and serve with rice, bread, or a spoon.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 227. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0275 · `instructions[2]`

- **Current text:** “2. Drain, keeping a cup of the cooking water, and fold the beans into a bean pot with the whole onion, molasses, brown sugar, the cubed salt pork and enough liquid to show at the surface.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 228. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0275 · `instructions[3]`

- **Current text:** “3. Bake with the lid on, checking once to top up water, until the sauce has gone deep mahogany and thick enough to coat a spoon.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 229. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0276 · `instructions[2]`

- **Current text:** “2. Roast it low in a covered pan with a splash of water, fat cap up, until the bone pulls free and a food thermometer reads 145 °F with the meat slack and giving.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 230. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0277 · `instructions[3]`

- **Current text:** “3. Return everything to the pot with the carrot batons, cover, and braise at a tremble until the meat gives under a spoon.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 231. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0277 · `instructions[3]`

- **Current text:** “3. Return everything to the pot with the carrot batons, cover, and braise at a tremble until the meat gives under a spoon.”
- **Why:** the step names a protein ("3. Return everything to the pot with the carrot batons, cover, and braise at a tremble until the meat gives under a spoon.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 232. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0278 · `instructions[2]`

- **Current text:** “2. Add the chipotle and tomatoes, cook down dark, then return the pork with water to cover and simmer until the cubes loosen at the edges.”
- **Why:** the step cooks pork but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 233. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0278 · `instructions[2]`

- **Current text:** “2. Add the chipotle and tomatoes, cook down dark, then return the pork with water to cover and simmer until the cubes loosen at the edges.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 234. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0279 · `instructions[2]`

- **Current text:** “2. Shred the cabbage and toss with the lime juice, yogurt and salt — it should sit and soften while you cook.”
- **Why:** the step cooks tilapia but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 235. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0279 · `instructions[3]`

- **Current text:** “3. Pan-fry the fillets in oil until the crust sets and a food thermometer in the thick end reads 145 °F, flipping once.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 236. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0280 · `instructions[1]`

- **Current text:** “1. Poach the breast in salted water until a food thermometer reads 165 °F, then shred it and keep the poaching water.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 237. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0280 · `instructions[3]`

- **Current text:** “3. Dip each tortilla in the sauce, fill with chicken and onion, roll, and lay them seam-down in a baking dish.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 238. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0280 · `instructions[4]`

- **Current text:** “4. Pour the rest of the sauce over, shower with cheddar, and bake until bubbling at the edges.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 239. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0283 · `instructions[1]`

- **Current text:** “1. Poach the breast in the stock with half a sliced onion and the oregano until a food thermometer reads 165 °F; lift out to rest.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 240. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0283 · `instructions[3]`

- **Current text:** “3. Shred the chicken back into the broth and bring it to a steam, then kill the heat and squeeze the limes in — off the heat keeps the soup bright.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 241. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0284 · `instructions[2]`

- **Current text:** “2. Sear the chuck on every side in a Dutch oven, pour the sauce over with water to cover, and braise covered in a low oven until the beef falls when nudged.”
- **Why:** the record's safety field states class meat_whole_cut_red at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-red-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 242. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0284 · `instructions[2]`

- **Current text:** “2. Sear the chuck on every side in a Dutch oven, pour the sauce over with water to cover, and braise covered in a low oven until the beef falls when nudged.”
- **Why:** the step names a protein ("2. Sear the chuck on every side in a Dutch oven, pour the sauce over with water to cover, and braise covered in a low oven until the beef falls when nudged.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 243. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0285 · `instructions[2]`

- **Current text:** “2. Warm the beans in the sauce, then hold on the back burner.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 244. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0287 · `instructions[2]`

- **Current text:** “2. Scramble the eggs gently in the same pan, off the heat early — they finish inside the wrap.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 245. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0287 · `instructions[3]`

- **Current text:** “3. Warm the tortillas, load with potatoes, eggs and cheese, and roll them tight in foil.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 246. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0290 · `instructions[2]`

- **Current text:** “2. Shallow-fry in oil until the crust takes on real color and a food thermometer at the centre of the thickest cutlet reads 165 °F; drain briefly.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 247. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0290 · `instructions[3]`

- **Current text:** “3. Spoon the cooked tomatoes around the cutlets in a skillet, lay the mozzarella on each, and cover off the heat until it melts.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 248. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0292 · `instructions[1]`

- **Current text:** “1. Brown the beef hard in oil, breaking it small, until it takes on real color.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 249. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0293 · `instructions[2]`

- **Current text:** “2. Shallow-fry in oil, turning once, until the crust is deep gold and a food thermometer at the centre reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 250. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0294 · `instructions[1]`

- **Current text:** “1. Crisp the ground pork in a hot pan with a spoon of oil, breaking it small, until it sticks and browns in patches.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 251. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0297 · `instructions[2]`

- **Current text:** “2. Add the cumin and diced tomato and cook down to a rough masala.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 252. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0297 · `instructions[3]`

- **Current text:** “3. Beat the eggs with salt, pour in, and stir slowly — soft curds, never dry — pulling the pan off as soon as a food thermometer reads 160 °F.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 253. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0303 · `instructions[1]`

- **Current text:** “1. Season the thighs and sear them skin-side down in a cold-start skillet so the fat renders and the skin crisps.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 254. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0303 · `instructions[2]`

- **Current text:** “2. Flip, add the garlic, and cook until a food thermometer reads 165 °F; move them to a warm plate.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 255. `rawEggNoWarning` — data/recipes/originals/originals.jsonl · fl-original-0305 · `instructions[1]`

- **Current text:** “1. Mix the tuna with the lemon juice, a spoon of mayonnaise and pepper.”
- **Required change:** Use pasteurized eggs (or shell eggs treated to destroy Salmonella) for this raw or undercooked egg dish, or cook the egg component to 71 °C (160 °F) on a food thermometer. (Source: FDA — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Rule:** `raw-egg-recipes-pasteurized`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 256. `flagForReview` — data/recipes/originals/originals.jsonl · fl-original-0309 · `instructions[2]`

- **Current text:** “2. Cook the peppers and onion in the rendered fat until they slump and sweeten, then return the sausage coins.”
- **Why:** the step names a protein ("2. Cook the peppers and onion in the rendered fat until they slump and sweeten, then return the sausage coins.") that matches no doneness class in the rulebook — a reviewer must decide which safe minimum applies before this step can pass
- **Required change:** 

#### 257. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0310 · `instructions[1]`

- **Current text:** “1. Sear the chops in a hot skillet until they take on real color on both sides.”
- **Why:** the step cooks pork chops but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 258. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0310 · `instructions[3]`

- **Current text:** “3. Pour the stock down the side of the pan, cover, and simmer gently until a food thermometer at the bone reads 145 °F.”
- **Why:** the record's safety field states class meat_whole_cut_pork at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the cut, away from bone, fat or gristle reaches 63 °C (145 °F) on a food thermometer, then rest at least 3 minutes — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `whole-cut-pork-145-rest-3`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 259. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0311 · `instructions[3]`

- **Current text:** “3. Pull the pan off as soon as a food thermometer reads 160 °F — the carryover finishes the curds.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 260. `belowMinimumTemperature` — data/recipes/originals/originals.jsonl · fl-original-0313 · `instructions[3]`

- **Current text:** “3. Shape into a small loaf on a lined tin and bake until a food thermometer at the centre reads 160 °F.”
- **Trigger phrase:** 160 °f
- **Why:** 160 °f is below the class minimum 165 °F (74 °C) for leftovers (rule casseroles-165)
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — 160 °f is below the class minimum 165 °F (74 °C). (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 261. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0313 · `instructions[3]`

- **Current text:** “3. Shape into a small loaf on a lined tin and bake until a food thermometer at the centre reads 160 °F.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 262. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0314 · `instructions[1]`

- **Current text:** “1. Poach the breast in salted water until a food thermometer reads 165 °F, then shred it.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 263. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0318 · `instructions[1]`

- **Current text:** “1. Sear the thighs skin-side down until the skin is deep gold; lift out.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 264. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0321 · `instructions[3]`

- **Current text:** “3. Scramble the eggs in the same pan, then add the rice and break it up, letting it toast against the metal.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 265. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0323 · `instructions[4]`

- **Current text:** “4. Lower the heat, stir in the cream, return the chicken, and warm through gently — a hard boil splits the sauce.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 266. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0326 · `instructions[2]`

- **Current text:** “2. Nestle the thighs in, skin up, and roast until a food thermometer at the bone reads 165 °F and the potatoes give under a knife.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 267. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0328 · `instructions[1]`

- **Current text:** “1. Warm the garlic in the oil, add the tomatoes with salt and a pinch of sugar, and cook the sauce down until it loses its raw edge.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 268. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0330 · `instructions[1]`

- **Current text:** “1. Warm the tortillas in a dry pan and wrap them in a towel to steam soft.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 269. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0330 · `instructions[2]`

- **Current text:** “2. Beat the eggs with salt, then scramble them slowly in the butter, dragging the curds from the edges.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 270. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0330 · `instructions[3]`

- **Current text:** “3. Pull the pan off as soon as a food thermometer reads 160 °F — soft curds, not dry ones.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 271. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0334 · `instructions[4]`

- **Current text:** “4. Steam on the lowest heat until the rice is done and a food thermometer at the bone reads 165 °F — no peeking before then.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 272. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0336 · `instructions[3]`

- **Current text:** “3. Push the tin aside, lay the salmon in the space, and return it to the oven until a food thermometer at the centre reads 145 °F.”
- **Why:** the record's safety field states class flesh_fish at 145.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 273. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0337 · `instructions[1]`

- **Current text:** “1. Simmer the whole breast in the stock until a food thermometer reads 165 °F, then lift it out to rest.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 274. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0337 · `instructions[3]`

- **Current text:** “3. Crisp the tortilla strips in the oven while the soup comes back to a simmer.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 275. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0344 · `instructions[3]`

- **Current text:** “3. Cook the half-mooned zucchini in the same pan until it browns at the cut edges and stays crisp within.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 276. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0349 · `instructions[2]`

- **Current text:** “2. Pan-fry in oil until golden on both sides and a food thermometer at the centre reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 277. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0350 · `instructions[2]`

- **Current text:** “2. Brown the beef hard in a little oil, breaking it small, until it crisps at the edges.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 278. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0350 · `instructions[4]`

- **Current text:** “4. Serve over the rice with sliced green onions and a fried egg if you feel like it.”
- **Why:** the step cooks fried egg but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 279. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0355 · `instructions[2]`

- **Current text:** “2. Add the tomato and cook off the watery edge.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 280. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0355 · `instructions[3]`

- **Current text:** “3. Beat the eggs with salt and the cilantro, pour over the vegetables, and cook on low until the edges set but the centre still gleams.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 281. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0355 · `instructions[4]`

- **Current text:** “4. Fold, slide onto a plate, and check the centre has reached a food thermometer's 160 °F before eating.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 282. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0356 · `instructions[4]`

- **Current text:** “4. Squeeze the roasted lemon over everything and eat from the tray.”
- **Why:** the step cooks cod but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `flesh-fish-145`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 283. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0358 · `instructions[1]`

- **Current text:** “1. Halve the peppers lengthwise and par-roast them cut-side up while you cook the filling.”
- **Why:** the step cooks stuffed but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the stuffing and the innermost part of the poultry reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11)
- **Rule:** `stuffed-poultry-stuffing-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 284. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0358 · `instructions[3]`

- **Current text:** “3. Pile the filling into the pepper halves, return to the oven, and bake until the peppers slump and the tops brown.”
- **Why:** the step cooks stuffed but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the stuffing and the innermost part of the poultry reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11)
- **Rule:** `stuffed-poultry-stuffing-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety

#### 285. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0361 · `instructions[1]`

- **Current text:** “1. Blend the oats to a coarse flour, then add the banana, eggs, milk, baking powder and salt and blitz to a thick batter.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 286. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0361 · `instructions[3]`

- **Current text:** “3. Cook in a lightly buttered pan over medium-low until bubbles pop and the edges look dry, then flip once.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 287. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0361 · `instructions[4]`

- **Current text:** “4. A food thermometer in the thickest pancake should read 160 °F before the first one leaves the pan.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 288. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0362 · `instructions[1]`

- **Current text:** “1. Simmer the thighs in the stock with the halved onion until a food thermometer at the bone reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 289. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0365 · `instructions[2]`

- **Current text:** “2. Beat the eggs, pour them in, and scramble slowly over low heat.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 290. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0365 · `instructions[3]`

- **Current text:** “3. Pull the pan off at a food thermometer's 160 °F and fold the crumbled feta through — the carryover finishes the eggs while the feta stays in crumbles.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 291. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0367 · `instructions[2]`

- **Current text:** “2. Sear the thighs skin-side down until deep gold, then flip and roast alongside the potatoes until a food thermometer reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 292. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0368 · `instructions[3]`

- **Current text:** “3. Stir the corn into the sauce for the last ten minutes to warm through.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 293. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0373 · `instructions[2]`

- **Current text:** “2. Season the thighs and bake them skin-side up until the fat renders and the skin crisps.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 294. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0373 · `instructions[3]`

- **Current text:** “3. Brush the glaze over and return to the oven until it lacquers and a food thermometer at the bone reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 295. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0375 · `instructions[2]`

- **Current text:** “2. Check the breast with a food thermometer — 165 °F at the centre — then lift and shred it.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 296. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0376 · `instructions[2]`

- **Current text:** “2. Beat the eggs with salt and pour them over; scramble slowly, lifting from the edges.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 297. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0376 · `instructions[3]`

- **Current text:** “3. Pull the pan off when the eggs reach a food thermometer's 160 °F and still look barely wet — they finish in the pan.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 298. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0377 · `instructions[1]`

- **Current text:** “1. Brown the salted thighs slowly in oil until the skin releases and turns deep amber; move them to a plate.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 299. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0378 · `instructions[1]`

- **Current text:** “1. Grate the zucchini, salt it, and let it drain in a cloth for ten minutes — squeeze hard, or the fritters steam apart.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 300. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0378 · `instructions[3]`

- **Current text:** “3. Fry spoonfuls in oil, flattening slightly, until the bottoms brown and a food thermometer in the thickest fritter reads 160 °F.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 301. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0378 · `instructions[4]`

- **Current text:** “4. Drain briefly, eat with yogurt or plain, and make the last fritter the cook's tax.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 302. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0379 · `instructions[3]`

- **Current text:** “3. Add the ditalini and cook until barely tender, then wilt the spinach through.”
- **Why:** the step cooks ground beef but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 303. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0380 · `instructions[3]`

- **Current text:** “3. Fry the dried chilies, garlic and pepper chunks for a breath, then return the chicken with the sauce of soy, vinegar and sugar.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 304. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0382 · `instructions[1]`

- **Current text:** “1. Cook the sugar dry in the pan, without stirring past a swirl, until it turns the colour of dark tea — this is the caramel.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 305. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0382 · `instructions[3]`

- **Current text:** “3. Add the garlic, soy and a third of a cup of water, and simmer until the sauce turns syrupy and a food thermometer reads 165 °F.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 306. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0383 · `instructions[1]`

- **Current text:** “1. Scramble the beaten eggs soft in oil and set them aside — they cook again later, so keep them barely wet.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 307. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0383 · `instructions[2]`

- **Current text:** “2. Stir-fry the cabbage ribbons over high heat until the edges brown and the cores stay crisp.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 308. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0383 · `instructions[4]`

- **Current text:** “4. Return the eggs to finish — a food thermometer should read 160 °F before the pan leaves the heat — and serve with rice.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 309. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0387 · `instructions[3]`

- **Current text:** “3. Roast until the skin crisps and a food thermometer at the bone reads 165 °F, adding a splash of water if the pan dries.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 310. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0389 · `instructions[1]`

- **Current text:** “1. Warm the garlic in the oil, add the tomatoes with the oregano and salt, and simmer until the sauce darkens and thickens.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 311. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0390 · `instructions[1]`

- **Current text:** “1. Poach the breast gently in salted water until a food thermometer at the centre reads 165 °F; cool until it handles.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 312. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0391 · `instructions[2]`

- **Current text:** “2. Fry the patties in oil until deeply browned on both sides and a food thermometer reads 160 °F; move them to a plate.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 313. `reheatingWithoutThermometer` — data/recipes/originals/originals.jsonl · fl-original-0391 · `instructions[4]`

- **Current text:** “4. Dust the onions with the flour, cook it out, then add a cup and a half of water and bubble to a gravy; return the patties to warm through and serve over the potatoes.”
- **Required change:** Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Rule:** `leftovers-reheat-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 314. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0392 · `instructions[1]`

- **Current text:** “1. Brown the beef hard, breaking it small, until the pan picks up a crust.”
- **Why:** the record's safety field states class meat_ground at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `ground-meat-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 315. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0393 · `instructions[4]`

- **Current text:** “4. Bake until the cornmeal sets and the cheese browns, then rest ten minutes so it slices instead of slurries.”
- **Why:** the step cooks bake but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `casseroles-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 316. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0396 · `instructions[1]`

- **Current text:** “1. Season the cubed thighs and sear them in oil until browned all over; they finish in the sauce.”
- **Why:** the record's safety field states class meat_poultry at 165.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 317. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0397 · `instructions[1]`

- **Current text:** “1. Spread the yogurt on plates and let it come to cool room temperature while the eggs cook.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 318. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0399 · `instructions[3]`

- **Current text:** “3. Cook in the buttered pan over medium heat until bubbles pop and the edges dry, then flip once more only.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 319. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0399 · `instructions[4]`

- **Current text:** “4. Check the first pancake reaches a food thermometer's 160 °F, then stack, top with the honey-butter, and pour the rest of the honey over.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 320. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0400 · `instructions[1]`

- **Current text:** “1. Scramble the beaten eggs thin and soft, then set aside; warm the tortillas wrapped in a towel.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 321. `missingInternalTemperature` — data/recipes/originals/originals.jsonl · fl-original-0400 · `instructions[3]`

- **Current text:** “3. Season with the soy, a little vinegar and sugar, and cook until the cabbage wilts but still snaps.”
- **Why:** the step cooks eggs but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety, retrieved 2026-10-11)
- **Rule:** `raw-eggs-firm`
- **Source:** US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety — https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety

#### 322. `metadataNotInText` — data/recipes/originals/originals.jsonl · fl-original-0400 · `instructions[4]`

- **Current text:** “4. Return the eggs, toss once, and let everyone build their own wrap — a food thermometer should read 160 °F before the filling lands in the first tortilla.”
- **Why:** the record's safety field states class egg at 160.0 °F by thermometer (source: USDA FSIS Safe Minimum Internal Temperature Chart (food-safety rulebook data/food-safety/rules.json, citation fsis-safe-temperature-chart)), but the instruction text the user reads shows no thermometer check — metadata the text does not show is a finding, not a pass
- **Required change:** Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 71 °C (160 °F) on a food thermometer — write the check the record's safety field claims into the instruction text. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `egg-dishes-160`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/
