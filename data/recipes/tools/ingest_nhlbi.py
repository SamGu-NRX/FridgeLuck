#!/usr/bin/env python3
"""NHLBI Healthy Eating Recipes -> RS v1 ingestion (data/recipes/tools/).

Rights basis (SOURCES.md section 3, lead-verified):
- The NHLBI site notice states the information is public domain; works
  authored by federal employees as part of official duties are not subject
  to US copyright (17 U.S.C. section 105).
- The NHLBI leaflet (publications/15-5227.pdf) states "These recipes were
  specially developed by the National Heart, Lung, and Blood Institute
  (NHLBI)".
- The trap: pages crediting a community manual are NOT treated as NHLBI
  works per SOURCES.md's example (the Pinto Beans page crediting *Honoring
  the Gift of Heart Health*). Community-manual credits quarantine fail-closed
  and never enter corpus.jsonl.

Quantity evidence:
- Stated ounces convert at exactly 28.3495 g/oz into kind=source_grams
  (SCHEMA.md: grams carried from a source record); provenance names the
  stated ounce value and the exact factor.
- Cup/Tbsp/tsp lines use the suite conversion table via household refs
  (only when the ref exists).
- Everything else is an honest unknown; recipes under 95% resolution skip.
"""
from __future__ import annotations

import argparse
import html as html_mod
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import ingest_nhs as N  # reuse name tables, claim logic, step builder

ID_TAG = "nhlbi"
BUILD_DATE = "2026-10-11"
SITE_NOTICE = ("The information on this site is in the public domain and may "
               "be used or reproduced without permission.")
LEAFLET_STATEMENT = ("These recipes were specially developed by the National "
                     "Heart, Lung, and Blood Institute (NHLBI)")
LEAFLET_URL = "https://www.nhlbi.nih.gov/sites/default/files/publications/15-5227.pdf"
MIN_RESOLVE = N.MIN_RESOLVE

# Cookbook credits: NHLBI's own healthy-eating cookbooks (the leaflet's
# "specially developed by NHLBI" statement covers the program's recipes).
# Community-manual credits (e.g. *Honoring the Gift of Heart Health*, the
# Filipino and Vietnamese manual families) are NOT NHLBI works per
# SOURCES.md section 3's example and quarantine with everything unrecognized.
COOKBOOK_CREDITS = (
    "deliciously healthy dinners",
    "deliciously healthy family meals",
    "delicious heart healthy latino recipes",
    "heart healthy home cooking african american style",
    "stay young at heart",
)

OZ_PER_GRAM = 28.3495
LB_PER_GRAM = 453.592


def clean_text(s: str) -> str:
    s = html_mod.unescape(s)
    return re.sub(r"\s+", " ", s).strip()


def strip_tags(s: str) -> str:
    return clean_text(re.sub(r"<[^>]+>", " ", s))


