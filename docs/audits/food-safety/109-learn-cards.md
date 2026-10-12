# Fix list — PR #109 (overhaul/learn-cards — 116 kitchen-knowledge learn cards)

Branch `overhaul/learn-cards` · PR head pinned at `a1f3c7a00a04f27bfbf87e8f19717df452f5ba24` · linted 2026-10-12 · **771 records, 5 findings**. Linter: `fl-safety-lint` built from the canon branch at `299ff32` (`packages/FLFoodSafety`); this task added no linter code.

## Extraction (provenance)

Each of the 116 card files under `data/kitchen-knowledge/learn-cards/cards/` contributes its five section texts (`whatItIs`, `historyNote`, `howToChoose`, `storage`, `useItUp`) and every substitution note as copy records (`<cardId>#<section>`). All text verbatim. 771 copy records.

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

The `<records.json>` file is `p109-learn-cards.json` in the canon task's scratch — the extraction output described above (771 records, shape per `data/food-safety/conformance/README.md`). Rerunning the extraction scripts on the same head reproduces it byte-for-byte.

## Findings by kind

| kind | count |
|---|---|
| `cook-decayed-or-sprouted` | 1 |
| `salvage-spoiled` | 3 |
| `smell-safety-test` | 1 |

Total: **5 findings** over 771 records.

## Findings

#### 1. `salvage-spoiled` — data/kitchen-knowledge/learn-cards/cards · avocado#howToChoose · `howToChoose`

- **Current text:** “Squeeze gently: ripe fruit yields to even, light pressure without feeling mushy, and the stem end should look green underneath, not brown.”
- **Required change:** Replace with: Do not use food that has spoiled — gone slimy, moldy, decayed or off-smelling. Discard it, and plan to buy less next time. When in doubt, throw it out. (policy: salvage-spoiled; source: US FDA — Are You Storing Food Safely?; https://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely; retrieved 2026-10-11: "Be aware that food can make you very sick even when it doesn't look, smell, or taste spoiled. That's because foodborne illnesses are caused by pathogenic bacteria, which are different from the spoilage bacteria that make foods "go bad."")

#### 2. `cook-decayed-or-sprouted` — data/kitchen-knowledge/learn-cards/cards · garlic#howToChoose · `howToChoose`

- **Current text:** “Choose heads that feel firm and heavy with tight, unbroken skin and no green sprouts; soft or sprouting bulbs have started using up their own flavour.”
- **Required change:** Replace with: Discard produce that is rotten, decaying or has sprouted — cooking does not make spoiled produce safe. Use produce before its quality window instead. When in doubt, throw it out. (policy: cook-decayed-or-sprouted; source: US FDA — Selecting and Serving Produce Safely; https://www.fda.gov/food/buy-store-serve-safe-food/selecting-and-serving-produce-safely; retrieved 2026-10-11: "Cut away any damaged or bruised areas on fresh fruits and vegetables before preparing and/or eating. Throw away any produce that looks rotten.")

#### 3. `salvage-spoiled` — data/kitchen-knowledge/learn-cards/cards · paneer#howToChoose · `howToChoose`

- **Current text:** “Choose blocks that look moist and ivory with a clean dairy smell, not sour or slimy; firmer blocks fry better, softer ones crumble for fillings.”
- **Required change:** Replace with: Do not use food that has spoiled — gone slimy, moldy, decayed or off-smelling. Discard it, and plan to buy less next time. When in doubt, throw it out. (policy: salvage-spoiled; source: US FDA — Are You Storing Food Safely?; https://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely; retrieved 2026-10-11: "Be aware that food can make you very sick even when it doesn't look, smell, or taste spoiled. That's because foodborne illnesses are caused by pathogenic bacteria, which are different from the spoilage bacteria that make foods "go bad."")

#### 4. `salvage-spoiled` — data/kitchen-knowledge/learn-cards/cards · parsley#howToChoose · `howToChoose`

- **Current text:** “Choose perky, deep-green bunches with no slimy or yellowed stems; flat-leaf for cooking and salads, curly where texture matters.”
- **Required change:** Replace with: Do not use food that has spoiled — gone slimy, moldy, decayed or off-smelling. Discard it, and plan to buy less next time. When in doubt, throw it out. (policy: salvage-spoiled; source: US FDA — Are You Storing Food Safely?; https://www.fda.gov/consumers/consumer-updates/are-you-storing-food-safely; retrieved 2026-10-11: "Be aware that food can make you very sick even when it doesn't look, smell, or taste spoiled. That's because foodborne illnesses are caused by pathogenic bacteria, which are different from the spoilage bacteria that make foods "go bad."")

#### 5. `smell-safety-test` — data/kitchen-knowledge/learn-cards/cards · tempeh#howToChoose · `howToChoose`

- **Current text:** “Choose blocks that are pale-to-grey with a firm, dry surface and a clean smell — black spots are the mould, sliminess or off smells are not; keep it cold.”
- **Required change:** Replace with: Smell is not a safety test: bacteria that cause food poisoning do not change how food smells or looks. Judge by time and temperature instead — the 2-hour rule and the storage window — and discard what has passed them. When in doubt, throw it out. (policy: smell-safety-test; source: USDA Food Safety and Inspection Service — Refrigeration and Food Safety; https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/refrigeration; retrieved 2026-10-11: "Pathogenic bacteria can grow rapidly in the "Danger Zone," the temperature range between 40 and 140 °F, but they do not generally affect the taste, smell, or appearance of a food. In other words, one cannot tell that a pathogen is present.")
