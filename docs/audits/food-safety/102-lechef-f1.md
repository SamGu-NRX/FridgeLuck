# Fix list — PR #102 (overhaul/lechef-f1 — embedded FSIS table, design scripts, WORLD_RECIPE fixture)

Branch `overhaul/lechef-f1` · PR head pinned at `41597b1a393c153cf75a68d6a7019e5240866792` · linted 2026-10-12 · **60 records, 2 findings**. Linter: `fl-safety-lint` built from the canon branch at `299ff32` (`packages/FLFoodSafety`); this task added no linter code.

## Extraction (provenance)

Three extractions, all verbatim: (1) every keyword-screened string literal of `backend/gemini-agent/src/lechef/foodSafety.ts` — the six embedded FSIS `test` strings, the source name, and the unknown-path copy; (2) keyword-screened string literals ≥25 chars from every file under `backend/gemini-agent/src/lechef/designs/` (assistant turns and policy lines); (3) the `WORLD_RECIPE` fixture in `coach/scripts/world.ts` as a recipe record (title "Chicken stir-fry", four verbatim steps). Note: `world.ts` marks step index 2 with `safetyCheckTarget: "chicken"`; that marker is not the canonical safety-field shape and was not extracted as one. 60 records.

Extraction scripts (deterministic; run against a checkout of the head above; scratch copies: `extract/kit.py` + `extract/x_lechef.py` — the per-target script imports the shared kit for the leaf-block HTML extractor, the keyword screen and the record builders):

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
# ---- x_lechef.py ----
#!/usr/bin/env python3
"""Extractors for PR #94 (backend recipe service + agent system prompt) and
PR #102 (LeChef F1: foodSafety.ts embedded table, design scripts, world
fixture). Faithful verbatim extraction of string literals; record shapes per
data/food-safety/conformance/README.md."""
import json, re, sys, os, subprocess, glob
sys.path.insert(0, os.path.dirname(__file__))
from kit import records_file, recipe_record, copy_record, write, SAFETY_SCREEN

BASE = "/home/user/work/fs-canon-p5"

def rev(ref):
    return subprocess.run(["git", "rev-parse", ref], capture_output=True, text=True,
                          cwd=f"{BASE}/clone").stdout.strip()

TS_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"|\'((?:[^\'\\\n]|\\.)*)\'|`([^`]*)`')

def ts_literals(src):
    """String literals from TypeScript source, verbatim inner text."""
    out = []
    for m in TS_LITERAL.finditer(src):
        text = next(g for g in m.groups() if g is not None)
        if text.strip():
            out.append(text)
    return out

def looks_like_code(t):
    if "/" in t or ".ts" in t or "\n" in t:
        return True
    return t.startswith("{") and not t.endswith(".")

def p94():
    ref = "p5/p94"
    sha = rev(ref)
    svc = "backend/gemini-agent/src/services/recipeService.ts"
    sysp = "backend/gemini-agent/src/agent/systemPrompt.ts"
    records = []
    # The recipe-generation prompt: template-literal pieces in generateRecipe.
    svc_src = open(f"{BASE}/targets/p94/{svc}").read()
    n = 0
    for lit in ts_literals(svc_src):
        if len(lit) >= 25 and lit.startswith(("You are a practical", "Staple allowances",
                                              "The avoid_ingredients", "Ingredients that conflict",
                                              "Do not invent", "List every ingredient")):
            n += 1
            records.append(copy_record(file=svc, id=f"recipeService.ts#prompt-{n}",
                                       field="prompt", text=lit))
    for lit in ts_literals(open(f"{BASE}/targets/p94/{sysp}").read()):
        if len(lit) >= 25 and re.search(r"(?i)safety|freshness|shelf-life", lit):
            records.append(copy_record(file=sysp, id="systemPrompt.ts#"
                                       + re.sub(r"[^a-z0-9]+", "-", lit[:40].lower()).strip("-"),
                                       field="system-prompt", text=lit))
    doc = records_file(
        "PR #94 (fleet/fl-backend-trunk-20261011) - the recipe-generation prompt sentences and the food-safety lines of the agent system prompt, verbatim string literals",
        records)
    write(f"{BASE}/records/p94-backend-recipe-service.json", doc)
    print(f"p94: {len(records)} copy records; head {sha}")

