# Fix list — PR #95 (overhaul/design-round — design mocks, directions f / h / p)

Branch `overhaul/design-round` · PR head pinned at `a33290588dcc50c2434d0767f0fdcd81cf637212` · linted 2026-10-12 · **299 records, 4 findings**. Linter: `fl-safety-lint` built from the canon branch at `299ff32` (`packages/FLFoodSafety`); this task added no linter code.

## Extraction (provenance)

For each of the three directions: every leaf text block of every HTML page (including dark twins and the xxl variants) matching the same keyword screen becomes a copy record; each direction's `recipe.html` also becomes one recipe record (same construction as PR #86; direction-p's five steps include its timer affordances verbatim). All text verbatim. 299 records (direction-f 129, direction-h 93, direction-p 77). The directions' safety copy is NOT identical: direction-f's step 3 carries "Check the thickest piece reads 74 °C with a thermometer.", direction-h's does not, and direction-p splits the check across steps 2–3.

Extraction scripts (deterministic; run against a checkout of the head above; scratch copies: `extract/kit.py` + `extract/x_mocks.py` — the per-target script imports the shared kit for the leaf-block HTML extractor, the keyword screen and the record builders):

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
# ---- x_mocks.py ----
#!/usr/bin/env python3
"""Extractors for the spec mocks (PR #86, docs/spec-overhaul-20261011) and
design mocks (PR #95, overhaul/design-round).

Per HTML mock: every leaf-block line matching the food-safety keyword screen
becomes a copy record (id <basename>#L<index of the line in the file's
extraction order>). The recipe.html of each surface additionally becomes one
recipe record: title as shown, ingredient rows between the "Ingredients" and
"Why it fits you"/"Your taste" anchors, numbered step rows between the
"Steps" anchor and "Per serving"/"Cook with LeChef" (affordance rows like
"4 Show all 8" excluded). SPEC.md section 3.1 bullets become copy records.
All strings verbatim; nothing fixed.
"""
import json, re, sys, os, subprocess, glob
sys.path.insert(0, os.path.dirname(__file__))
from kit import leaf_lines, records_file, recipe_record, copy_record, write, SAFETY_SCREEN

BASE = "/home/user/work/fs-canon-p5"
NUM_ROW = re.compile(r"^(\d{1,2})\s+(\S.*)$")
UNIT_START = re.compile(r"^\d{1,2}\s+(min|kcal|of|steps|timers|servings|nests|tbsp|tsp|heads|cloves|cooks|assumed|g)\b")

def rev(ref):
    return subprocess.run(["git", "rev-parse", ref], capture_output=True, text=True,
                          cwd=f"{BASE}/clone").stdout.strip()

def screen_file(path, rel, records):
    lines = leaf_lines(open(path).read())
    n = 0
    for i, line in enumerate(lines):
        if SAFETY_SCREEN.search(line):
            records.append(copy_record(file=rel, id=f"{os.path.basename(path)}#L{i}",
                                       field="mock-copy", text=line))
            n += 1
    return lines, n

def recipe_from_mock(path, rel):
    """Build the recipe record from a recipe.html mock (anchors + numbered rows)."""
    lines = leaf_lines(open(path).read())
    ing_start = next((i for i, l in enumerate(lines) if l.startswith("Ingredients")), None)
    ing_end = next((i for i, l in enumerate(lines)
                    if i > (ing_start or 0) and (l.startswith("Why it fits you") or l.startswith("Your taste"))), None)
    ingredients = []
    if ing_start is not None and ing_end is not None:
        for l in lines[ing_start + 1:ing_end]:
            if l in ("− 2 servings +", "+", "−", "assumed", "Swap") or l.startswith(("Ingredients", "−", "+")):
                continue
            if l.startswith("Swap "):
                ingredients.append(l)  # swap row: verbatim (Lime + swap copy)
            elif re.search(r"[A-Za-z]", l):
                ingredients.append(l)
    step_start = next((i for i, l in enumerate(lines) if l.startswith("Steps")), None)
    steps = []
    if step_start is not None:
        # Consecutive run of numbered rows right after the "Steps" anchor.
        # Any non-row line (dock label, "Show all 8" affordance, section
        # header) ends the run. Handles every direction's dock label.
        for l in lines[step_start + 1:]:
            m = NUM_ROW.match(l)
            if not m or UNIT_START.match(l) or re.match(r"^\d{1,2}\s+Show\b", l):
                if steps or not m:
                    break
                continue
            steps.append(m.group(2))
    return recipe_record(file=rel, id=f"{rel}#recipe", title="Ginger chicken udon noodles",
                         ingredients="; ".join(ingredients), steps=steps)

SPEC_31 = [
    "Doneness for meat, poultry, fish, eggs and leftovers is stated as a checkable test with a thermometer temperature from a reviewed source (USDA FSIS safe minimum internal temperatures), never by colour or time alone. Timers say when to check.",
    "A camera look describes what a picture can show (browning, size, consistency) and says what it cannot assess. It never gives a safety verdict.",
    "Adapt rescales amounts. It changes a time only when a reviewed rule supports it (thickness, pan size, quantity in the pan); otherwise the step says to check rather than trust the timer.",
    "Every substitution rechecks all eaters' allergens, including compound ingredients (soy sauce contains wheat, pesto contains nuts). Swaps describe the difference (\"a little sharper\") and never promise \"no change\".",
    "Food-safety guidance is advisory and sourced. Shelf-life estimates never certify that food is safe.",
]