def parse_nhlbi_page(path: Path) -> dict[str, Any] | None:
    """Extract title, ingredient lines, directions, times, yield, credit."""
    html = path.read_text(encoding="utf-8")

    m = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S)
    title = strip_tags(m.group(1)) if m else ""
    if not title:
        mt = re.search(r"<title>(.*?)\s*\|\s*NHLBI", html, re.S)
        title = strip_tags(mt.group(1)) if mt else ""
    if not title:
        return None

    ingredients: list[str] = []
    mi = re.search(r"<h2[^>]*>\s*Ingredients\s*</h2>\s*<ul[^>]*>(.*?)</ul>",
                   html, re.S | re.I)
    if mi:
        ingredients = [strip_tags(x) for x in re.findall(r"<li[^>]*>(.*?)</li>",
                                                         mi.group(1), re.S)]
    directions: list[str] = []
    md = re.search(r"<h2[^>]*>\s*Directions\s*</h2>\s*<ol[^>]*>(.*?)</ol>",
                   html, re.S | re.I)
    if md:
        directions = [strip_tags(x) for x in re.findall(r"<li[^>]*>(.*?)</li>",
                                                        md.group(1), re.S)]

    def field_minutes(field: str) -> int:
        mf = re.search(rf"field--name-field-{field}.*?"
                       r"<div[^>]*class=\"field__item[^\"]*\"[^>]*>(.*?)</div>",
                       html, re.S)
        if not mf:
            return 0
        mm = re.search(r"(\d+)\s*minute", strip_tags(mf.group(1)), re.I)
        return int(mm.group(1)) if mm else 0

    prep_min = field_minutes("prep-time")
    cook_min = field_minutes("cook-time")

    servings = 0
    my = re.search(r"field--name-field-yields.*?"
                   r"<div[^>]*class=\"field__item[^\"]*\"[^>]*>(.*?)</div>",
                   html, re.S)
    if my:
        ms = re.search(r"(\d+)", strip_tags(my.group(1)))
        if ms:
            servings = int(ms.group(1))

    credit = ""
    mc = re.search(r"Recipe Source:\s*(.*?)</p>", html, re.S | re.I)
    if not mc:
        mc = re.search(r"<strong>Source:</strong>\s*(.*?)</p>", html, re.S | re.I)
    if mc:
        credit = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", mc.group(1))).strip()

    return {"slug": path.stem, "title": title, "ingredients": ingredients,
            "directions": directions, "minutes": prep_min + cook_min,
            "servings": servings, "credit": credit, "html": html}


# --- quantity parsing -------------------------------------------------------

PREP_VERB_HEADS = re.compile(
    r"^(?:cut|chopped|chop|rinsed|rinse|minced|mince|diced|dice|sliced|slice|"
    r"drained|drain|rinsed|beaten|beat|softened|trimmed|trim|cubed|shredded|"
    r"halved|quartered|separated|crumbled|torn|cooked|crushed|mashed|peeled|"
    r"grated|zested|warmed|toasted|ground)\b", re.I)


def ingredient_name(s: str) -> str:
    """Food name from an ingredient line: keep leading comma segments until a
    segment starts with a prep verb ("boneless, skinless chicken breast, cut
    into thin strips" -> "boneless skinless chicken breast")."""
    out: list[str] = []
    for seg in s.split(","):
        seg = seg.strip()
        if not seg:
            continue
        if PREP_VERB_HEADS.match(seg):
            break
        out.append(seg)
    return " ".join(out) if out else s.split(",")[0].strip()


def parse_num(tok: str) -> float | None:
    tok = tok.strip().lower()
    if tok in N.NUM_WORDS:
        return float(N.NUM_WORDS[tok])
    if tok == "half":
        return 0.5
    m = re.fullmatch(r"(\d+)\s+(\d+)\s*/\s*(\d+)", tok)  # 1 1/2
    if m:
        return int(m.group(1)) + int(m.group(2)) / int(m.group(3))
    m = re.fullmatch(r"(\d+)\s*/\s*(\d+)", tok)  # 1/2
    if m:
        return int(m.group(1)) / int(m.group(2))
    m = re.fullmatch(r"(\d+(?:\.\d+)?)", tok)
    if m:
        return float(m.group(1))
    return None


def norm_line(line: str) -> str:
    s = unicodedata.normalize("NFKD", line)
    s = s.replace("\u2044", "/")
    s = re.sub(r"(\d)(?=\d/\d)", r"\1 ", s)  # 1½ -> 1 1/2
    s = s.replace("\u2013", "-").replace("\u2014", "-")
    s = re.sub(r"\s+", " ", s).strip()
    return s


def upper_of_range(tok: str) -> float | None:
    """Upper bound of '1-2' / '1 to 2' / single value (timers and quantities)."""
    tok = re.sub(r"\s+to\s+", "-", tok, flags=re.I)
    parts = [p for p in tok.split("-") if p.strip()]
    vals = [parse_num(p) for p in parts]
    if not vals or any(v is None for v in vals):
        return None
    return max(v for v in vals if v is not None)


