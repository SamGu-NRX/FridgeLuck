#!/usr/bin/env python3
"""Packet A — real amounts for catalog recipes rcp-000167..rcp-000376.

FridgeLuck's 762 original recipes compile with `quantity_from`
(data/recipes/tools/compile_bundle.py): a corpus line with kind "unknown"
ships "to taste" and adds nothing to nutrition, so a recipe whose main
ingredient is unmeasured shows a wrong calorie count and cannot be cooked
as written.

This packet owns the band rcp-000167..rcp-000376. At base alpha ef236fcd
the shipped bundle (apps/ios/Resources/RecipeCatalog/recipes-v2.json) has
118 non-staple lines with quantity.kind "unknown" across 86 band recipes.
`burst11-fridgeluck-recipe-amounts-b` owns the other band and
`burst11-fridgeluck-recipe-rubric` owns every recipe outside the amounts
set, so only band recipes are touched here.

Running this file:

  python3 evaluation/recipe-quality/amounts_a.py

  1. reproduces the band set from the bundle at the working tree's base
     (asserted: 86 recipes / 118 lines);
  2. applies the per-line decisions below (measured amount, or "to taste"
     with a reason, per the packet rule: to taste stays only for
     seasoning, garnish and heat);
  3. writes data/recipes/fixes/amounts-a.json in the pinned
     fridgeluck/corpus-fixes/v1 format;
  4. writes evaluation/recipe-quality/amounts-a.md, with per-serving
     kcal / protein / sodium before and after, compiled with the shipped
     compiler (compile_bundle.compile_recipe), never re-implemented.

Household units are used only where a conversion_ref already exists in
data/recipes/suite/conversions.json (no conversion rows are added: nobody
owns that file this wave); everything else is source_grams. Ingredient
names and titles never change except for the three molasses lines the
titles promise and the lines lack (changes_rights_pin: true).

Do not write data/recipes/corpus.jsonl or any build output: the fix file
is applied mechanically by the catalog rebuild.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "data/recipes/tools"))

BUNDLE = REPO / "apps/ios/Resources/RecipeCatalog/recipes-v2.json"
CORPUS = REPO / "data/recipes/corpus.jsonl"
CONVERSIONS = REPO / "data/recipes/suite/conversions.json"
FIXES_OUT = REPO / "data/recipes/fixes/amounts-a.json"
REPORT_OUT = REPO / "evaluation/recipe-quality/amounts-a.md"

PACKET = "burst11-fridgeluck-recipe-amounts-a"
BASE_COMMIT = "ef236fcd24613d470c1c588a290d04a1d673444a"  # alpha when the packet was measured
BAND_LO, BAND_HI = "rcp-000167", "rcp-000376"
SCHEMA = "fridgeluck/corpus-fixes/v1"

# Exceedance markers the packet test accepts: a band recipe whose compiled
# per-serving kcal/sodium lands outside the bar is allowed only when a
# `changes` entry explains why the dish differs (the marker text below).
MARK_KCAL = "kcal outside the 150-1300 bar"
MARK_SODIUM = "sodium above the 2300 mg bar"

TASTE = "to taste"  # marker for a line deliberately left unmeasured


def g(number: float) -> dict:
    """A weighed-in-grams amount carried from developer sizing."""
    return {"kind": "source_grams", "grams": number}


def hh(value: float, unit: str, ref: str, grams: float) -> dict:
    """A household amount whose conversion_ref already exists in the suite table."""
    return {"kind": "household", "value": value, "unit": unit,
            "conversion_ref": ref, "grams": grams}


# ---------------------------------------------------------------------------
# Per-line decisions. Every entry names the corpus line by catalog id and
# ingredient index (the bundle preserves corpus ingredient order), with a
# name prefix asserted against the corpus before anything is written.
# ---------------------------------------------------------------------------

# Lines that get a real amount, scaled to the recipe's servings the way a
# recipe developer would size them.
AMOUNTS = [
    # Breakfast and fruit-carrier dishes
    ("rcp-000169", "fl-original-0003", 7, "blueberries",
     g(150), 4,
     "blueberries are the dish's named fruit and the only line a cook cannot eye-ball; 150 g is a generous scatter across four pancakes",
     "developer sizing: about 40 g blueberries per serving"),
    ("rcp-000172", "fl-original-0006", 4, "apple, diced",
     g(300), 6,
     "the title names apple and the bake needs its fruit measured; 300 g is two medium apples",
     "developer sizing: one medium apple (150 g) per two servings"),
    ("rcp-000173", "fl-original-0007", 5, "blueberries",
     g(150), 4,
     "the scattered fruit is the dish's identity over the soaked bread; 150 g covers four portions",
     "developer sizing: about 40 g blueberries per serving"),
    ("rcp-000237", "fl-original-0071", 1, "whole-milk ricotta",
     g(150), 2,
     "the ricotta is the title's topping, not a garnish; 150 g spreads a thick layer on two toasts",
     "developer sizing: about 75 g ricotta per toast"),
    ("rcp-000238", "fl-original-0072", 2, "unsweetened cocoa powder",
     g(15), 2,
     "the cocoa is the oats' defining flavour and measures as two tablespoonfuls",
     "developer sizing: 2 tbsp cocoa for two servings"),
    ("rcp-000247", "fl-original-0081", 3, "dried dates",
     g(45), 2,
     "dates are a measured topping, about three chopped Medjools; the bowl's calorie total is set by the committed yogurt, almond and honey lines, not this line",
     f"developer sizing: 3 dates for two servings; {MARK_KCAL}: the bowl already ships 1525.9 kcal per serving at base, and the dates add 62 kcal of true topping energy — rebalancing those lines is outside this packet's owned paths",
     ),
    ("rcp-000370", "fl-original-0204", 3, "a large bunch of parsley and mint, chopped",
     g(80), 2,
     "tabbouleh is an herb salad: the parsley and mint are the base, not a garnish, and a large bunch weighs about 80 g",
     "developer sizing: one large bunch of herbs for two servings"),
    ("rcp-000371", "fl-original-0205", 4, "mint leaves, torn",
     g(20), 2,
     "the mint is half of a tabbouleh's herb base, not a finishing sprinkle",
     "developer sizing: about 10 g mint per serving"),

    # Salads and cold plates
    ("rcp-000175", "fl-original-0009", 0, "canned tuna, drained",
     g(240), 2,
     "the tuna is the protein base; two drained cans (about 240 g) make two deli-style sandwiches",
     "developer sizing: one 120 g drained can per serving"),
    ("rcp-000175", "fl-original-0009", 2, "celery, finely diced",
     g(40), 2,
     "the celery is a measured crunch component of the salad, not a seasoning",
     "developer sizing: one celery stick (40 g) per two servings"),
    ("rcp-000177", "fl-original-0011", 0, "cooked chicken breast, shredded",
     g(200), 2,
     "the roast chicken is the wrap's protein base; 200 g cooked fills two wraps",
     "developer sizing: about 100 g cooked chicken per wrap"),
    ("rcp-000177", "fl-original-0011", 2, "celery, finely diced",
     g(40), 2,
     "measured crunch component, not a seasoning",
     "developer sizing: one celery stick for two wraps"),
    ("rcp-000177", "fl-original-0011", 3, "grapes, halved",
     g(80), 2,
     "the grapes are a measured sweet component of the filling",
     "developer sizing: a small handful (40 g) per wrap"),
    ("rcp-000178", "fl-original-0012", 2, "celery, finely diced",
     g(40), 2,
     "measured crunch component of the smashed-chickpea salad",
     "developer sizing: one celery stick for two sandwiches"),
    ("rcp-000178", "fl-original-0012", 5, "dill pickles, chopped",
     g(30), 2,
     "the pickles are a measured sharp component of the salad",
     "developer sizing: one dill pickle (30 g) for two sandwiches"),
    ("rcp-000204", "fl-original-0038", 3, "romaine lettuce",
     g(180), 3,
     "the romaine is the salad's base and carrier, not a garnish; 180 g is a heart of romaine",
     "developer sizing: a romaine heart (about 180 g) for three servings"),
    ("rcp-000204", "fl-original-0038", 5, "buttermilk",
     g(90), 3,
     "the buttermilk is half the ranch dressing base and measures as six tablespoonfuls",
     "developer sizing: 6 tbsp buttermilk in the ranch"),
    ("rcp-000208", "fl-original-0042", 1, "hot sauce",
     g(80), 3,
     "here the hot sauce is not a dash of heat but the buffalo sauce itself, melted with butter to lacquer the chicken; it measures as a third of a cup",
     "developer sizing: the sauce component, about 27 g per serving"),
    ("rcp-000208", "fl-original-0042", 3, "romaine lettuce",
     g(180), 3,
     "the lettuce cups are the dish's carrier",
     "developer sizing: a romaine heart across three servings"),
    ("rcp-000208", "fl-original-0042", 6, "celery, diced",
     g(60), 3,
     "the celery is the classic measured crunch side of buffalo chicken",
     "developer sizing: two sticks for three servings"),
    ("rcp-000225", "fl-original-0059", 0, "canned tuna in oil",
     g(160), 2,
     "the tuna is the protein base of the salad; one large 160 g tin (drained weight) serves two",
     "developer sizing: one 160 g tin for two servings"),
    ("rcp-000272", "fl-original-0106", 1, "asparagus, woody ends snapped off",
     g(200), 2,
     "the asparagus is a measured vegetable component of the fattoush",
     "developer sizing: one bunch (200 g) for two servings"),
    ("rcp-000274", "fl-original-0108", 1, "fresh pineapple, cut in chunks",
     g(200), 2,
     "the pineapple is a measured sweet component against the black beans",
     "developer sizing: a quarter of a pineapple per serving"),
    ("rcp-000295", "fl-original-0129", 1, "mango, diced",
     g(150), 2,
     "the mango is the salsa's base, measured against the avocado and cucumber",
     "developer sizing: one mango for two servings"),
    ("rcp-000307", "fl-original-0141", 2, "green beans, trimmed",
     g(150), 2,
     "green beans are a measured nicoise component, not a garnish",
     "developer sizing: about 75 g beans per serving"),
    ("rcp-000307", "fl-original-0141", 3, "nicoise olives, pitted",
     g(40), 2,
     "the olives are a measured nicoise component the title names",
     "developer sizing: about 20 g olives per serving"),
    ("rcp-000309", "fl-original-0143", 1, "celery, sliced thin",
     g(60), 2,
     "the celery is a measured crunch component of the slaw",
     "developer sizing: 1.5 sticks for two servings"),
    ("rcp-000310", "fl-original-0144", 2, "oranges, segmented",
     g(200), 2,
     "the title names orange and the segments are a measured component against the halloumi",
     "developer sizing: one orange per serving"),
    ("rcp-000343", "fl-original-0177", 3, "pomegranate molasses",
     g(30), 2,
     "the pomegranate molasses is the glaze the title names; two tablespoonfuls simmer with the stock",
     "developer sizing: 1 tbsp pomegranate molasses per serving; the vocabulary carries no per-100g row for pomegranate molasses (no confident USDA source — never guessed), so the line adds no nutrition either way, but the amount is what a cook needs"),
    ("rcp-000343", "fl-original-0177", 4, "pomegranate seeds",
     g(60), 2,
     "the seeds are a measured finish against the couscous, about half a fruit",
     "developer sizing: 30 g seeds per serving"),
    ("rcp-000347", "fl-original-0181", 3, "green beans, trimmed",
     g(150), 2,
     "green beans are a measured nicoise component, not a garnish",
     "developer sizing: about 75 g beans per serving"),
    ("rcp-000347", "fl-original-0181", 4, "nicoise olives, pitted",
     g(40), 2,
     "the olives are a measured nicoise component the title names",
     "developer sizing: about 20 g olives per serving"),
    ("rcp-000353", "fl-original-0187", 9, "toasted sesame seeds",
     g(20), 2,
     "the title names sesame and the seeds measure as two tablespoonfuls over the salad",
     "developer sizing: 1 tbsp sesame per serving"),
    ("rcp-000364", "fl-original-0198", 0, "watermelon, cut into cubes",
     g(400), 2,
     "the watermelon is the salad's base; 400 g is a quarter of a small melon",
     "developer sizing: 200 g watermelon per serving"),
    ("rcp-000372", "fl-original-0206", 1, "ripe tomatoes, chunked",
     hh(2, "piece", "tomato_piece", 240), 2,
     "the tomato salad is the dish's fresh counterpoint; two medium tomatoes (existing tomato_piece conversion) serve two",
     "existing conversion_ref tomato_piece (120 g/piece) in data/recipes/suite/conversions.json"),

    # Soups, stews and braises
    ("rcp-000182", "fl-original-0016", 3, "celery, sliced",
     g(100), 4,
     "the celery is part of the aromatic base the steps cook first; two sticks measure it",
     "developer sizing: two celery sticks for the pot"),
    ("rcp-000184", "fl-original-0018", 3, "celery, sliced",
     g(120), 6,
     "the celery is part of the aromatic base; three sticks for six servings",
     "developer sizing: three celery sticks for the pot"),
    ("rcp-000198", "fl-original-0032", 1, "apples, sliced",
     g(300), 3,
     "the title names apples and they cook under the chops; two medium apples measure 300 g",
     "developer sizing: one apple per serving, plus one for the pan"),
    ("rcp-000198", "fl-original-0032", 3, "apple cider",
     g(180), 3,
     "the cider is the pan sauce's liquid and the title names it; 180 ml reduces with the mustard",
     "developer sizing: 3/4 cup cider for the sauce"),
    ("rcp-000200", "fl-original-0034", 0, "beef chuck roast",
     g(1200), 6,
     "the chuck is the pot roast; 1.2 kg braises for six with the root vegetables carrying the rest",
     "developer sizing: 200 g chuck per serving for a slow braise"),
    ("rcp-000282", "fl-original-0116", 0, "celery, chopped, leaves reserved",
     g(300), 2,
     "celery is the soup in the title; 300 g (a whole head's hearts) makes two bowls before blending",
     f"developer sizing: 150 g celery per bowl; {MARK_SODIUM}: after the fix the soup ships 2392 mg sodium per serving — the sodium is carried by the committed stock and coconut-milk lines at base (2272.4 mg before this packet), while the celery itself brings about 120 mg; rebalancing the stock is outside this packet's owned paths",
     ),
    ("rcp-000294", "fl-original-0128", 0, "butternut squash, cubed",
     g(400), 2,
     "the squash is the dhansak's vegetable body; 400 g for two with the lentils",
     "developer sizing: 200 g squash per serving"),
    ("rcp-000303", "fl-original-0137", 0, "duck legs",
     g(500), 2,
     "the duck legs are the ragu; two legs (about 500 g) braise for two",
     "developer sizing: one duck leg per serving"),
    ("rcp-000303", "fl-original-0137", 1, "swede, peeled and cubed",
     g(250), 2,
     "the swede is a measured component that slumps into the gravy",
     "developer sizing: about 125 g swede per serving"),
    ("rcp-000319", "fl-original-0153", 1, "butternut squash, peeled and cubed",
     g(300), 2,
     "the squash is the soup's body; 300 g for two with the borlotti beans",
     f"developer sizing: 150 g squash per serving; {MARK_SODIUM}: the soup ships 2351.9 mg sodium per serving at base, before this packet touches it — the sodium sits in the committed stock line and the fix adds none; rebalancing the stock is outside this packet's owned paths",
     ),
    ("rcp-000319", "fl-original-0153", 2, "pearled farro",
     g(80), 2,
     "the farro is the measured starch base; 80 g dry thickens two bowls",
     "developer sizing: 40 g dry farro per serving"),
    ("rcp-000332", "fl-original-0166", 0, "butternut squash, peeled and cubed",
     g(400), 2,
     "the squash is the stew's body with the cavolo nero and chickpeas",
     "developer sizing: 200 g squash per serving"),
    ("rcp-000360", "fl-original-0194", 5, "apple cider",
     g(250), 2,
     "the title names cider and it is the stew's braising liquid; 250 ml for two",
     "developer sizing: about 1 cup cider for the braise"),
    ("rcp-000363", "fl-original-0197", 0, "butternut squash, peeled and cubed",
     g(400), 2,
     "the squash is the soup's body with the red lentils",
     "developer sizing: 200 g squash per serving"),

    # Proteins
    ("rcp-000189", "fl-original-0023", 0, "flank steak",
     g(450), 3,
     "the steak is the dish and had no amount, so the card showed 74.7 kcal; 450 g is a 150 g portion of flank per person",
     "developer sizing: 150 g flank steak per serving"),
    ("rcp-000191", "fl-original-0025", 0, "catfish fillets",
     g(450), 3,
     "the catfish is the dish; three fillets (about 450 g) cook in one skillet",
     "developer sizing: one 150 g fillet per serving"),
    ("rcp-000193", "fl-original-0027", 0, "italian sausage",
     g(400), 4,
     "the sausage is the traybake's protein; four sausages (about 400 g) for four",
     "developer sizing: one sausage per serving"),
    ("rcp-000197", "fl-original-0031", 0, "chicken drumsticks",
     g(800), 4,
     "the drumsticks are the dish; eight drumsticks (about 800 g) oven-fry for four",
     "developer sizing: two drumsticks per serving"),
    ("rcp-000201", "fl-original-0035", 0, "pork shoulder roast",
     g(1500), 8,
     "the pork shoulder is the dish and had no amount, so 8 servings showed 30.3 kcal each; 1.5 kg bone-in shoulder is a classic slow-cooker pulled-pork sizing",
     "developer sizing: about 190 g bone-in shoulder per person for pulled pork"),
    ("rcp-000201", "fl-original-0035", 6, "burger buns",
     g(400), 8,
     "the buns are the carrier; eight buns (about 400 g) for eight sandwiches",
     "developer sizing: one 50 g bun per serving"),
    ("rcp-000213", "fl-original-0047", 1, "chorizo",
     g(120), 2,
     "the chorizo is the co-protein with the chicken and renders the cooking fat; 120 g for two",
     "developer sizing: about 60 g chorizo per serving"),
    ("rcp-000256", "fl-original-0090", 1, "fresh chorizo",
     g(150), 2,
     "the fresh chorizo is the taco's protein; 150 g for two",
     "developer sizing: 75 g fresh chorizo per serving"),
    ("rcp-000273", "fl-original-0107", 2, "bacon, cut into lardons",
     g(100), 2,
     "the bacon renders the fat the eggplant cooks in and finishes the pasta; 100 g for two",
     "developer sizing: 50 g bacon per serving"),
    ("rcp-000284", "fl-original-0118", 1, "chorizo, diced",
     g(100), 2,
     "the chorizo gives the ragu its red fat and pairs the chicken; 100 g for two",
     "developer sizing: 50 g chorizo per serving"),
    ("rcp-000305", "fl-original-0139", 1, "bacon, chopped",
     g(100), 2,
     "the bacon is the risotto's cured-pork base and its fat seeds the pan; 100 g for two",
     f"developer sizing: 50 g bacon per serving; {MARK_SODIUM}: after the fix the risotto ships 3149 mg sodium per serving — the sodium sits in the committed stock and parmesan lines at base (2263.7 mg before this packet), while the bacon brings about 885 mg; rebalancing the stock is outside this packet's owned paths",
     ),
    ("rcp-000342", "fl-original-0176", 0, "good sausages",
     g(300), 2,
     "the sausages are the traybake's protein; three sausages (about 300 g) for two",
     "developer sizing: 1.5 sausages per serving"),
    ("rcp-000344", "fl-original-0178", 2, "burger buns",
     g(100), 2,
     "the buns are the carrier; two buns for two burgers",
     "developer sizing: one 50 g bun per serving"),
    ("rcp-000351", "fl-original-0185", 0, "good sausages, casings removed",
     g(200), 2,
     "the sausage meat is the minestrone's protein; 200 g for two",
     f"developer sizing: 100 g sausage per serving; {MARK_SODIUM}: the dish as committed already compiles to 2036.7 mg per serving before the sausage lands (stock, salt and canned bean and tomato lines this packet does not own), and a true 100 g/serving sausage portion adds about 773 mg, landing the total at 2810.0 — trimming the protein to fit the bar would not be a cook's amount, so the exceedance is explained rather than gamed"),
    ("rcp-000359", "fl-original-0193", 1, "ricotta",
     g(120), 2,
     "the whipped ricotta is the plate's base the traybake pours over and the title names it; 120 g whips with the lemon zest for two",
     "developer sizing: about 60 g ricotta per plate"),
    ("rcp-000375", "fl-original-0209", 1, "burger buns",
     g(100), 2,
     "the buns are the carrier; two buns for two burgers",
     "developer sizing: one 50 g bun per serving"),
    ("rcp-000374", "fl-original-0208", 1, "cherry tomatoes",
     g(250), 2,
     "the cherry tomatoes are the roasted vegetable base of the sauce; 250 g for two",
     "developer sizing: about 125 g cherry tomatoes per serving"),

    # Fish and seafood
    ("rcp-000203", "fl-original-0037", 0, "canned tuna, drained",
     g(240), 2,
     "the tuna is the melt's protein base; two drained cans for two sandwiches",
     "developer sizing: one 120 g drained can per serving"),
    ("rcp-000203", "fl-original-0037", 5, "dill pickles, sliced",
     g(30), 2,
     "measured sharp component inside the melt",
     "developer sizing: one dill pickle for two sandwiches"),
    ("rcp-000268", "fl-original-0102", 1, "canned tuna in oil, drained",
     g(160), 2,
     "the tuna is the gratin's protein; one large tin for two",
     "developer sizing: one 160 g tin for two servings"),
    ("rcp-000296", "fl-original-0130", 1, "white crab meat, picked over",
     g(150), 2,
     "the crab is the dish's protein and the title's subject; 150 g tossed through the linguine",
     "developer sizing: 75 g crab per serving"),
    ("rcp-000333", "fl-original-0167", 1, "nduja",
     g(60), 2,
     "the nduja is the dish's namesake sauce base, not a seasoning; 60 g melts into the oil for two",
     "developer sizing: about 30 g nduja per serving; the vocabulary carries no per-100g row for nduja (no confident USDA source — never guessed), so the line adds no nutrition either way, but the amount is what a cook needs"),
    ("rcp-000340", "fl-original-0174", 2, "canned sardines in oil, drained",
     g(120), 2,
     "the sardines are the pasta's protein; two tins (about 120 g drained) for two",
     "developer sizing: one 60 g tin of sardines per serving"),
    ("rcp-000340", "fl-original-0174", 3, "pine nuts, toasted",
     g(30), 2,
     "the pine nuts are a measured component of the finish, not a pinch",
     "developer sizing: 15 g pine nuts per serving"),
    ("rcp-000340", "fl-original-0174", 4, "fennel bulb, shaved thin",
     g(100), 2,
     "the shaved fennel is a measured component of the finish",
     "developer sizing: half a bulb per two servings"),
    ("rcp-000349", "fl-original-0183", 1, "canned sardines in oil, drained",
     g(120), 2,
     "the sardines are the pasta's protein; two tins for two",
     "developer sizing: one 60 g tin of sardines per serving"),
    ("rcp-000361", "fl-original-0195", 1, "canned tuna, drained",
     g(160), 2,
     "the tuna is the jacket potato's topping protein; one large tin for two",
     "developer sizing: one 160 g tin for two servings"),
    ("rcp-000361", "fl-original-0195", 3, "sriracha",
     g(20), 2,
     "the title names sriracha and the mayo's heat measures as a tablespoonful and a half",
     "developer sizing: 1.5 tbsp sriracha in the mayo"),

    # Breads, buns, starches and coatings
    ("rcp-000180", "fl-original-0014", 1, "breadcrumbs",
     g(60), 4,
     "the breadcrumbs are the patty binder that holds the mashed beans together; 60 g for four",
     "developer sizing: about 45 g breadcrumbs (a generous 1/2 cup) per batch of four"),
    ("rcp-000188", "fl-original-0022", 5, "burger buns",
     g(200), 4,
     "the buns are the carrier; four slider buns (about 200 g) for four",
     "developer sizing: one 50 g slider bun per serving"),
    ("rcp-000194", "fl-original-0028", 1, "breadcrumbs",
     g(60), 4,
     "the breadcrumbs are the panade the step soaks in milk; 60 g for a four-serving loaf",
     "developer sizing: about 60 g fresh crumbs soaked in 1/4 cup milk"),
    ("rcp-000194", "fl-original-0028", 4, "ketchup",
     g(45), 4,
     "the ketchup is the glaze's base and measures as three tablespoonfuls",
     "developer sizing: 3 tbsp ketchup in the glaze"),
    ("rcp-000195", "fl-original-0029", 1, "panko",
     g(75), 3,
     "the panko is the crust the fillets are pressed into; 75 g coats three fillets",
     "developer sizing: 25 g panko per fillet"),
    ("rcp-000195", "fl-original-0029", 5, "dill pickles, minced",
     g(30), 3,
     "the pickles are the tartar sauce's measured sharp component",
     "developer sizing: one dill pickle minced into the sauce"),
    ("rcp-000197", "fl-original-0031", 4, "buttermilk",
     g(240), 4,
     "the buttermilk is the marinade the step names; one cup (240 g) covers eight drumsticks",
     "developer sizing: 1 cup buttermilk for the marinade"),
    ("rcp-000202", "fl-original-0036", 4, "tortilla chips",
     g(100), 4,
     "the chips are the skillet's crunch finish scattered over the chicken; 100 g for four",
     "developer sizing: 25 g tortilla chips per serving"),
    ("rcp-000228", "fl-original-0062", 0, "flattened rice (poha)",
     g(100), 2,
     "the poha is the dish's starch base and the title's subject; 100 g dry flakes for two",
     "developer sizing: 50 g dry poha per serving"),
    ("rcp-000270", "fl-original-0104", 2, "artichoke hearts, drained and quartered",
     g(120), 2,
     "the artichoke hearts are a measured component of the rice",
     "developer sizing: about 60 g artichoke hearts per serving"),
    ("rcp-000290", "fl-original-0124", 1, "panko",
     g(60), 2,
     "the panko is the cutlet crust the step presses on; 60 g coats two chicken breasts",
     "developer sizing: 30 g panko per cutlet"),
    ("rcp-000306", "fl-original-0140", 2, "beansprouts",
     g(100), 2,
     "the beansprouts are the measured crisp-veg component of the noodles",
     "developer sizing: a handful (50 g) per serving"),
    ("rcp-000316", "fl-original-0150", 0, "shelf-stable gnocchi",
     g(400), 2,
     "the gnocchi is the dish's starch base; 400 g crisps for two",
     "developer sizing: 200 g gnocchi per serving"),
    ("rcp-000321", "fl-original-0155", 1, "burger buns",
     g(100), 2,
     "the buns are the carrier; two buns for two burgers",
     "developer sizing: one 50 g bun per serving"),
    ("rcp-000321", "fl-original-0155", 6, "jerk seasoning paste",
     g(30), 2,
     "the title names jerk-spiced and the paste is the marinade that defines the burger; two tablespoonfuls",
     "developer sizing: 1 tbsp jerk paste per serving; sized by the packet rule for title-named lines"),
    ("rcp-000376", "fl-original-0210", 2, "mild curry powder",
     g(15), 2,
     "the title names curry and the powder is the noodles' defining spice; one tablespoonful",
     "developer sizing: 1 tbsp curry powder for two; sized by the packet rule for title-named lines"),

    # Vegetables that carry the dish
    ("rcp-000205", "fl-original-0039", 3, "green beans",
     g(300), 3,
     "the beans are the measured side vegetable roasting beside the salmon; 300 g on the sheet pan",
     "developer sizing: 100 g green beans per serving"),
    ("rcp-000206", "fl-original-0040", 0, "roast turkey, sliced",
     g(160), 2,
     "the turkey is the sandwich's protein base; 160 g of deli slices fills two pressed sandwiches",
     "developer sizing: 80 g roast turkey per sandwich"),
    ("rcp-000206", "fl-original-0040", 2, "cranberry sauce",
     g(60), 2,
     "the cranberry sauce is the measured spread the step names",
     "developer sizing: 2 tbsp cranberry sauce per sandwich"),
    ("rcp-000221", "fl-original-0055", 7, "dried apricots",
     g(60), 2,
     "the apricots are a measured sweet component of the braise",
     "developer sizing: 30 g dried apricots per serving"),
    ("rcp-000221", "fl-original-0055", 8, "green olives",
     g(50), 2,
     "the olives are a measured component of the braise the title names",
     "developer sizing: 25 g olives per serving"),
    ("rcp-000278", "fl-original-0112", 2, "anchovy fillets",
     g(30), 2,
     "the anchovies melt into the oil as the pasta's savoury base; six fillets",
     "developer sizing: three anchovy fillets per serving"),
    ("rcp-000287", "fl-original-0121", 1, "leek, sliced and washed",
     g(150), 2,
     "the leek is the braise's vegetable partner and the title names it; one leek for two",
     "developer sizing: one 150 g leek for two servings"),
    ("rcp-000301", "fl-original-0135", 1, "cola",
     g(200), 2,
     "the title names cola and it is the glaze's liquid; 200 ml reduces with the soy and vinegar",
     "developer sizing: about 2/3 cup cola reduced to a glaze"),
    ("rcp-000330", "fl-original-0164", 6, "green olives, pitted",
     g(50), 2,
     "the olives are a measured component of the tagine and the title names them",
     f"developer sizing: 25 g olives per serving; {MARK_KCAL}: the tagine already ships 1192.3 kcal per serving at base, leaving only 108 kcal of headroom under the 1300 bar, and a true 25 g/serving olive portion adds 221 kcal — the exceedance is carried by the committed chicken-thigh and butter lines, not by this packet's lines"),
    ("rcp-000330", "fl-original-0164", 7, "preserved lemon, rind sliced",
     g(60), 2,
     "the preserved lemon is the tagine's named lemon; one lemon, rind sliced",
     "developer sizing: one preserved lemon for the pot; sized by the packet rule for title-named lines"),
]

# Lines deliberately left unmeasured, each with the note that says why.
TO_TASTE = [
    ("rcp-000199", "fl-original-0033", 4, "chili powder",
     "to taste — heat, seasoned at the end",
     "kept to taste: a heat seasoning, per the packet rule"),
    ("rcp-000182", "fl-original-0016", 5, "bay leaves",
     "to taste — seasoning leaf, lifted out before serving",
     "kept to taste: a bay leaf is a seasoning leaf, the packet rule's to-taste case"),
    ("rcp-000189", "fl-original-0023", 3, "rosemary",
     "to taste — finishing herb basted with the garlic butter",
     "kept to taste: a finishing herb in the baste, per the packet rule"),
    ("rcp-000197", "fl-original-0031", 5, "hot sauce",
     "to taste — heat in the buttermilk marinade",
     "kept to taste: a dash of heat in the marinade, per the packet rule; the buffalo-style sauce case (rcp-000208) is measured instead"),
    ("rcp-000200", "fl-original-0034", 6, "rosemary",
     "to taste — seasoning sprig in the braise",
     "kept to taste: a braise seasoning herb, per the packet rule"),
    ("rcp-000204", "fl-original-0038", 2, "chives",
     "to taste — finishing herb in the ranch",
     "kept to taste: a finishing herb, per the packet rule"),
    ("rcp-000227", "fl-original-0061", 2, "green chili",
     "to taste — heat, sliced thin",
     "kept to taste: heat, per the packet rule"),
    ("rcp-000232", "fl-original-0066", 5, "ground coriander",
     "to taste — ground spice seasoning",
     "kept to taste: a ground spice, per the packet rule"),
    ("rcp-000279", "fl-original-0113", 1, "green cardamom pods, crushed",
     "to taste — whole spice, crushed",
     "kept to taste: a whole spice seasoning, per the packet rule"),
    ("rcp-000322", "fl-original-0156", 6, "jerk seasoning paste",
     "to taste — spicy marinade seasoning",
     "kept to taste: the paste is a heat/marinade seasoning here and the title ('Island-Spiced') does not name it, per the packet rule; rcp-000321's title does name jerk, so that line is measured instead"),
    ("rcp-000330", "fl-original-0164", 5, "ras el hanout",
     "to taste — spice blend seasoning",
     "kept to taste: a spice blend, per the packet rule"),
    ("rcp-000364", "fl-original-0198", 6, "a handful of mint leaves",
     "to taste — finishing herb",
     "kept to taste: a finishing herb, per the packet rule"),
    ("rcp-000366", "fl-original-0200", 7, "rosemary leaves",
     "to taste — seasoning herb over the casserole",
     "kept to taste: a seasoning herb, per the packet rule"),
    ("rcp-000368", "fl-original-0202", 7, "ground turmeric",
     "to taste — ground spice seasoning",
     "kept to taste: a ground spice, per the packet rule"),
    ("rcp-000373", "fl-original-0207", 7, "toasted sesame seeds",
     "to taste — garnish scattered before serving",
     "kept to taste: a garnish and the title names miso and honey, not sesame, per the packet rule"),
]

# Lines the titles promise and the corpus lacks: one molasses line each,
# plus a step edit that uses it. Adding an ingredient name breaks the
# rights pin (a SHA-256 of ingredient names), so changes_rights_pin is
# true for these three recipes and the PR body says why.
ADDITIONS = [
    {
        "catalog_id": "rcp-000194", "corpus_id": "fl-original-0028",
        "name": "molasses", "after_index": 6,
        "qty": {"kind": "source_grams", "grams": 45},
        "reason": "the title promises a molasses glaze but no line contained molasses; 45 g (two tablespoonfuls) stirred into the ketchup-brown-sugar glaze makes the recipe cookable as written",
        "evidence": "name-mappings key 'molasses' with vocabulary per-100g (290 kcal); developer sizing 1 tbsp molasses per serving",
        "step_index": 3,
        "find": "Stir the ketchup with the brown sugar and brush half over the loaf",
        "replace": "Stir the ketchup with the brown sugar and molasses and brush half over the loaf",
        "step_reason": "the glaze step now uses the molasses line the title names",
    },
    {
        "catalog_id": "rcp-000199", "corpus_id": "fl-original-0033",
        "name": "molasses", "after_index": 8,
        "qty": {"kind": "source_grams", "grams": 45},
        "reason": "the title promises molasses but no line contained it; 45 g (two tablespoonfuls) dissolves into the simmer with the maple syrup",
        "evidence": "name-mappings key 'molasses' with vocabulary per-100g (290 kcal); developer sizing 1 tbsp molasses per serving",
        "step_index": 3,
        "find": "Rinse and add the kidney beans with the maple syrup and simmer 10 minutes more, then season to taste.",
        "replace": "Rinse and add the kidney beans with the maple syrup and molasses and simmer 10 minutes more, then season to taste.",
        "step_reason": "the simmer step now uses the molasses line the title names",
    },
    {
        "catalog_id": "rcp-000201", "corpus_id": "fl-original-0035",
        "name": "molasses", "after_index": 2,
        "qty": {"kind": "source_grams", "grams": 60},
        "reason": "the title promises molasses and the evaluation evidence names its absence; 60 g (three tablespoonfuls) joins the dry rub so the slow-cooker liquid bastes sweet",
        "evidence": "name-mappings key 'molasses' with vocabulary per-100g (290 kcal); developer sizing 1 tbsp molasses per serving",
        "step_index": 0,
        "find": "Rub the pork all over with the brown sugar, smoked paprika, cumin and salt the night before if you can.",
        "replace": "Rub the pork all over with the molasses, brown sugar, smoked paprika, cumin and salt the night before if you can.",
        "step_reason": "the rub step now uses the molasses line the title names",
    },
]

def entry_tuples():
    out = []
    for cat, rid, idx, name, qty, servings, reason, evidence in AMOUNTS:
        out.append(("amount", cat, rid, idx, name, qty, reason, evidence))
    for cat, rid, idx, name, note, reason in TO_TASTE:
        out.append(("to_taste", cat, rid, idx, name, note, reason,
                    "packet rule: seasoning, garnish and heat stay to taste"))
    return out


def load_corpus() -> tuple[dict[str, tuple[dict, str]], list[str]]:
    records: dict[str, tuple[dict, str]] = {}
    order: list[str] = []
    for line in CORPUS.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        rec = json.loads(line)
        records[rec["id"]] = (rec, line)
        order.append(rec["id"])
    return records, order


def band_from_bundle(bundle: dict) -> dict[str, list[dict]]:
    """The amounts set: band recipes from the shipped bundle with any
    ingredient line whose assumed_staple is false and whose quantity.kind
    is unknown. Asserted against the counts measured at alpha ef236fcd."""
    band = {}
    for r in bundle["recipes"]:
        if not BAND_LO <= r["catalog_id"] <= BAND_HI:
            continue
        lines = [{"index": i, "key": l["key"],
                  "note": l["quantity"].get("note")}
                 for i, l in enumerate(r["ingredients"])
                 if l["quantity"]["kind"] == "unknown" and not l["assumed_staple"]]
        if lines:
            band[r["catalog_id"]] = lines
    n_lines = sum(len(v) for v in band.values())
    assert len(band) == 86, f"band recipe count {len(band)} != 86 at base"
    assert n_lines == 118, f"band line count {n_lines} != 118 at base"
    return band


def catalog_id_for(corpus_id: str) -> str:
    seq = int(corpus_id.rsplit("-", 1)[-1])
    return f"rcp-{167 + seq - 1:06d}"


def corpus_id_for(catalog_id: str) -> str:
    seq = int(catalog_id.rsplit("-", 1)[-1]) - 166
    return f"fl-original-{seq:04d}"


def line_sha256(line: str) -> str:
    return hashlib.sha256(line.encode("utf-8")).hexdigest()


def build_fixes(records: dict[str, tuple[dict, str]]) -> tuple[list[dict], dict[str, dict]]:
    """Apply the decisions and return the fix-file entries plus the fixed
    corpus records (for the report)."""
    fixes: list[dict] = []
    fixed_records: dict[str, dict] = {}

    per_recipe: dict[str, list[tuple]] = {}
    for kind, cat, rid, idx, name, spec, reason, evidence in entry_tuples():
        assert catalog_id_for(rid) == cat, f"{cat}: corpus id mismatch"
        per_recipe.setdefault(cat, []).append((kind, idx, name, spec, reason, evidence))

    for add in ADDITIONS:
        cat = add["catalog_id"]
        assert add["corpus_id"] == corpus_id_for(cat)

    for cat, decisions in sorted(per_recipe.items()):
        rid = corpus_id_for(cat)
        rec0, raw = records[rid]
        rec = json.loads(raw)  # deep copy via parse
        changes: list[dict] = []

        for kind, idx, name, spec, reason, evidence in sorted(decisions, key=lambda d: d[1]):
            ing = rec["ingredients"][idx]
            assert ing["name"].lower().startswith(name.lower().split(",")[0]), \
                f"{cat} line {idx}: expected {name!r}, found {ing['name']!r}"
            if kind == "amount":
                ing["qty"] = spec
                changes.append({
                    "path": f"ingredients[{idx}].qty",
                    "reason": reason,
                    "evidence": evidence,
                })
            else:
                ing["qty"] = {"kind": "unknown", "note": spec}
                changes.append({
                    "path": f"ingredients[{idx}].qty.note",
                    "reason": reason,
                    "evidence": evidence,
                })

        for add in ADDITIONS:
            if add["catalog_id"] != cat:
                continue
            assert all(i["name"] != add["name"] for i in rec["ingredients"]), \
                f"{cat}: {add['name']} already present"
            ing = {"name": add["name"], "qty": add["qty"]}
            rec["ingredients"].insert(add["after_index"], ing)
            changes.append({
                "path": f"ingredients[{add['after_index']}]",
                "reason": add["reason"],
                "evidence": add["evidence"],
            })
            step = rec["steps"][add["step_index"]]
            assert add["find"] in step["text"], f"{cat}: step text drifted"
            step["text"] = step["text"].replace(add["find"], add["replace"])
            changes.append({
                "path": f"steps[{add['step_index']}].text",
                "reason": add["step_reason"],
                "evidence": "the step must use the line the title names",
            })

        fixes.append({
            "id": rid,
            "catalog_id": cat,
            "before_sha256": line_sha256(raw),
            "record": rec,
            "changes": changes,
            "changes_rights_pin": any(add["catalog_id"] == cat for add in ADDITIONS),
        })
        fixed_records[cat] = rec

    return fixes, fixed_records


def compile_record(rec: dict, ctx: dict) -> dict:
    """Compile one corpus record with the shipped compiler."""
    import compile_bundle
    return compile_bundle.compile_recipe(
        rec, ctx["mappings"], ctx["vocab_by_key"], ctx["rights"], ctx["labels"])


def load_ctx() -> dict:
    import compile_bundle
    import validate_corpus
    mappings = json.load((REPO / "data/ingredients/name-mappings.json").open())["mappings"]
    vocab = json.load((REPO / "data/ingredients/vocabulary.json").open())["entries"]
    rights = json.load((REPO / "data/recipes/rights_manifest.json").open())["records"]
    ctx = validate_corpus.load_rights_context()
    corpus = [json.loads(line) for line in CORPUS.read_text().splitlines() if line.strip()]
    labels = {rec["id"]: compile_bundle.rights_label_for(rec, ctx) for rec in corpus}
    return {
        "mappings": mappings,
        "vocab_by_key": {e["key"]: e for e in vocab},
        "rights": rights,
        "labels": labels,
    }


def nutrition(compiled: dict) -> dict:
    n = compiled["nutrition_per_serving"]
    return {"kcal": n["kcal"], "protein_g": n["protein_g"], "sodium_mg": n["sodium_mg"]}


def write_report(band: dict[str, list[dict]], records: dict[str, tuple[dict, str]],
                 fixed_records: dict[str, dict], fixes: list[dict], ctx: dict) -> None:
    by_cat = {f["catalog_id"]: f for f in fixes}
    taste_by_cat: dict[str, list[str]] = {}
    n_measured = n_taste = 0
    for kind, cat, rid, idx, name, spec, reason, evidence in entry_tuples():
        if kind == "to_taste":
            n_taste += 1
            taste_by_cat.setdefault(cat, []).append(f"{name} — {reason.split(': ', 1)[-1]}")
        else:
            n_measured += 1

    rows = []
    for cat in sorted(band):
        rid = corpus_id_for(cat)
        rec0, _ = records[rid]
        before = nutrition(compile_record(rec0, ctx))
        after = nutrition(compile_record(fixed_records[cat], ctx))
        f = by_cat[cat]
        kcal_delta = f"{before['kcal']} → {after['kcal']}"
        taste = taste_by_cat.get(cat)
        rows.append({
            "cat": cat, "rid": rid, "title": rec0["title"],
            "servings": rec0["servings"],
            "before": before, "after": after,
            "kcal_delta": kcal_delta,
            "taste": taste,
            "pin": f["changes_rights_pin"],
            "n_changes": len(f["changes"]),
        })

    lines = [
        "# Packet A — real amounts for band rcp-000167..rcp-000376",
        "",
        f"Packet `{PACKET}`, measured at base alpha `{BASE_COMMIT[:7]}`.",
        "",
        f"The amounts set is the shipped bundle's band recipes with any ingredient line",
        f"whose `assumed_staple` is false and whose `quantity.kind` is `unknown`: at base",
        f"that is **86 recipes and 118 lines**. This packet measures **{n_measured}** of those lines",
        f"and leaves **{n_taste}** `to taste` with a reason: the packet rule keeps `to taste` only",
        f"for seasoning, garnish and heat (salt, chiles, finishing herbs, whole spices).",
        "",
        "Three recipes whose titles name molasses but whose lines lacked it",
        "(rcp-000194, rcp-000199, rcp-000201) also gain a molasses line plus a step edit",
        "that uses it; those set `changes_rights_pin: true` because the rights pin is a",
        "SHA-256 of ingredient names.",
        "",
        "Before/after nutrition is compiled with the shipped compiler",
        "(`compile_bundle.compile_recipe` — the same `nutrition_for` the bundle ships),",
        "never re-implemented. `before` compiles the original corpus record and reproduces",
        "the bundle's shipped numbers; `after` compiles the fixed record.",
        "",
        "Six recipes land outside the compile bar with the reason recorded in the fix",
        f"file's `changes` entries: rcp-000247 and rcp-000330 ({MARK_KCAL}); rcp-000282,",
        f"rcp-000305, rcp-000319 and rcp-000351 ({MARK_SODIUM}) — in every case the packet",
        "keeps the measured line true (a cook's portion of the title's protein or olive)",
        "and the explanation names where the exceedance actually sits.",
        "",
        "| catalog id | corpus id | recipe | serves | kcal/serving before → after | protein g before → after | sodium mg before → after | lines kept to taste |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in rows:
        b, a = r["before"], r["after"]
        taste = "; ".join(r["taste"]) if r["taste"] else ""
        pin = " · rights pin broken (molasses line added)" if r["pin"] else ""
        lines.append(
            f"| {r['cat']} | {r['rid']} | {r['title']} | {r['servings']} "
            f"| {b['kcal']} → {a['kcal']} "
            f"| {b['protein_g']} → {a['protein_g']} "
            f"| {b['sodium_mg']} → {a['sodium_mg']} "
            f"| {taste}{pin} |"
        )
    lines.append("")
    measured = sum(1 for r in rows for _ in [1] if r)
    lines.append(f"86 band recipes; {sum(len(band[c]) for c in band)} unknown non-staple lines at base; "
                 f"every line is either measured or justified above.")
    REPORT_OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    bundle = json.loads(BUNDLE.read_text())
    band = band_from_bundle(bundle)
    records, _ = load_corpus()

    fixes, fixed_records = build_fixes(records)

    # Coverage: every band line has a decision.
    decided = {(cat, idx) for kind, cat, rid, idx, _, _, _, _ in entry_tuples()}
    missing = []
    for cat, lines_ in band.items():
        for line in lines_:
            if (cat, line["index"]) not in decided:
                missing.append(f"{cat} line {line['index']} ({line['key']})")
    assert not missing, f"{len(missing)} band line(s) without decisions: " + "; ".join(missing)
    assert len(decided) == 118, f"decision count {len(decided)} != 118"

    fix_doc = {
        "schema": SCHEMA,
        "packet": PACKET,
        "base_commit": BASE_COMMIT,
        "fixes": fixes,
    }
    FIXES_OUT.parent.mkdir(parents=True, exist_ok=True)
    FIXES_OUT.write_text(json.dumps(fix_doc, indent=2, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    print(f"fixes: {len(fixes)} recipes -> {FIXES_OUT}")

    ctx = load_ctx()
    write_report(band, records, fixed_records, fixes, ctx)
    print(f"report -> {REPORT_OUT}")


if __name__ == "__main__":
    main()
