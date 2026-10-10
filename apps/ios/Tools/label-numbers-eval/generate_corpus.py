#!/usr/bin/env python3
"""Deterministic generator for the label-numbers corpus (L2: numerical interpretation).

Every label in the corpus is explicitly synthetic. Layouts follow publicly
documented regulator format references (cited per family in LABEL_FORMAT_REFERENCES)
but no real product name, brand, or value is reproduced: all products, quantities,
and values are generated here from a fixed seed.

The corpus separates *optical transcription* (owned by the grocery OCR eval) from
*numerical interpretation*: every line is already a plausible OCR result for a clean
label, and corrupted variants apply seeded OCR-style damage to the *text* so we can
measure whether arms abstain when a field or its column basis is no longer
observable.

Truth is recorded per (canonical field, column basis) pair, keyed "field@basis"
(container-level fields use the bare field name). Each truth entry records the
value exactly as displayed, the unit as declared, the basis, whether the entry is
observable from the record's own lines, the value's evidence line, and — for
unobservable entries — the reason.

Usage: python3 generate_corpus.py --seed 20261010 --out corpus/labels.jsonl
"""

import argparse
import json
import re
import random
from pathlib import Path

# ---------------------------------------------------------------------------
# Format references (layout references only; all content below is synthetic).
# ---------------------------------------------------------------------------
LABEL_FORMAT_REFERENCES = {
    "us_dual_column": (
        "FDA 21 CFR 101.9 Nutrition Facts label, dual-column per serving / per "
        "package layout (2020 format). Layout reference only; values are synthetic."
    ),
    "ca_bilingual": (
        "Canadian Food Inspection Agency (CFIA) bilingual Nutrition Facts table "
        "format (2021/2022 format); French-only labels permitted. Layout reference "
        "only; values are synthetic."
    ),
    "eu_per100g": (
        "EU Regulation 1169/2011 (FIC) Annex XV nutrition declaration, per 100 g / "
        "100 ml column. Layout reference only; values are synthetic."
    ),
    "eu_per_portion": (
        "EU Regulation 1169/2011 (FIC) Annex XV nutrition declaration with per "
        "portion column in addition to per 100 g / 100 ml. Layout reference only; "
        "values are synthetic."
    ),
}

FAMILIES = list(LABEL_FORMAT_REFERENCES.keys())

CANONICAL_FIELDS = [
    "energy_kcal", "energy_kj", "serving_size", "servings_per_container",
    "fat_g", "carbohydrate_g", "protein_g", "sodium_mg", "salt_g",
]
FIELD_UNITS = {
    "energy_kcal": "kcal", "energy_kj": "kJ", "serving_size": None,
    "servings_per_container": "count", "fat_g": "g", "carbohydrate_g": "g",
    "protein_g": "g", "sodium_mg": "mg", "salt_g": "g",
}

# surface names the generator renders for each field (used by field_name_corrupt
# and re-checked by check_corpus to verify the name is genuinely gone)
FIELD_NAMES = {
    "energy_kcal": ["Calories", "Energy"],
    "energy_kj": ["Energy"],
    "fat_g": ["Fat", "Lipides", "Total Fat"],
    "carbohydrate_g": ["Carbohydrate", "Glucides"],
    "protein_g": ["Protein", "Protéines"],
    "sodium_mg": ["Sodium"],
    "salt_g": ["Salt", "Sel"],
    "serving_size": ["Serving size", "Taille de la portion", "Per ", "pour "],
    "servings_per_container": ["servings per container", "Environ", "portions"],
}

# Column-basis marker regexes. A basis counts as present in a record iff some line
# matches the marker. These are deliberately narrow so unrelated lines ("servings
# per container", "portions") do not spuriously establish a basis.
BASIS_MARKERS = {
    "per_serving": r"(?i)(amount per serving|per serving\b|pour\b)",
    "per_package": r"(?i)per package",
    "per_100g": r"(?i)per 100 g",
    "per_100ml": r"(?i)per 100 ml",
    "per_portion": r"(?i)per portion",
}
BASES = list(BASIS_MARKERS.keys())

KJ_PER_KCAL = 4.184
SALT_PER_SODIUM = 2.5  # EU FIC: salt = sodium x 2.5