QTY_TOK = r"(?:\d+\s+\d+\s*/\s*\d+|\d+\s*/\s*\d+|\d+(?:\.\d+)?|half|a|an|one|two|three|four|five|six)"


def parse_ingredient_line(line: str) -> dict[str, Any] | None:
    """Return {name, qty} or None if unparseable (treated as unknown)."""
    text = norm_line(line)
    # "for sauce: 2 tbsp ketchup" / "for salad: 1 large mango" -> parse remainder
    mlabel = re.match(r"^for\s+[a-z ]+:\s*(.+)$", text, re.I)
    if mlabel:
        text = mlabel.group(1).strip()
    low = text.lower()

    def unknown(name: str) -> dict[str, Any]:
        return {"name": N.display_canonical(N.normalize_name(name)),
                "qty": {"kind": "unknown"}}

    if re.search(r"\bto taste\b|\bas needed\b|\bas desired\b", low):
        return unknown(ingredient_name(text))
    if re.search(r"nonstick (?:cooking )?spray|cooking spray|wooden skewers", low):
        return unknown(ingredient_name(text))

    # garlic with a stated clove count: "1 Tbsp garlic, minced (about 2-3 cloves)"
    mcl = re.search(r"\(\s*about\s+([\d\-–\s]+|one\s+to\s+two|\d+)\s*cloves?\s*\)",
                    text, re.I)
    if mcl and "garlic" in low:
        tok = mcl.group(1).replace("\u2013", "-")
        cloves = upper_of_range(re.sub(r"\s*(one|two)", " ", tok)) or 0
        if not cloves:
            words = re.findall(r"one|two", tok, re.I)
            cloves = len(words)
        if cloves:
            return {"name": N.display_canonical(N.normalize_name("garlic")),
                    "qty": {"kind": "household", "value": cloves, "unit": "clove",
                            "conversion_ref": "garlic_clove",
                            "grams": N.ref_grams("garlic_clove", cloves)}}

    # count-first or unit-first stated-weight packs:
    #   "2 (5 oz) cans diced tomatoes"  /  "1 can (14.5 oz) chicken broth"
    mp = re.match(rf"^(?P<cnt>{QTY_TOK})\s*(?P<unit>cans?|packages?|packets?|jars?|"
                  r"containers?|boxes?|bottles?|cartons?|bags?)?\s*"
                  r"\(\s*(?P<oz>\d+(?:\.\d+)?)\s*oz(?:\s+each)?\)\s*"
                  r"(?:(?P=unit)s?\s+)?(?:of\s+)?(?P<name>.+)$", text, re.I)
    if mp and (mp.group("unit") or re.match(rf"^{QTY_TOK}\s*\(", text)):
        cnt = upper_of_range(mp.group("cnt")) or 0.0
        oz = float(mp.group("oz"))
        name = re.sub(r"\([^)]*\)", " ", mp.group("name")).strip()
        if cnt > 0 and oz > 0:
            return {"name": N.display_canonical(N.normalize_name(name)),
                    "qty": {"kind": "source_grams",
                            "grams": round(cnt * oz * OZ_PER_GRAM, 1)}}
        return unknown(name)

    # stated ounces: "12 oz boneless, skinless chicken breast"
    mo = re.match(rf"^(?P<qty>{QTY_TOK}(?:\s*-\s*{QTY_TOK})?)\s*"
                  r"(?:oz|ounces?)\s+(?P<name>.+)$", text, re.I)
    if mo:
        oz = upper_of_range(mo.group("qty"))
        name = ingredient_name(mo.group("name"))
        if oz and oz > 0:
            return {"name": N.display_canonical(N.normalize_name(name)),
                    "qty": {"kind": "source_grams",
                            "grams": round(oz * OZ_PER_GRAM, 1)}}
        return unknown(name)

    # stated pounds: "1 1/2 lb salmon fillet, cut into 6 portions"
    mlb = re.match(rf"^(?P<qty>{QTY_TOK}(?:\s*-\s*{QTY_TOK})?)\s*"
                   r"(?:lbs?|pounds?)\s+(?P<name>.+)$", text, re.I)
    if mlb:
        lb = upper_of_range(mlb.group("qty"))
        name = ingredient_name(mlb.group("name"))
        if lb and lb > 0:
            return {"name": N.display_canonical(N.normalize_name(name)),
                    "qty": {"kind": "source_grams",
                            "grams": round(lb * LB_PER_GRAM, 1)}}
        return unknown(name)

    # household measures: C / cup / Tbsp / tsp (only refs in the suite table)
    mh = re.match(rf"^(?P<qty>{QTY_TOK}(?:\s*-\s*{QTY_TOK})?)\s*"
                  r"(?P<unit>C\b|cups?|Tbsps?\.?|tbsps?\.?|tablespoons?|tsps?\.?|teaspoons?)\s+"
                  r"(?P<name>.+)$", text)
    if mh:
        val = upper_of_range(mh.group("qty"))
        name = ingredient_name(re.sub(r"\([^)]*\)", " ", mh.group("name")).strip())
        unit = mh.group("unit").lower().rstrip(".")
        if val is None or val <= 0:
            return unknown(name)
        canon = N.normalize_name(name)
        base = (N.SPOON_REF_BY_NAME.get(canon)
                or N.SPOON_REF_BY_NAME.get(N.lookup_name(canon)))
        if base:
            suffix = ("cup" if unit in ("c", "cup", "cups")
                      else "tbsp" if unit.startswith(("tbsp", "tbs", "table"))
                      else "tsp")
            ref = f"{base}_{suffix}"
            if N.ref_exists(ref):
                return {"name": N.display_canonical(canon),
                        "qty": {"kind": "household", "value": val, "unit": suffix,
                                "conversion_ref": ref,
                                "grams": N.ref_grams(ref, val)}}
        return unknown(name)

    # garlic cloves
    mg = re.match(rf"^(?P<qty>{QTY_TOK}(?:\s*-\s*{QTY_TOK})?)\s*"
                  r"cloves?\s+(?:garlic,?\s*)?(?P<name>.*)$", text, re.I)
    if mg and "garlic" in low:
        val = upper_of_range(mg.group("qty"))
        ref = "garlic_clove"
        if val and N.ref_exists(ref):
            return {"name": N.display_canonical(N.normalize_name("garlic")),
                    "qty": {"kind": "household", "value": val, "unit": "clove",
                            "conversion_ref": ref, "grams": N.ref_grams(ref, val)}}
        return unknown("garlic")

    # plain counts: "2 large eggs", "1 medium onion"
    mq = re.match(rf"^(?P<qty>{QTY_TOK})\s+(?P<name>.+)$", text)
    if mq:
        val = upper_of_range(mq.group("qty"))
        name_raw = re.sub(r"\([^)]*\)", " ", mq.group("name")).strip()
        canon = N.normalize_name(ingredient_name(name_raw))
        look = N.lookup_name(canon)
        size = N.SIZE_WORDS.search(name_raw)
        look_text = f"{name_raw.lower()} {look}"
        # guards: a different food shares the piece keyword
        if re.search(r"\b(?:green|spring) onions?\b|\bscallions?\b", look_text):
            return unknown(canon)
        if re.search(r"\b(?:cherry|grape) tomatoes?\b", look_text):
            return unknown(canon)
        for rx, ref, ref_size in N.PIECE_REFS:
            if not N.ref_exists(ref):
                continue
            if (rx.search(name_raw.lower()) or rx.search(canon)
                    or rx.search(look)):
                if size and ref_size and size.group(1).lower() != ref_size:
                    break
                return {"name": N.display_canonical(canon),
                        "qty": {"kind": "household", "value": val or 1.0,
                                "unit": ref, "conversion_ref": ref,
                                "grams": N.ref_grams(ref, val or 1.0)}}
        return unknown(canon)

    return unknown(ingredient_name(text))