def p102():
    ref = "p5/p102"
    sha = rev(ref)
    src_root = "backend/gemini-agent/src"
    records = []
    # foodSafety.ts: every screened string literal (embedded table tests,
    # source name, unknown-path strings).
    fs = "backend/gemini-agent/src/lechef/foodSafety.ts"
    for lit in ts_literals(open(f"{BASE}/targets/p102/{fs}").read()):
        if len(lit) >= 15 and SAFETY_SCREEN.search(lit) and not looks_like_code(lit):
            records.append(copy_record(
                file=fs, id="foodSafety.ts#" + re.sub(r"[^a-z0-9]+", "-", lit[:40].lower()).strip("-"),
                field="foodSafety.ts", text=lit))
    # Design scripts: assistant-turn copy and policy lines.
    for path in sorted(glob.glob(f"{BASE}/targets/p102/{src_root}/lechef/designs/**/*.ts", recursive=True)):
        rel = path.replace(f"{BASE}/targets/p102/", "")
        base = os.path.basename(path)
        for i, lit in enumerate(ts_literals(open(path).read())):
            if (len(lit) >= 25 and SAFETY_SCREEN.search(lit)
                    and not looks_like_code(lit) and not lit.startswith("@")):
                records.append(copy_record(
                    file=rel, id=f"{base}#L{i}", field="design-copy", text=lit))
    # WORLD_RECIPE fixture as a recipe record (verbatim steps).
    world = open(f"{BASE}/targets/p102/{src_root}/lechef/designs/coach/scripts/world.ts").read()
    steps = re.findall(r'\{ index: (\d+), text: "([^"]+)"(, timerMinutes: \d+)?(, safetyCheckTarget: "([a-z]+)")? \}', world)
    bill = re.findall(r'name: "([^"]+)", quantity', world)
    records.append(recipe_record(
        file="backend/gemini-agent/src/lechef/designs/coach/scripts/world.ts",
        id="WORLD_RECIPE", title="Chicken stir-fry",
        ingredients=", ".join(bill),
        steps=[s[1] for s in sorted(steps, key=lambda s: int(s[0]))]))
    doc = records_file(
        "PR #102 (overhaul/lechef-f1) - foodSafety.ts embedded-table strings and unknown-path copy, design-script safety copy, and the WORLD_RECIPE fixture steps, verbatim. Note: world.ts marks step index 2 with safetyCheckTarget:\"chicken\"; that marker is not the canonical safety-field shape and is not extracted as one.",
        records)
    write(f"{BASE}/records/p102-lechef-f1.json", doc)
    print(f"p102: {len(records)} records; head {sha}")

if __name__ == "__main__":
    os.makedirs(f"{BASE}/records", exist_ok=True)
    which = sys.argv[1:] or ["94", "102"]
    if "94" in which: p94()
    if "102" in which: p102()

```

## Reproduce the lint

```sh
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json> --json   # machine output
swift run --package-path packages/FLFoodSafety fl-safety-lint lint <records.json>        # human output
```

The `<records.json>` file is `p102-lechef-f1.json` in the canon task's scratch — the extraction output described above (60 records, shape per `data/food-safety/conformance/README.md`). Rerunning the extraction scripts on the same head reproduces it byte-for-byte.

Field convention: `instructions[N]` is the Nth numbered line of the extracted instructions string; for a source `steps[]` array the zero-based array index is N−1 (verified against `fl-original-0026`, a 4-step record whose reheat step is line 4 and array index 3).

## Findings by kind

| kind | count |
|---|---|
| `missingInternalTemperature` | 2 |

Total: **2 findings** over 60 records.

## Findings

#### 1. `missingInternalTemperature` — backend/gemini-agent/src/lechef/designs/coach/scripts/world.ts · WORLD_RECIPE · `instructions[2]`

- **Current text:** “2. Heat the pan and sear the chicken.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/

#### 2. `missingInternalTemperature` — backend/gemini-agent/src/lechef/designs/coach/scripts/world.ts · WORLD_RECIPE · `instructions[3]`

- **Current text:** “3. Stir-fry the chicken until done.”
- **Why:** the step cooks chicken but states no thermometer, no internal temperature and no check of any kind
- **Required change:** Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/, retrieved 2026-10-11)
- **Rule:** `poultry-all-cuts-165`
- **Source:** USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart — https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/