# ---------------------------------------------------------------------------
# Synthetic product universe
# ---------------------------------------------------------------------------
US_SERVINGS = [
    "1 cup (228 g)", "2/3 cup (55 g)", "3 cookies (30 g)", "1 container (150 g)",
    "1 tbsp (15 mL)", "1 bottle (500 mL)", "1 packet (42 g)", "2 waffles (70 g)",
    "1 scoop (28 g)", "1 bar (60 g)", "1 slice (38 g)", "1 pouch (120 g)",
]
CA_SERVINGS_EN = [
    "2 tbsp (30 mL)", "3/4 cup (175 g)", "1 container (100 g)", "4 crackers (20 g)",
    "1 muffin (85 g)", "1 tbsp (15 mL)", "1/2 cup (125 mL)", "1 bar (44 g)",
    "10 pieces (50 g)", "1 pouch (90 g)", "1 bowl (60 g)", "2 slices (64 g)",
]
CA_SERVINGS_FR = [
    "2 c. à soupe (30 mL)", "3/4 tasse (175 g)", "1 contenant (100 g)",
    "4 craquelins (20 g)", "1 muffin (85 g)", "1 c. à soupe (15 mL)",
    "1/2 tasse (125 mL)", "1 barre (44 g)", "10 morceaux (50 g)",
    "1 sachet (90 g)", "1 bol (60 g)", "2 tranches (64 g)",
]
EU_PORTIONS = [
    ("one biscuit", 25), ("half pot", 125), ("1 slice", 40),
    ("one yoghurt drink", 250), ("two scoops", 60), ("one muffin", 70),
    ("1 sachet", 30), ("one bowl", 45),
]
US_PRODUCT_NAMES = [
    "Orchard Crunch Cereal", "Meadow Yogurt", "Harvest Granola Bar",
    "Lakeside Tomato Soup", "Pantry Penne", "Golden Waffle Co.",
    "Cedar Trail Mix", "Bluebell Oat Drink", "Ridge Nut Butter",
    "Harbor Rice Pudding", "Fieldroot Crackers", "SunnySyrup Pancakes",
]
CA_PRODUCT_NAMES = [
    "PrairieGranola", "Lait de la Vallée", "Boreal Biscuits", "Sirop du Nord",
    "Chemin des Bleuets", "Terroir Soupe", "Avoine Nordet",
    "Craquelins du lac", "Beurre d'arachide Boréal", "Yaourt Grand Nord",
]
EU_PRODUCT_NAMES = [
    "Alpenhof Müsli", "Bergquell Jogurt", "Nordsee Kräcker", "Landbrot Scheibe",
    "Vitalia Trinkjoghurt", "Kellergut Saft", "Sonnenwiese Waffeln",
    "Talblick Käse", "Elbmarsch Brötchen", "Wiesenthal Suppe",
]


def _round_g(x, decimals=1):
    return round(x, decimals)


def _fmt_g(v, comma=False, decimals=1):
    """Gram value with selectable decimals; whole numbers printed without decimals."""
    s = str(int(round(v))) if abs(v - round(v)) < 1e-9 else f"{v:.{decimals}f}"
    return s.replace(".", ",") if comma else s


def _fmt_int(v, comma=False):
    s = str(int(v))
    return s.replace(".", ",") if comma else s


def _fmt_thousands(v):
    """US-style thousands separator, e.g. 1540 -> '1,540'."""
    return f"{v:,}"


def field(value, basis, observable, evidence_line, fid=None, unit=None, justify=None):
    fid = fid or _CURRENT_FIELD[0]
    return {
        "value": value,
        "unit": unit if unit is not None else FIELD_UNITS[fid],
        "basis": basis,
        "observable": observable,
        "evidence_line": evidence_line,
        "unobservability_reason": justify,
    }


_CURRENT_FIELD = [None]


def put(fields, fid, basis, value, observable, evidence_line, unit=None, justify=None):
    _CURRENT_FIELD[0] = fid
    key = fid if basis is None else f"{fid}@{basis}"
    fields[key] = field(value, basis, observable, evidence_line, fid=fid, unit=unit, justify=justify)