def build_steps(directions: list[str], ingredient_names: list[str], title: str
                ) -> tuple[list[dict[str, Any]], list[str]]:
    """The NHS conversion (ingest_nhs.build_steps): FSIS endpoints from the
    recipe's own ingredients, reheat checks per step, gate-checked."""
    return N.build_steps(directions, ingredient_names, title)


# Verified NHLBI-food extensions to the shared spoon-name map: added ONLY
# where the suite table carries a matching ref (canned whole peeled tomatoes
# -> the table's canned-diced-tomatoes cup ref; scallions -> the green-onion
# tbsp ref; "fresh/dried <herb>" herbs; "ground black pepper").
NHLBI_SPOON_EXT: dict[str, str] = {
    "canned whole peeled tomatoes": "canned_tomatoes",
    "canned tomatoes": "canned_tomatoes",
    "scallion": "green_onion", "scallions": "green_onion",
    "green onion": "green_onion", "green onions": "green_onion",
    "fresh basil": "basil", "dried basil": "basil",
    "dried oregano": "oregano", "fresh oregano": "oregano",
    "dried thyme": "thyme", "ground black pepper": "black_pepper",
    "ground cumin": "cumin", "fresh parsley": "parsley",
    "fresh cilantro": "cilantro", "fresh mint": "mint",
    # broth normalizes to "stock" in the shared lookup; the "low-sodium"
    # qualifier survives normalization, so key the exact normalized form.
    "low-sodium chicken stock": "chicken_stock",
    "low sodium chicken stock": "chicken_stock",
    "low-sodium vegetable stock": "veg_stock",
}


