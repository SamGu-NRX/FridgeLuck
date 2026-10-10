#!/usr/bin/env python3
"""Generates the frozen eval corpus for the unified-search eval harness.

Deterministic: same input -> byte-identical corpus.json. The output is
committed; this script documents provenance and can regenerate it.

Corpus shape (mirrors SearchDocument fields):
  kitchenIngredient: title/keywords/aliases/category
  kitchenInventory:  title/location/grams/expiry  (canonical id = "<ing>_<loc>")
  recipe:            title/keywords/created_at
  journal:           title/rating/cooked_at

Queries: a small set of hand-pinned queries (v1) plus a large generated set
(500+ total). Expected sets come from a construction-based oracle that
independently re-implements the matching contract: fold to lowercase without
diacritics, tokenize each indexed column (title, subtitle, keywords,
date_tokens) into alphanumeric runs, and match a query when every query token
is a prefix of some document token (underscore-joined tokens act as an
adjacency phrase within one column). The oracle is written from the matching
contract, not from the engine's code path, so an engine regression surfaces
as a metric drop rather than a silent pass.
"""
import json
import os
import calendar
import unicodedata
import re
from itertools import combinations

# ---------- ingredients (24) ----------
INGREDIENTS = [
    (1, "Chicken Breast", ["chicken"], "protein"),
    (2, "Whole Egg", ["eggs"], "protein"),
    (3, "Whole Milk", ["milk"], "dairy"),
    (4, "Butter", [], "dairy"),
    (5, "Cheddar Cheese", ["cheddar"], "dairy"),
    (6, "Greek Yogurt", ["yogurt"], "dairy"),
    (7, "Soy Sauce", [], "condiment"),
    (8, "Olive Oil", [], "condiment"),
    (9, "Garlic", [], "produce"),
    (10, "Yellow Onion", ["onion"], "produce"),
    (11, "Tomato", ["tomatoes"], "produce"),
    (12, "Spinach", [], "produce"),
    (13, "Mushrooms", [], "produce"),
    (14, "Bell Pepper", [], "produce"),
    (15, "Jasmine Rice", ["rice"], "pantry"),
    (16, "Dried Pasta", ["pasta"], "pantry"),
    (17, "Canned Chickpeas", ["chickpeas"], "pantry"),
    (18, "Flour Tortillas", ["tortillas"], "pantry"),
    (19, "Salmon Fillet", ["salmon"], "protein"),
    (20, "Chives", [], "herbs"),
    (21, "Maple Syrup", [], "condiment"),
    (22, "Aubergine", ["eggplant"], "produce"),
    (23, "Courgette", ["zucchini"], "produce"),
    (24, "Cilantro", ["coriander"], "herbs"),
]

# ---------- inventory (9) ----------
# (row_id, title, location, grams, expiry or None)  canonical id = "<row>_<loc>"
INVENTORY = [
    (1, "Chicken Breast", "fridge", 350, "2026-10-13"),
    (2, "Ground Beef", "fridge", 400, "2026-10-12"),
    (3, "Whole Milk", "fridge", 900, "2026-10-20"),
    (4, "Butter", "fridge", 250, "2026-11-01"),
    (5, "Spinach", "fridge", 150, "2026-10-11"),
    (6, "Tomato", "fridge", 300, "2026-10-14"),
    (7, "Jasmine Rice", "pantry", 2000, None),
    (8, "Dried Pasta", "pantry", 900, None),
    (9, "Canned Chickpeas", "pantry", 400, None),
]