# ---------------------------------------------------------------------------
# Clean label renderers. Each returns (lines, fields_dict).
# ---------------------------------------------------------------------------

def gen_us_dual_column(rnd, group_index, record_no):
    name = rnd.choice(US_PRODUCT_NAMES)
    serving = rnd.choice(US_SERVINGS)
    serv_per_cont = rnd.randint(2, 16)
    grams = float(serving.split("(")[1].rstrip(") ").replace(" g", "").replace(" mL", ""))
    kcal100 = rnd.randint(120, 520)
    fat100 = _round_g(rnd.uniform(0.5, 30.0))
    carb100 = _round_g(rnd.uniform(0.0, 75.0))
    prot100 = _round_g(rnd.uniform(0.0, 25.0))
    sodium100 = rnd.randint(5, 950)

    kcal_s = round(kcal100 * grams / 100.0)
    kcal_p = round(kcal_s * serv_per_cont)
    fat_s = _round_g(fat100 * grams / 100.0)
    carb_s = _round_g(carb100 * grams / 100.0)
    prot_s = _round_g(prot100 * grams / 100.0)
    sodium_s = int(round(sodium100 * grams / 100.0))
    fat_pkg = _round_g(fat_s * serv_per_cont)
    carb_pkg = _round_g(carb_s * serv_per_cont)
    prot_pkg = _round_g(prot_s * serv_per_cont)
    sodium_pkg = sodium_s * serv_per_cont
    dv_fat, dv_fat_pkg = round(fat_s / 78 * 100), round(fat_pkg / 78 * 100)
    dv_sod, dv_sod_pkg = round(sodium_s / 2300 * 100), round(sodium_pkg / 2300 * 100)
    dv_carb, dv_carb_pkg = round(carb_s / 275 * 100), round(carb_pkg / 275 * 100)
    dv_prot, dv_prot_pkg = rnd.randint(5, 35), rnd.randint(10, 80)

    fs, fc = _fmt_g, _fmt_g
    lines = [
        "Nutrition Facts",
        f"{name}",
        f"About {serv_per_cont} servings per container",
        f"Serving size {serving}",
        "Amount per serving      Per package",
        f"Calories {kcal_s}      Calories {kcal_p}",
        "                        % Daily Value*",
        f"Total Fat {fs(fat_s)} g  {dv_fat}%      Total Fat {fs(fat_pkg)} g  {dv_fat_pkg}%",
        f"Sodium {_fmt_thousands(sodium_s)} mg  {dv_sod}%      Sodium {_fmt_thousands(sodium_pkg)} mg  {dv_sod_pkg}%",
        f"Total Carbohydrate {fc(carb_s)} g  {dv_carb}%      Total Carbohydrate {fc(carb_pkg)} g  {dv_carb_pkg}%",
        f"Protein {fs(prot_s)} g  {dv_prot}%      Protein {fs(prot_pkg)} g  {dv_prot_pkg}%",
        "*The % Daily Value (DV) tells you how much a nutrient in a serving of food contributes to a daily diet. 2,000 calories a day is used for general nutrition advice.",
    ]
    f = {}
    put(f, "energy_kcal", "per_serving", str(kcal_s), True, 5)
    put(f, "energy_kcal", "per_package", str(kcal_p), True, 5)
    put(f, "serving_size", None, serving, True, 3)
    put(f, "servings_per_container", None, str(serv_per_cont), True, 2)
    put(f, "fat_g", "per_serving", fs(fat_s), True, 7)
    put(f, "fat_g", "per_package", fs(fat_pkg), True, 7)
    put(f, "carbohydrate_g", "per_serving", fc(carb_s), True, 9)
    put(f, "carbohydrate_g", "per_package", fc(carb_pkg), True, 9)
    put(f, "protein_g", "per_serving", fs(prot_s), True, 10)
    put(f, "protein_g", "per_package", fs(prot_pkg), True, 10)
    put(f, "sodium_mg", "per_serving", str(sodium_s), True, 8)
    put(f, "sodium_mg", "per_package", str(sodium_pkg), True, 8)
    put(f, "salt_g", "per_serving", None, False, None, justify="not_declared")
    put(f, "energy_kj", "per_serving", None, False, None, justify="not_declared")
    return lines, f