def classify_credit(credit: str) -> str:
    c = credit.lower()
    if any(t in c for t in COOKBOOK_CREDITS):
        return "ingest"
    # Unrecognized and community-manual credits both fail closed
    # (SOURCES.md section 3: skip or individually clear external credits).
    return "quarantine"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite-dir", required=True)
    ap.add_argument("--pages", required=True)
    ap.add_argument("--mode", choices=["measure", "write"], default="measure")
    ap.add_argument("--debug-slug", default=None,
                    help="print per-line parse results for one slug")
    args = ap.parse_args()

    suite_dir = Path(args.suite_dir)
    sys.path.insert(0, str(suite_dir))
    import rs  # noqa: E402  (suite validator, read-only)

    conv = json.loads((suite_dir / "conversions.json").read_text())
    conv = conv.get("conversions", conv)
    N.CONVERSION_REFS.clear()
    N.CONVERSION_REFS.update(conv.keys())
    N.CONVERSION_TABLE.clear()
    N.CONVERSION_TABLE.update(conv)
    N.SPOON_REF_BY_NAME.update(NHLBI_SPOON_EXT)
    allergens = json.loads((suite_dir / "allergens.json").read_text())
    scanner = rs.AllergenScanner(allergens)
    alias_keys = {k.lower() for k in allergens["ingredient_aliases"]}

    existing = [json.loads(l) for l in N.CORPUS.read_text(encoding="utf-8").splitlines() if l.strip()]
    manifest = json.loads(N.MANIFEST.read_text(encoding="utf-8"))
    records = manifest["records"]

    norm = lambda s: re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()
    seen_keys = {(norm(r["title"]),
                  frozenset(norm(i["name"]) for i in r["ingredients"]))
                 for r in existing}

    pages = sorted(Path(args.pages).glob("*.html"))
    selected: list[dict[str, Any]] = []
    skipped: list[tuple[str, str, str]] = []
    quarantine: list[tuple[str, str, str]] = []
    next_num = 1

    credit_counts: dict[str, int] = {}
    for page in pages:
        parsed_page = parse_nhlbi_page(page)
        if parsed_page is None:
            skipped.append((page.stem, "?", "no title/ingredients/directions"))
            continue
        title = parsed_page["title"]
        cls = classify_credit(parsed_page["credit"])
        credit_counts[cls] = credit_counts.get(cls, 0) + 1
        if cls == "quarantine":
            quarantine.append((parsed_page["slug"], title,
                               f"external/community-manual credit: "
                               f"{parsed_page['credit']!r} (SOURCES.md section 3 trap)"))
            continue

        raw_lines = parsed_page["ingredients"]
        if len(raw_lines) < 3:
            skipped.append((parsed_page["slug"], title,
                            f"only {len(raw_lines)} ingredient lines"))
            continue
        if args.debug_slug == parsed_page["slug"]:
            print(f"=== DEBUG {parsed_page['slug']} ===")
            for x in raw_lines:
                p = parse_ingredient_line(x)
                if p is None:
                    print(f"  NONE    | {x}")
                else:
                    q = p["qty"]
                    extra = (f" grams={q.get('grams')} ref={q.get('conversion_ref')}"
                             if q["kind"] != "unknown" else "")
                    print(f"  {q['kind']:<12}| {x[:60]} -> {p['name']}{extra}")
        parsed = [parse_ingredient_line(x) for x in raw_lines if x.strip()]
        if any(p is None for p in parsed):
            skipped.append((parsed_page["slug"], title, "unparseable line"))
            continue
        resolved = sum(1 for p in parsed if p["qty"]["kind"] != "unknown")
        frac = resolved / len(parsed)
        if frac < MIN_RESOLVE:
            unresolved = [p["name"] for p in parsed if p["qty"]["kind"] == "unknown"]
            skipped.append((parsed_page["slug"], title,
                            f"resolution {frac:.0%} < 95% "
                            f"(unresolved: {', '.join(unresolved[:4])})"))
            continue
        if not parsed_page["servings"]:
            skipped.append((parsed_page["slug"], title, "yield unparseable"))
            continue
        if not parsed_page["minutes"]:
            skipped.append((parsed_page["slug"], title, "time unparseable"))
            continue

        steps, safety_problems = build_steps(parsed_page["directions"],
                                             [p["name"] for p in parsed], title)
        if not steps:
            skipped.append((parsed_page["slug"], title, "no directions parsed"))
            continue
        if safety_problems:
            skipped.append((parsed_page["slug"], title, "food-safety conversion incomplete: "
                            + "; ".join(safety_problems)))
            continue

        cuisine, slots = N.judge(title, [])
        ingredients = [{"name": p["name"], "qty": p["qty"]} for p in parsed]
        claims = N.decide_claims([{"name": p["name"]} for p in parsed],
                                 raw_lines, scanner, allergens, steps)
        unaliased = [p["name"] for p in parsed if p["name"] not in alias_keys]

        oz_lines = [x for x in raw_lines
                    if re.search(r"\boz\b|\bounces?\b", norm_line(x), re.I)]
        prov: dict[str, str] = {
            "source_page": ("https://www.nhlbi.nih.gov/health/heart-healthy-living/"
                            f"healthy-foods/healthy-eating-recipes/{parsed_page['slug']}"),
            "rights_terms": ("NHLBI site public-domain notice; SOURCES.md "
                             "section 3 (per-recipe contributor check)"),
            "adaptation": ("wording adapted for structured steps and thermometer "
                           "doneness (public-domain work; modification permitted)"),
        }
        if oz_lines:
            prov["ingredient_grams"] = (
                "stated ounce quantities converted at exactly 28.3495 g/oz "
                f"(stated: {'; '.join(oz_lines[:3])}); qty kind source_grams")

        selected.append({
            "slug": parsed_page["slug"], "title": title,
            "credit": parsed_page["credit"], "frac": frac,
            "recipe": {
                "rs_version": "1", "id": "", "title": title,
                "cuisine": cuisine, "meal_slots": slots,
                "minutes": parsed_page["minutes"],
                "servings": parsed_page["servings"],
                "ingredients": ingredients, "steps": steps,
                "source_ref": "", "provenance": prov,
            },
            "record": {
                "source_id": "nhlbi_recipes",
                "source_type": "government",
                "origin": "NHLBI federal work (per-recipe contributor check)",
                "license": "public-domain (US government work)",
                "access_date": BUILD_DATE,
                "license_evidence": (
                    f'NHLBI site notice: "{SITE_NOTICE}" (retrieved 2026-10-11, '
                    f'SOURCES.md section 3); NHLBI leaflet: "{LEAFLET_STATEMENT}" '
                    f"({LEAFLET_URL}, retrieved 2026-10-11); page credits "
                    f"{parsed_page['credit']!r}: {prov['source_page']}"),
                "permissions": {"text": True, "images": False,
                                "modification": True, "attribution": True,
                                "caching": True, "offline_use": True},
            },
            "claims_decisions": claims,
            "unaliased": sorted(set(unaliased)),
        })

    print(f"parsed pages: {len(pages)}")
    print(f"credit classification: {credit_counts}")
    print(f"selected (resolution >= {MIN_RESOLVE:.0%}): {len(selected)}")
    print(f"skipped: {len(skipped)}")
    for slug, name, why in skipped[:40]:
        print(f"  SKIP {slug}: {why}")
    print(f"quarantined: {len(quarantine)}")
    for slug, name, why in quarantine:
        print(f"  QUARANTINE {slug}: {why}")

    # deterministic ids: sort by slug
    selected.sort(key=lambda s: s["slug"])
    for s in selected:
        s["recipe"]["id"] = f"fl-{ID_TAG}-{next_num:04d}"
        s["recipe"]["source_ref"] = f"fl-{ID_TAG}-{next_num:04d}"
        next_num += 1

    cov: dict[str, int] = {}
    for s in selected:
        cov[s["recipe"]["cuisine"]] = cov.get(s["recipe"]["cuisine"], 0) + 1
    print(f"selected cuisines: {cov}")
    slots_cov: dict[str, int] = {}
    for s in selected:
        for sl in s["recipe"]["meal_slots"]:
            slots_cov[sl] = slots_cov.get(sl, 0) + 1
    print(f"selected slots: {slots_cov}")
    times_cov: dict[str, int] = {"0-15": 0, "16-30": 0, "31-45": 0,
                                 "46-60": 0, "61+": 0}
    for s in selected:
        m_ = s["recipe"]["minutes"]
        band = ("0-15" if m_ <= 15 else "16-30" if m_ <= 30
                else "31-45" if m_ <= 45 else "46-60" if m_ <= 60 else "61+")
        times_cov[band] += 1
    print(f"selected time bands: {times_cov}")
    n_claims = sum(len(s["claims_decisions"]) for s in selected)
    print(f"claims to write: {n_claims}")
    unalias_all = sorted({u for s in selected for u in s["unaliased"]})
    print(f"unaliased names in selected: {unalias_all}")

    if args.mode == "measure":
        print("\n(measure mode: nothing written)")
        return 0

    added: list[dict[str, Any]] = []
    for s in selected:
        r = s["recipe"]
        key = (norm(r["title"]),
               frozenset(norm(i["name"]) for i in r["ingredients"]))
        if key in seen_keys:
            print(f"dedupe skip: {r['title']!r}")
            continue
        seen_keys.add(key)
        r["claims"] = s["claims_decisions"]
        added.append(s)

    with N.CORPUS.open("a", encoding="utf-8", newline="\n") as f:
        for s in added:
            f.write(json.dumps(s["recipe"], ensure_ascii=False) + "\n")
    for s in added:
        records[s["recipe"]["source_ref"]] = s["record"]
    N.MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
                          encoding="utf-8")
    print(f"\nappended {len(added)} NHLBI recipes; corpus now has "
          f"{len(existing) + len(added)} recipes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