# ---------- recipes (30) ----------
RECIPES = [
    (1, "Garlic Butter Chicken", "chicken breast butter garlic", "2026-04-02"),
    (2, "Lemon Herb Chicken", "chicken lemon olive oil", "2026-04-02"),
    (3, "Chicken Noodle Soup", "chicken pasta onion garlic", "2026-04-03"),
    (4, "Creamy Tomato Pasta", "pasta tomato garlic milk", "2026-04-03"),
    (5, "Pesto Pasta Salad", "pasta spinach olive oil", "2026-04-05"),
    (6, "Mushroom Risotto", "rice mushrooms onion butter", "2026-04-06"),
    (7, "Egg Fried Rice", "rice egg soy sauce chives", "2026-04-06"),
    (8, "Salmon Teriyaki", "salmon soy sauce maple syrup", "2026-04-08"),
    (9, "Baked Salmon Fillet", "salmon olive oil garlic", "2026-04-08"),
    (10, "Cheese Quesadilla", "tortillas cheddar butter", "2026-04-10"),
    (11, "Spinach Frittata", "egg spinach cheddar", "2026-04-11"),
    (12, "Veggie Omelette", "egg bell pepper onion mushrooms", "2026-04-11"),
    (13, "Chili Con Carne", "beef tomato onion garlic", "2026-04-13"),
    (14, "Beef Stir Fry", "beef soy sauce bell pepper", "2026-04-13"),
    (15, "Vegetable Stir Fry", "bell pepper mushrooms soy sauce rice", "2026-04-15"),
    (16, "Chickpea Buddha Bowl", "chickpeas rice spinach", "2026-04-16"),
    (17, "Hummus Wrap", "chickpeas tortillas olive oil", "2026-04-17"),
    (18, "Eggplant Parmigiana", "eggplant tomato cheddar", "2026-04-18"),
    (19, "Ratatouille", "eggplant tomato bell pepper onion", "2026-04-19"),
    (20, "Zucchini Fritters", "zucchini egg olive oil", "2026-04-20"),
    (21, "Greek Salad", "tomato onion olive oil", "2026-04-21"),
    (22, "Garlic Mushrooms on Toast", "mushrooms butter garlic", "2026-04-22"),
    (23, "Maple Glazed Carrots", "maple syrup butter", "2026-04-23"),
    (24, "Butter Garlic Rice", "rice butter garlic", "2026-04-24"),
    (25, "Tomato Basil Soup", "tomato onion garlic", "2026-04-25"),
    (26, "Chicken Quesadilla", "chicken tortillas cheddar", "2026-04-26"),
    (27, "Beef Tacos", "beef tortillas tomato", "2026-04-27"),
    (28, "Soy Glazed Salmon Rice Bowl", "salmon soy sauce rice", "2026-04-28"),
    (29, "Spinach Garlic Pasta", "pasta spinach garlic", "2026-04-29"),
    (30, "Chive Egg Scramble", "egg chives butter", "2026-04-30"),
]

# ---------- journal (20) ----------
JOURNAL = [
    (1, "Chicken Noodle Soup", "2026-05-06", 4),
    (2, "Mushroom Risotto", "2026-05-18", 5),
    (3, "Egg Fried Rice", "2026-06-02", 3),
    (4, "Garlic Butter Chicken", "2026-06-09", 5),
    (5, "Creamy Tomato Pasta", "2026-06-21", 4),
    (6, "Salmon Teriyaki", "2026-07-04", 5),
    (7, "Spinach Frittata", "2026-07-11", 2),
    (8, "Chickpea Buddha Bowl", "2026-07-19", 3),
    (9, "Cheese Quesadilla", "2026-07-27", 1),
    (10, "Vegetable Stir Fry", "2026-08-02", 4),
    (11, "Chili Con Carne", "2026-08-08", 5),
    (12, "Chicken Noodle Soup", "2026-08-14", 3),
    (13, "Egg Fried Rice", "2026-08-14", 4),
    (14, "Mushroom Risotto", "2026-08-21", 4),
    (15, "Garlic Butter Chicken", "2026-08-29", 5),
    (16, "Creamy Tomato Pasta", "2026-09-05", 3),
    (17, "Salmon Teriyaki", "2026-09-12", 4),
    (18, "Chickpea Buddha Bowl", "2026-09-19", 2),
    (19, "Cheese Quesadilla", "2026-09-26", 3),
    (20, "Spinach Frittata", "2026-10-03", 5),
]

WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = ["january", "february", "march", "april", "may", "june", "july",
          "august", "september", "october", "november", "december"]
MONTH_ABBR = [m[:3] for m in MONTHS]