def gen_ca_bilingual(rnd, group_index, record_no):
    fr_only = record_no % 4 == 3  # every 4th CA label is French-only, comma decimals
    comma = fr_only
    name = rnd.choice(CA_PRODUCT_NAMES)
    serving = rnd.choice(CA_SERVINGS_FR if fr_only else CA_SERVINGS_EN)
    serv_per_cont = rnd.randint(2, 12)
    kcal = rnd.randint(35, 480)
    fat = _round_g(rnd.uniform(0.0, 22.0))
    carb = _round_g(rnd.uniform(0.0, 60.0))
    prot = _round_g(rnd.uniform(0.0, 20.0))
    sodium = rnd.randint(0, 780)
    dv_fat, dv_carb, dv_sod = round(fat / 78 * 100), round(carb / 275 * 100), round(sodium / 2300 * 100)
    fc, fn = _fmt_g, _fmt_int

    if fr_only:
        lines = [
            "Valeur nutritive",
            f"{name}",
            f"pour {serving}",
            f"Environ {serv_per_cont} portions par contenant",
            f"Calories {fn(kcal, comma)}",
            f"Lipides {fc(fat, comma)} g  {dv_fat} %",
            f"Glucides {fc(carb, comma)} g  {dv_carb} %",
            f"Protéines {fc(prot, comma)} g",
            f"Sodium {fn(sodium, comma)} mg  {dv_sod} %",
            "*5 % ou moins, c'est peu; 15 % ou plus, c'est beaucoup",
        ]
        ev = {"energy_kcal": 4, "serving_size": 2, "servings_per_container": 3,
              "fat_g": 5, "carbohydrate_g": 6, "protein_g": 7, "sodium_mg": 8}
    else:
        lines = [
            "Nutrition Facts / Valeur nutritive",
            f"{name}",
            f"Per {serving} / pour {serving}",
            f"About {serv_per_cont} servings / Environ {serv_per_cont} portions",
            f"Calories {kcal} / Calories {kcal}",
            f"Fat / Lipides {fc(fat, comma)} g  {dv_fat} %",
            f"Carbohydrate / Glucides {fc(carb, comma)} g  {dv_carb} %",
            f"Protein / Protéines {fc(prot, comma)} g",
            f"Sodium / Sodium {sodium} mg  {dv_sod} %",
            "*5% or less is a little, 15% or more is a lot / *5 % ou moins, c'est peu; 15 % ou plus, c'est beaucoup",
        ]
        ev = {"energy_kcal": 4, "serving_size": 2, "servings_per_container": 3,
              "fat_g": 5, "carbohydrate_g": 6, "protein_g": 7, "sodium_mg": 8}

    f = {}
    put(f, "energy_kcal", "per_serving", fn(kcal, comma), True, ev["energy_kcal"])
    put(f, "serving_size", None, serving, True, ev["serving_size"])
    put(f, "servings_per_container", None, str(serv_per_cont), True, ev["servings_per_container"])
    put(f, "fat_g", "per_serving", fc(fat, comma), True, ev["fat_g"])
    put(f, "carbohydrate_g", "per_serving", fc(carb, comma), True, ev["carbohydrate_g"])
    put(f, "protein_g", "per_serving", fc(prot, comma), True, ev["protein_g"])
    put(f, "sodium_mg", "per_serving", fn(sodium, comma), True, ev["sodium_mg"])
    put(f, "salt_g", "per_serving", None, False, None, justify="not_declared")
    put(f, "energy_kj", "per_serving", None, False, None, justify="not_declared")
    return lines, f