def p86():
    sha = rev("p5/p86")
    root = "docs/spec/overhaul-20261011/mocks"
    files = sorted(glob.glob(f"{BASE}/targets/p86/{root}/*.html"))
    records = []
    per_file = {}
    for path in files:
        rel = f"{root}/{os.path.basename(path)}"
        _, n = screen_file(path, rel, records)
        per_file[os.path.basename(path)] = n
        if os.path.basename(path) == "recipe.html":
            records.append(recipe_from_mock(path, rel))
    for n, bullet in enumerate(SPEC_31, 1):
        records.append(copy_record(file="docs/spec/overhaul-20261011/SPEC.md",
                                   id=f"SPEC.md#3.1-{n}", field="spec-3.1", text=bullet))
    doc = records_file(
        "PR #86 (docs/spec-overhaul-20261011) - spec mock screen copy (keyword-screened leaf blocks, verbatim), the recipe mock as a recipe record, and the five SPEC.md 3.1 bullets, verbatim",
        records)
    write(f"{BASE}/records/p86-spec-mocks.json", doc)
    print(f"p86: {len(records)} records ({per_file}); head {sha}")

def p95():
    sha = rev("p5/p95")
    root = "docs/design-round"
    records = []
    per_direction = {}
    for direction in ["direction-f", "direction-h", "direction-p"]:
        n_before = len(records)
        files = sorted(glob.glob(f"{BASE}/targets/p95/{root}/{direction}/*.html"))
        for path in files:
            rel = f"{root}/{direction}/{os.path.basename(path)}"
            screen_file(path, rel, records)
            if os.path.basename(path) == "recipe.html":
                records.append(recipe_from_mock(path, rel))
        per_direction[direction] = len(records) - n_before
    doc = records_file(
        "PR #95 (overhaul/design-round) - design mock screen copy for directions f, h and p (keyword-screened leaf blocks of every page including dark twins and xxl variants, verbatim), one recipe record per direction's recipe mock",
        records)
    write(f"{BASE}/records/p95-design-mocks.json", doc)
    print(f"p95: {len(records)} records {per_direction}; head {sha}")

if __name__ == "__main__":
    os.makedirs(f"{BASE}/records", exist_ok=True)
    which = sys.argv[1:] or ["86", "95"]
    if "86" in which: p86()
    if "95" in which: p95()

```

## Reproduce the lint

```sh
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json> --json   # machine output
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json>        # human output
```

The `<records.json>` file is `p95-design-mocks.json` in the canon task's scratch — the extraction output described above (299 records, shape per `data/food-safety/conformance/README.md`). Rerunning the extraction scripts on the same head reproduces it byte-for-byte.

Field convention: `instructions[N]` is the Nth numbered line of the extracted instructions string; for a source `steps[]` array the zero-based array index is N−1 (verified against `fl-original-0026`, a 4-step record whose reheat step is line 4 and array index 3).

## Findings by kind

| kind | count |
|---|---|
| `salvage-spoiled` | 2 |
| `timeOnlyCooking` | 2 |

Total: **4 findings** over 299 records.

## Findings

#### 1. `timeOnlyCooking` — docs/design-round/direction-h/recipe.html · docs/design-round/direction-h/recipe.html#recipe · `instructions[3]`

- **Current text:** “3. Heat the oil in a wok until it just smokes. Fry the chicken 4 minutes without moving it, then 2 more, tossing. timer 4:00, 2:00”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 2. `salvage-spoiled` — docs/design-round/direction-h/shell-s-progress-dark.html · shell-s-progress-dark.html#L14 · `mock-copy`

- **Current text:** “Saved-from-waste is counted in grams of food used before it spoiled — the app's ecological promise in one line.”
- **Required change:** Replace with: Do not use food that has spoiled — gone slimy, moldy, decayed or off-smelling. Discard it, and plan to buy less next time. When in doubt, throw it out. (policy: salvage-spoiled; source: US FDA — Are You Storing Food Safely?; https://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely; retrieved 2026-10-11: "Be aware that food can make you very sick even when it doesn't look, smell, or taste spoiled. That's because foodborne illnesses are caused by pathogenic bacteria, which are different from the spoilage bacteria that make foods "go bad."")

#### 3. `salvage-spoiled` — docs/design-round/direction-h/shell-s-progress.html · shell-s-progress.html#L14 · `mock-copy`

- **Current text:** “Saved-from-waste is counted in grams of food used before it spoiled — the app's ecological promise in one line.”
- **Required change:** Replace with: Do not use food that has spoiled — gone slimy, moldy, decayed or off-smelling. Discard it, and plan to buy less next time. When in doubt, throw it out. (policy: salvage-spoiled; source: US FDA — Are You Storing Food Safely?; https://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely; retrieved 2026-10-11: "Be aware that food can make you very sick even when it doesn't look, smell, or taste spoiled. That's because foodborne illnesses are caused by pathogenic bacteria, which are different from the spoilage bacteria that make foods "go bad."")

#### 4. `timeOnlyCooking` — docs/design-round/direction-p/recipe.html · docs/design-round/direction-p/recipe.html#recipe · `instructions[2]`

- **Current text:** “2. Sear the chicken 6 min , then add ginger and garlic. timer 6 min”
- **Trigger phrase:** chicken
- **Required change:** Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/