# ---------- matching oracle ----------
# Independent re-implementation of the matching contract (see module
# docstring). Mirrors FTS5 unicode61 remove_diacritics tokenization: tokens
# are alphanumeric runs, separators include "_", "-", ".", and punctuation;
# case and diacritics are folded away. A query matches a document when every
# query token is a prefix of some token in any indexed column; a query token
# containing "_" is one term for SearchText.tokens but a separator-split
# phrase for FTS5, so it requires adjacency within a single column.

TOK = re.compile(r"[^\W_]+", re.UNICODE)   # FTS5 unicode61: "_" is a separator
QTOK = re.compile(r"\w+", re.UNICODE)      # SearchText.tokens: "_" is kept


def fold(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(c for c in s if not unicodedata.combining(c))


def tokens(s):
    return TOK.findall(fold(s))


def date_tokens(iso_day):
    y, m, d = (int(x) for x in iso_day.split("-"))
    return " ".join([
        "%04d-%02d-%02d" % (y, m, d), "%04d-%02d" % (y, m),
        "%04d" % y, "%02d" % d, MONTHS[m - 1], MONTH_ABBR[m - 1],
    ])


def pretty_date(iso_day):
    y, m, d = (int(x) for x in iso_day.split("-"))
    wd = WEEKDAYS[calendar.weekday(y, m, d)]
    return "%s, %s %02d, %d" % (wd, MONTHS[m - 1].capitalize(), d, y)


# Per-document column token lists, in FTS column order.
doc_columns = []
docs = []


def add_doc(kind, canonical_id, title, subtitle, keywords, date_tokens_text):
    columns = [tokens(title), tokens(subtitle), tokens(keywords),
               tokens(date_tokens_text)]
    doc_columns.append(columns)
    docs.append({
        "kind": kind,
        "canonicalID": canonical_id,
        "title": title,
        "subtitle": subtitle,
        "keywords": keywords,
        "dateTokens": date_tokens_text,
    })


def doc_matches(columns, qtokens):
    """True when every query token is a prefix of some doc token; tokens
    containing "_" require an adjacent, prefix-matching run in one column."""
    for qt in qtokens:
        if "_" in qt:
            parts = qt.split("_")
            found = False
            for col in columns:
                for i in range(len(col) - len(parts) + 1):
                    if all(col[i + j].startswith(parts[j])
                           for j in range(len(parts))):
                        found = True
                        break
                if found:
                    break
            if not found:
                return False
        else:
            if not any(t.startswith(qt) for col in columns for t in col):
                return False
    return True


def qtokens(s):
    return QTOK.findall(fold(s))


def expected_for(query):
    qts = qtokens(query)
    assert qts, "empty query"
    return sorted(
        d["canonicalID"] for d, cols in zip(docs, doc_columns)
        if doc_matches(cols, qts))


# ---------- build documents ----------
for iid, title, aliases, category in INGREDIENTS:
    add_doc(
        "kitchen_ingredient", "kitchen_ingredient:%d" % iid,
        title, category, " ".join(aliases), "")

for iid, title, location, grams, expiry in INVENTORY:
    add_doc(
        "kitchen_inventory", "kitchen_inventory:%d_%s" % (iid, location),
        title, "%s · %d g in stock" % (location, grams),
        "inventory in stock kitchen", date_tokens(expiry) if expiry else "")

for rid, title, keywords, created in RECIPES:
    add_doc(
        "recipe", "recipe:%d" % rid, title, "30 min · 2 servings",
        keywords, date_tokens(created))

for jid, title, cooked, rating in JOURNAL:
    add_doc(
        "journal", "journal:%d" % jid, title,
        "Cooked %s · rated %d" % (pretty_date(cooked), rating),
        "journal meal logged", date_tokens(cooked))

ids = set(d["canonicalID"] for d in docs)

# ---------- hand-pinned queries (v1) + generated queries ----------
# All expectations come from the construction-based oracle below. The v1
# hand-written expectations encoded top-K intuition and silently omitted
# journal-title matches (e.g. "chicken" also matches "Chicken Noodle Soup"
# journal entries that rank outside the pinned top-6); the oracle computes
# the full matching set instead.
PINNED_QUERIES = [
    "chicken",
    # aubergine matches only the ingredient title; the alias direction is
    # covered by "eggplant" (keywords), since engine-level aliasing lives in
    # the adapters' alias map, not in the corpus.
    "aubergine",
    "eggplant",
    "soy sauce",
    "chickpeas",
    "pasta",
    "cheddar",
    "spinach",
    "milk",
    "garlic chicken",
    "tomato pasta",
    "spinach egg",
    "rice soy",
    "june",
    "july",
    "2026-08-14",
    "august",
    "september",
    # october also matches fridge inventory expiring in October by design.
    "october",
]
QUERIES = [{"q": q, "expected": expected_for(q)} for q in PINNED_QUERIES]

# ---------- generated queries (oracle-computed expectations) ----------
generated = {}


def add_generated(q):
    if not q or q in generated or any(x["q"] == q for x in QUERIES):
        return
    expected = expected_for(q)
    # Skip queries matching everything (uninformative) or nothing (no
    # recall to measure).
    if expected and len(expected) < len(docs):
        generated[q] = expected


all_tokens = sorted({t for cols in doc_columns for col in cols for t in col})

# Family A: every distinct indexed token as a full/prefix query.
for t in all_tokens:
    if len(t) >= 2 and not t.isdigit() or len(t) >= 2:
        add_generated(t)

# Family B: distinct 3-5 character prefixes of indexed tokens.
seen_prefixes = set()
for t in all_tokens:
    for n in (3, 4, 5):
        if len(t) > n:
            p = t[:n]
            if p not in seen_prefixes:
                seen_prefixes.add(p)
                add_generated(p)

# Family C: AND pairs of distinct tokens co-occurring in a document.
pairs = sorted({
    (a, b)
    for cols in doc_columns for col in cols
    for a, b in combinations(sorted(set(col)), 2)
    if len(a) >= 3 and len(b) >= 3 and "_" not in a and "_" not in b
})
for a, b in pairs:
    add_generated("%s %s" % (a, b))

# Family D: AND triples co-occurring in recipe keyword lists.
triples = sorted({
    (a, b, c)
    for rid, title, keywords, created in RECIPES
    for a, b, c in combinations(sorted(set(tokens(keywords))), 3)
})
for a, b, c in triples:
    add_generated("%s %s %s" % (a, b, c))

# Family E: underscore compounds from adjacent title/keyword tokens
# (adjacency phrase semantics in FTS5).
compounds = set()
for iid, title, aliases, category in INGREDIENTS:
    for col in (tokens(title), tokens(" ".join(aliases))):
        for i in range(len(col) - 1):
            if len(col[i]) >= 3 and len(col[i + 1]) >= 3:
                compounds.add((col[i], col[i + 1]))
for a, b in sorted(compounds):
    add_generated("%s_%s" % (a, b))

# Family F: every full date string that appears in a document.
all_dates = sorted({row[4] for row in INVENTORY if row[4]} |
                   {c for _, _, _, c in RECIPES} |
                   {c for _, _, c, _ in JOURNAL})
for iso in all_dates:
    add_generated(iso)

queries = QUERIES + [{"q": q, "expected": ids_}
                     for q, ids_ in sorted(generated.items())]
assert len(queries) >= 500, "corpus must freeze at least 500 queries, got %d" % len(queries)

corpus = {
    "version": "unified-search-eval-corpus-v2",
    "counts": {"ingredients": len(INGREDIENTS), "inventory": len(INVENTORY),
               "recipes": len(RECIPES), "journal": len(JOURNAL)},
    "docs": docs,
    "queries": queries,
}

output_path = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Tests", "SearchCheckTests", "Fixtures", "corpus.json")
with open(output_path, "w") as f:
    json.dump(corpus, f, indent=1)
    f.write("\n")

print("docs: %d  queries: %d (hand-pinned %d, generated %d)"
      % (len(docs), len(queries), len(QUERIES), len(generated)))