def gen_eu_per100g(rnd, group_index, record_no):
    comma = record_no % 2 == 0
    liquid = record_no % 5 == 2
    basis = "per_100ml" if liquid else "per_100g"
    basis_text = "per 100 ml" if liquid else "per 100 g"
    name = rnd.choice(EU_PRODUCT_NAMES)
    kcal = rnd.randint(40, 680)
    kj = round(kcal * KJ_PER_KCAL)
    fat = _round_g(rnd.uniform(0.0, 35.0))
    carb = _round_g(rnd.uniform(0.0, 80.0))
    prot = _round_g(rnd.uniform(0.0, 28.0))
    salt = _round_g(rnd.uniform(0.0, 3.0))
    sodium_g = _round_g(salt / SALT_PER_SODIUM, 2)
    both = record_no % 3 == 0  # declare sodium as well as salt
    fn = _fmt_int

    lines = [
        "Nutrition declaration",
        f"{name}",
        f"Typical values {basis_text}",
        f"Energy {fn(kj, comma)} kJ / {fn(kcal, comma)} kcal",
        f"Fat {_fmt_g(fat, comma)} g",
        f"  of which saturates {_fmt_g(_round_g(fat * 0.35), comma)} g",
        f"Carbohydrate {_fmt_g(carb, comma)} g",
        f"  of which sugars {_fmt_g(_round_g(carb * 0.2), comma)} g",
        f"Protein {_fmt_g(prot, comma)} g",
        f"Salt {_fmt_g(salt, comma)} g",
    ]
    f = {}
    put(f, "energy_kcal", basis, fn(kcal, comma), True, 3)
    put(f, "energy_kj", basis, fn(kj, comma), True, 3)
    put(f, "fat_g", basis, _fmt_g(fat, comma), True, 4)
    put(f, "carbohydrate_g", basis, _fmt_g(carb, comma), True, 6)
    put(f, "protein_g", basis, _fmt_g(prot, comma), True, 8)
    put(f, "salt_g", basis, _fmt_g(salt, comma), True, 9)
    put(f, "sodium_mg", basis, None, False, None, justify="not_declared")
    put(f, "serving_size", None, None, False, None, justify="not_declared")
    put(f, "servings_per_container", None, None, False, None, justify="not_declared")
    if both:
        lines.insert(10, f"Sodium {_fmt_g(sodium_g, comma, 2)} g")
        put(f, "sodium_mg", basis, _fmt_g(sodium_g, comma, 2), True, 10, unit="g")
    lines.append("Reference intake of an average adult (8 400 kJ / 2 000 kcal)")
    return lines, f


def gen_eu_per_portion(rnd, group_index, record_no):
    comma = record_no % 2 == 1
    liquid = record_no % 6 == 4
    name = rnd.choice(EU_PRODUCT_NAMES)
    portion_name, pgrams = rnd.choice(EU_PORTIONS)
    basis100 = "per_100ml" if liquid else "per_100g"
    b100 = "per 100 ml" if liquid else "per 100 g"
    kcal100 = rnd.randint(60, 620)
    kj100 = round(kcal100 * KJ_PER_KCAL)
    fat100 = _round_g(rnd.uniform(0.0, 30.0))
    carb100 = _round_g(rnd.uniform(0.0, 70.0))
    prot100 = _round_g(rnd.uniform(0.0, 25.0))
    salt100 = _round_g(rnd.uniform(0.0, 2.8))
    kcal_p = round(kcal100 * pgrams / 100.0)
    kj_p = round(kcal_p * KJ_PER_KCAL)  # per-basis conversion keeps kJ<->kcal exact on each column
    fat_p = _round_g(fat100 * pgrams / 100.0)
    carb_p = _round_g(carb100 * pgrams / 100.0)
    prot_p = _round_g(prot100 * pgrams / 100.0)
    salt_p = _round_g(salt100 * pgrams / 100.0)
    salt_decl = rnd.random() < 0.6
    fn, fc = _fmt_int, _fmt_g

    lines = [
        "Nutrition declaration",
        f"{name}",
        f"Typical values          {b100}      per portion ({pgrams} g)",
        f"Energy                  {fn(kj100, comma)} kJ      {fn(kj_p, comma)} kJ",
        f"                        {fn(kcal100, comma)} kcal      {fn(kcal_p, comma)} kcal",
        f"Fat                     {fc(fat100, comma)} g      {fc(fat_p, comma)} g",
        f"Carbohydrate            {fc(carb100, comma)} g      {fc(carb_p, comma)} g",
        f"Protein                 {fc(prot100, comma)} g      {fc(prot_p, comma)} g",
    ]
    f = {}
    put(f, "energy_kcal", basis100, fn(kcal100, comma), True, 4)
    put(f, "energy_kcal", "per_portion", fn(kcal_p, comma), True, 4)
    put(f, "energy_kj", basis100, fn(kj100, comma), True, 3)
    put(f, "energy_kj", "per_portion", fn(kj_p, comma), True, 3)
    put(f, "fat_g", basis100, fc(fat100, comma), True, 5)
    put(f, "fat_g", "per_portion", fc(fat_p, comma), True, 5)
    put(f, "carbohydrate_g", basis100, fc(carb100, comma), True, 6)
    put(f, "carbohydrate_g", "per_portion", fc(carb_p, comma), True, 6)
    put(f, "protein_g", basis100, fc(prot100, comma), True, 7)
    put(f, "protein_g", "per_portion", fc(prot_p, comma), True, 7)
    put(f, "sodium_mg", basis100, None, False, None, justify="not_declared")
    put(f, "serving_size", None, None, False, None, justify="not_declared")
    put(f, "servings_per_container", None, None, False, None, justify="not_declared")
    if salt_decl:
        lines.append(f"Salt                     {fc(salt100, comma)} g      {fc(salt_p, comma)} g")
        put(f, "salt_g", basis100, fc(salt100, comma), True, 8)
        put(f, "salt_g", "per_portion", fc(salt_p, comma), True, 8)
    else:
        put(f, "salt_g", basis100, None, False, None, justify="not_declared")
    lines.append("Reference intake of an average adult (8 400 kJ / 2 000 kcal)")
    return lines, f


# ---------------------------------------------------------------------------
# Corruption (seeded OCR-style damage). Corrupted entries become unobservable.
# ---------------------------------------------------------------------------
SUBSTITUTIONS = {"0": ["O", "Q"], "1": ["l", "I"], "5": ["S"], "8": ["B"], "6": ["b"], "9": ["g"], "2": ["Z"], "3": ["Z"], "4": ["A"], "7": ["T"]}


def _numeric_present(value, text):
    """True if the truth value is numerically present as a token in text."""
    from decimal import Decimal, InvalidOperation
    if value is None:
        return False
    try:
        target = Decimal(str(value))
    except InvalidOperation:
        return str(value) in text
    for tok in re.findall(r"\d[\d.,]*", text):
        tok = tok.strip(".,")
        if not tok:
            continue
        for cand in {tok, tok.replace(",", "")}:
            try:
                if Decimal(cand) == target:
                    return True
            except InvalidOperation:
                continue
    return False


def _value_occurrences(line, value):
    """Spans (start, end) where the value's display token occurs in the line.

    Handles plain, thousands-grouped (1,540), and comma-decimal (0,5) display
    conventions, plus plain substring match for string-valued fields.
    """
    val = str(value)
    patterns = [re.escape(val)]
    if val.isdigit():
        try:
            iv = int(val)
        except ValueError:
            iv = None
        if iv is not None and iv >= 1000:
            patterns.append(re.escape(f"{iv:,}"))
        patterns.append(re.escape(val.replace(".", ",")))
    elif val.replace(".", "", 1).isdigit():
        patterns.append(re.escape(val.replace(".", ",")))
    spans = []
    for p in patterns:
        for m in re.finditer(p, line):
            spans.append((m.start(), m.end()))
    return sorted(set(spans))


def corrupt_lines(rnd, lines, fields):
    """Apply one seeded corruption op. Returns (lines, fields, corruption|None).

    Applies only when the op genuinely damages the target's transcription; unobservable
    entries always carry a justification that check_corpus independently verifies.
    """
    candidates = [k for k, d in fields.items() if d["observable"]]
    if not candidates:
        return lines, fields, None
    target = rnd.choice(candidates)
    tinfo = fields[target]
    fid = target.split("@")[0]
    li = tinfo["evidence_line"]
    line = lines[li]
    op = rnd.choice(["digit_substitute", "unit_corrupt", "header_corrupt",
                     "decimal_shred", "field_name_corrupt", "thousands_mangle"])

    if op == "digit_substitute":
        val = tinfo["value"]
        if val is None:
            return lines, fields, None
        occ = _value_occurrences(line, val)  # list of (start, end) spans
        if not occ:
            return lines, fields, None
        span_start, span_end = occ[0]
        digit_pos = [j for j in range(span_start, span_end) if line[j].isdigit()]
        if not digit_pos:
            return lines, fields, None
        pos = rnd.choice(digit_pos)
        offset = pos - span_start
        old = line[pos]
        new = rnd.choice(SUBSTITUTIONS.get(old, ["X"]))
        trial = list(line)
        for (s, e) in occ:
            j = s + offset
            if j < e and trial[j].isdigit():
                trial[j] = new
        trial = "".join(trial)
        if _numeric_present(val, trial):
            return lines, fields, None  # corruption did not destroy the value
        lines[li] = trial
        tinfo.update(observable=False, unobservability_reason="value_not_in_text")
        return lines, fields, {"op": op, "detail": f"digit '{old}'->'{new}' inside value occurrences on line {li}", "affected": [target]}

    if op == "unit_corrupt":
        unit = tinfo["unit"]
        if unit is None or not re.search(rf"(?<![A-Za-z0-9]){re.escape(unit)}(?![A-Za-z0-9])", line):
            return lines, fields, None
        unit_re = re.compile(rf"(?<![A-Za-z0-9]){re.escape(unit)}(?![A-Za-z0-9])")
        lines[li] = unit_re.sub("§", line)
        # every entry on this line sharing the destroyed unit loses it too
        for k, d in fields.items():
            if d["observable"] and d["unit"] == unit and d["evidence_line"] == li:
                d.update(observable=False, unobservability_reason="unit_missing")
        return lines, fields, {"op": op, "detail": f"unit '{unit}' mangled on line {li}", "affected": [target]}

    if op == "header_corrupt":
        basis = tinfo["basis"]
        if basis is None:
            return lines, fields, None
        marker_re = re.compile(BASIS_MARKERS[basis])
        matches = [i for i, l in enumerate(lines) if marker_re.search(l)]
        if not matches:
            return lines, fields, None
        for i in matches:
            lines[i] = marker_re.sub("#", lines[i])
        # every entry on the damaged basis loses its basis evidence
        affected = []
        for k, d in fields.items():
            if d["observable"] and d["basis"] == basis:
                d.update(observable=False, unobservability_reason="basis_header_missing")
                affected.append(k)
        return lines, fields, {"op": op, "detail": f"basis marker for {basis} damaged on lines {matches}", "affected": affected}

    if op == "decimal_shred":
        occ = _value_occurrences(line, tinfo["value"]) if tinfo["value"] is not None else []
        sep_positions = [j for (s, e) in occ for j in range(s, e) if line[j] in ".,"]
        if not sep_positions:
            return lines, fields, None
        i = sep_positions[0]
        lines[li] = line[:i] + "?" + line[i + 1:]
        tinfo.update(observable=False, unobservability_reason="value_not_in_text")
        return lines, fields, {"op": op, "detail": f"decimal separator shredded in value on line {li}", "affected": [target]}

    if op == "field_name_corrupt":
        hits = sorted((w for w in FIELD_NAMES.get(fid, []) if w in line), key=len, reverse=True)
        if not hits:
            return lines, fields, None
        for w in hits:  # longest first so "Total Fat" is not half-replaced by "Fat"
            lines[li] = lines[li].replace(w, w[:len(w) - 1] + "x")
        tinfo.update(observable=False, unobservability_reason="field_name_missing")
        return lines, fields, {"op": op, "detail": f"field name damaged on line {li}", "affected": [target]}

    if op == "thousands_mangle":
        m = re.search(r"\d{1,3},\d{3}", line)
        if not m:
            return lines, fields, None
        i = m.start() + m.group(0).index(",")
        lines[li] = line[:i] + "O" + line[i + 1:]
        tinfo.update(observable=False, unobservability_reason="value_not_in_text")
        return lines, fields, {"op": op, "detail": "thousands separator mangled", "affected": [target]}

    return lines, fields, None


# ---------------------------------------------------------------------------
# Corpus assembly
# ---------------------------------------------------------------------------
GENERATORS = {
    "us_dual_column": gen_us_dual_column,
    "ca_bilingual": gen_ca_bilingual,
    "eu_per100g": gen_eu_per100g,
    "eu_per_portion": gen_eu_per_portion,
}
CLEAN_PER_FAMILY = 60


def build(seed=20261010):
    rnd = random.Random(seed)
    records = []
    rec_no = 1
    for fam in FAMILIES:
        gen = GENERATORS[fam]
        for k in range(CLEAN_PER_FAMILY):
            group = f"LN-G{rec_no:04d}"
            lines, fields = gen(rnd, k, rec_no)
            records.append({
                "record_id": f"LN-{rec_no:04d}", "group_id": group, "variant": "clean",
                "family": fam, "variant_kind": "clean",
                "source": {"kind": "synthetic", "generator": f"gen_{fam}",
                           "reference": LABEL_FORMAT_REFERENCES[fam]},
                "lines": lines, "corruption": None, "fields": fields,
            })
            rec_no += 1
            # one corrupted variant per group, retrying until an op lands
            c = random.Random(seed * 100003 + rec_no)
            cfields = json.loads(json.dumps(fields))
            clines = list(lines)
            corruption = None
            for _ in range(8):
                corruption = corrupt_lines(c, clines, cfields)[2]
                if corruption:
                    break
            # a corruption that damages a line carrying a basis marker (e.g. the
            # serving-size header) invalidates every still-observable entry that
            # claims that basis
            for b in BASES:
                if not any(re.search(BASIS_MARKERS[b], l) for l in clines):
                    for d in cfields.values():
                        if d["observable"] and d["basis"] == b:
                            d.update(observable=False, unobservability_reason="basis_header_missing")
            # a corruption that destroys a value on a shared line (both columns of
            # a dual-column label) invalidates every entry evidenced by that line
            for k, d in cfields.items():
                if not d["observable"]:
                    continue
                ev = d["evidence_line"]
                if ev is None or not (0 <= ev < len(clines)):
                    continue
                v = d["value"]
                gone = v is None or (
                    k.split("@")[0] == "serving_size"
                    and " ".join(str(v).split()).lower() not in " ".join(clines[ev].split()).lower()
                ) or (
                    k.split("@")[0] != "serving_size"
                    and not _value_occurrences(clines[ev], str(v))
                )
                if gone:
                    d.update(observable=False, unobservability_reason="value_not_in_text")
            records.append({
                "record_id": f"LN-{rec_no:04d}", "group_id": group,
                "variant": "corrupted_v1", "family": fam, "variant_kind": "corrupted",
                "source": {"kind": "synthetic", "generator": f"gen_{fam}",
                           "reference": LABEL_FORMAT_REFERENCES[fam]},
                "lines": clines, "corruption": corruption, "fields": cfields,
            })
            rec_no += 1
    return records


def counts_summary(records, seed):
    return {
        "seed": seed,
        "total_records": len(records),
        "groups": len({r["group_id"] for r in records}),
        "by_family": {f: sum(1 for r in records if r["family"] == f) for f in FAMILIES},
        "by_variant_kind": {
            "clean": sum(1 for r in records if r["variant_kind"] == "clean"),
            "corrupted": sum(1 for r in records if r["variant_kind"] == "corrupted"),
        },
        "corruption_ops": {
            op: sum(1 for r in records if r["corruption"] and r["corruption"]["op"] == op)
            for op in sorted({r["corruption"]["op"] for r in records if r["corruption"]})
        },
        "corrupted_variants_with_no_op": sum(1 for r in records if r["variant_kind"] == "corrupted" and not r["corruption"]),
        "observable_truth_entries": sum(1 for r in records for d in r["fields"].values() if d["observable"]),
        "unobservable_truth_entries": sum(1 for r in records for d in r["fields"].values() if not d["observable"]),
        "observable_entries_by_field": {
            f: sum(1 for r in records for k, d in r["fields"].items() if k.split("@")[0] == f and d["observable"])
            for f in CANONICAL_FIELDS
        },
        "observable_entries_by_basis": {
            b: sum(1 for r in records for k, d in r["fields"].items() if d["observable"] and d["basis"] == b)
            for b in BASES + [None]
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=20261010)
    ap.add_argument("--out", default="corpus/labels.jsonl")
    args = ap.parse_args()
    records = build(args.seed)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8") as fh:
        for r in records:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
    summary = counts_summary(records, args.seed)
    (out.parent / "CORPUS_COUNTS.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
