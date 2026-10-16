#!/usr/bin/env python3

"""One-shot generator: facts + identities for every catalog ingredient key the
LeChef canon cannot yet resolve. Evidence-first: single foods get FDA
major-food-allergen status + USDA FDC category; compounds get standard
composition with certainty levels and compositionComplete=false wherever
labels vary by brand. Run once, review the diff, commit, delete or keep."""
import json, re, sys, collections

ROOT = "/home/user/work/burst11-fridgeluck-lechef-catalog-facts"
FACTS = f"{ROOT}/backend/gemini-agent/src/lechef/canon/ingredient-facts/facts.json"
IDENT = f"{ROOT}/backend/gemini-agent/src/lechef/canon/ingredient-facts/identities.json"
BUNDLE = f"{ROOT}/apps/ios/Resources/RecipeCatalog/recipes-v2.json"

RETRIEVED = "2026-10-16"
FDA = f"FDA: Major Food Allergens, https://www.fda.gov/food/food-labeling-nutrition/major-food-allergens (retrieved {RETRIEVED})"
FDC = "USDA FoodData Central, https://fdc.nal.usda.gov/ (retrieved "
def fdc(cat): return f"USDA FoodData Central category: {cat}, https://fdc.nal.usda.gov/ (retrieved {RETRIEVED})"

def fold(n):
    n = n.strip().lower()
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", n))

ALLERGENS = ["milk", "egg", "fish", "crustaceanShellfish", "treeNuts", "peanuts", "wheat", "soy", "sesame"]

facts_doc = json.load(open(FACTS))
ident_doc = json.load(open(IDENT))
facts = facts_doc["facts"]
idents = ident_doc["ingredients"]
bundle = json.load(open(BUNDLE))
bundle_classes = {i["key"]: (i.get("classes") or []) for i in bundle["ingredients"]}

# ---- TS-faithful identity index (LAST write wins) ----
idx = {}
for e in idents:
    idx[fold(e["key"])] = e["key"]
    for s in e.get("synonyms") or []:
        idx[fold(s)] = e["key"]

def resolves(bundle_key):
    f = fold(bundle_key)
    key = idx.get(f, f)
    return key in facts

unresolved = sorted(k for k in bundle_classes if not resolves(k))
print(f"unresolved bundle keys: {len(unresolved)}")

# ---------------- evidence builders ----------------
def ev(kind, ref, note): return {"kind": kind, "ref": ref, "note": note}

def AL(state, e):
    """Canon allergen/diet entry shape: {state, evidence:{kind, ref, note}}"""
    if isinstance(e, dict) and "state" in e and "evidence" in e:
        return e
    return {"state": state, "evidence": e}

def simple_allergens(category, contains=(), free_note=None, overrides=None):
    out = {}
    for t in ALLERGENS:
        if overrides and t in overrides:
            out[t] = AL("unknown", overrides[t]); continue
        if t in contains:
            out[t] = AL("contains", ev_ref("reference", FDA,
                f"derives from {ALLERGEN_NAME[t]}; FDA major food allergen. " + fdc(category)))
        else:
            out[t] = AL("free", ev_ref("reference", FDA, free_note or
                f"single food ({category}); carries no {ALLERGEN_NAME[t]}. " + fdc(category)))
    return out

ALLERGEN_NAME = {"milk": "milk", "egg": "egg", "fish": "fin fish",
                 "crustaceanShellfish": "crustacean shellfish", "treeNuts": "tree nuts",
                 "peanuts": "peanuts", "wheat": "wheat", "soy": "soybeans", "sesame": "sesame"}
def ev_ref(kind, ref, note): return {"kind": kind, "ref": ref, "note": note}

DIET_NOTE = {
    "plant": "plant food; no animal-derived ingredients (diet fact: allowed)",
    "mineral": "mineral/water; no animal-derived ingredients (diet fact: allowed)",
    "meat": "animal flesh; not compatible with vegetarian/vegan diets, and pescatarian diets exclude land-animal flesh (diet fact: violated)",
    "fish": "fin fish; pescatarian diets include fish, vegetarian/vegan do not (diet fact as stated)",
    "shellfish": "crustacean shellfish; pescatarian diets conventionally include shellfish, vegetarian/vegan do not (diet fact as stated)",
    "dairy": "milk product; not compatible with vegan or dairy-free diets, compatible with vegetarian (diet fact as stated)",
    "egg": "egg; not compatible with vegan, compatible with vegetarian (diet fact as stated)",
    "honey": "animal-derived (honey); not compatible with vegan, compatible with vegetarian (diet fact as stated)",
}
def simple_diets(dtype, overrides=None, gf=None, df=None):
    def D(s, note): return {"state": s, "evidence": ev_ref("standard", "diet composition standard", note)}
    d = {}
    if dtype in ("plant", "mineral"):
        for x in ("vegetarian", "vegan", "pescatarian"):
            d[x] = D("allowed", DIET_NOTE[dtype])
        d["dairyFree"] = D("allowed", DIET_NOTE[dtype])
        if gf is not None:
            d["glutenFree"] = D(gf,
                "gluten-free plant food; gluten is the protein of wheat, barley and rye" if gf == "allowed" else "gluten-bearing")
    elif dtype == "meat":
        for x in ("vegetarian", "vegan", "pescatarian"):
            d[x] = D("violated", DIET_NOTE[dtype])
        d["dairyFree"] = D("allowed", "no milk-derived ingredients (diet fact: allowed)")
    elif dtype in ("fish", "shellfish"):
        d["vegetarian"] = D("violated", "aquatic animal flesh; vegetarian/vegan do not eat it (diet fact: violated)")
        d["vegan"] = d["vegetarian"]
        d["pescatarian"] = D("allowed", DIET_NOTE[dtype])
        d["dairyFree"] = D("allowed", "no milk-derived ingredients (diet fact: allowed)")
    elif dtype == "dairy":
        d["vegetarian"] = D("allowed", DIET_NOTE[dtype])
        d["vegan"] = D("violated", DIET_NOTE[dtype])
        d["pescatarian"] = D("allowed", "no fish or flesh; pescatarian-compatible (diet fact: allowed)")
        d["dairyFree"] = D("violated", DIET_NOTE[dtype])
    elif dtype == "egg":
        d["vegetarian"] = D("allowed", DIET_NOTE[dtype])
        d["vegan"] = D("violated", DIET_NOTE[dtype])
        d["pescatarian"] = D("allowed", "no fish or flesh (diet fact: allowed)")
        d["dairyFree"] = D("allowed", "no milk-derived ingredients (diet fact: allowed)")
    elif dtype == "honey":
        d["vegetarian"] = D("allowed", DIET_NOTE[dtype])
        d["vegan"] = D("violated", DIET_NOTE[dtype])
        d["pescatarian"] = D("allowed", "no fish or flesh (diet fact: allowed)")
        d["dairyFree"] = D("allowed", "no milk-derived ingredients (diet fact: allowed)")
    if df is not None:
        d["dairyFree"] = D(df,
            "no milk-derived ingredients (diet fact: allowed)" if df == "allowed" else "milk-derived (diet fact: violated)")
    if overrides:
        for k, v in overrides.items():
            d[k] = {"state": "unknown", "evidence": v} if not (isinstance(v, dict) and "state" in v) else v
    return d

def dstate(s, note): return {"state": s, "evidence": ev_ref("standard", "diet composition standard", note)}
def unk_diet(note): return {"state": "unknown", "evidence": ev_ref("standard", "diet composition standard", note)}

# ---------------- tables ----------------
# SIMPLE: bundle_key -> (display, synonyms, fdc_category, dtype, contains_tokens, opts)
SIMPLE = {}
def S(key, display, cat, dtype, contains=(), syn=(), **opts):
    SIMPLE[key] = (display, [syn] if isinstance(syn, str) else list(syn), cat, dtype, list(contains), opts)

# --- produce & pantry plants ---
S("ackee", "Ackee", "Fruits and Fruit Juices", "plant", note="ripe ackee arils (Jamaican national fruit); only the ripe aril is eaten", aliases_ok=True)
S("allspice", "Allspice", "Spices and Herbs", "plant")
S("nutmeg", "Nutmeg", "Spices and Herbs", "plant", syn=["ground nutmeg"])
S("apple-cider", "Apple cider", "Fruits and Fruit Juices", "plant", note="unfermented pressed apple juice; hard cider is a distinct product", syn=["fresh apple cider"])
S("apricots", "Apricots", "Fruits and Fruit Juices", "plant")
S("artichoke-hearts", "Artichoke hearts", "Vegetables and Vegetable Products", "plant")
S("asparagus", "Asparagus", "Vegetables and Vegetable Products", "plant")
S("asian-pear", "Asian pear", "Fruits and Fruit Juices", "plant", syn=["nashi pear"])
S("bamboo-shoots", "Bamboo shoots", "Vegetables and Vegetable Products", "plant")
S("bay", "Bay leaf", "Spices and Herbs", "plant", syn=["bay leaves"])
S("beetroot", "Beetroot", "Vegetables and Vegetable Products", "plant", syn=["beets"])
S("besan", "Besan (chickpea flour)", "Legumes and Legume Products", "plant", syn=["gram flour", "chickpea flour"], note="ground chana chickpeas; gluten-free legume flour")
S("black-eyed-peas", "Black-eyed peas", "Legumes and Legume Products", "plant", syn=["cowpeas"])
S("black-tea", "Black tea", "Beverages", "plant", syn=["tea"])
S("blueberries", "Blueberries", "Fruits and Fruit Juices", "plant")
S("borlotti-beans", "Borlotti beans", "Legumes and Legume Products", "plant", syn=["cranberry beans"])
S("brown-rice", "Brown rice", "Cereal Grains and Pasta", "plant", syn=["wholegrain rice"])
S("butternut-squash", "Butternut squash", "Vegetables and Vegetable Products", "plant")
S("cabbage", "Cabbage", "Vegetables and Vegetable Products", "plant")
S("callaloo-greens", "Callaloo greens", "Vegetables and Vegetable Products", "plant", note="amaranth or taro leaves used Caribbean-style", syn=["callaloo"])
S("canned-tomatoes", "Canned tomatoes", "Vegetables and Vegetable Products", "plant", syn=["tinned tomatoes"], note="tomatoes with juice or puree and salt")
S("capers", "Capers", "Vegetables and Vegetable Products", "plant", syn=["caper berries"], note="pickled flower buds; brine is salt and vinegar")
S("caraway", "Caraway seeds", "Spices and Herbs", "plant", syn=["caraway"])
S("cauliflower", "Cauliflower", "Vegetables and Vegetable Products", "plant")
S("cayenne", "Cayenne pepper", "Spices and Herbs", "plant", syn=["cayenne"])
S("chiles", "Chiles", "Vegetables and Vegetable Products", "plant", syn=["hot peppers", "fresh chilies"], note="fresh or dried hot peppers; chipotle is smoked jalapeno")
S("chives", "Chives", "Spices and Herbs", "plant", syn=["chive"])
S("cinnamon", "Cinnamon", "Spices and Herbs", "plant", syn=["cinnamon sticks", "ground cinnamon"])
S("cocoa-powder", "Cocoa powder", "Sweets", "plant", syn=["unsweetened cocoa"], note="defatted ground cacao; chocolate liquor allergen-free at this purity")
S("coffee", "Coffee", "Beverages", "plant", syn=["ground coffee", "brewed coffee"])
S("coriander", "Coriander seeds", "Spices and Herbs", "plant", syn=["coriander seed"])
S("cranberries", "Cranberries", "Fruits and Fruit Juices", "plant")
S("daikon", "Daikon", "Vegetables and Vegetable Products", "plant", syn=["daikon radish", "mooli"])
S("dates", "Dates", "Fruits and Fruit Juices", "plant", syn=["medjool dates"])
S("dill", "Dill", "Spices and Herbs", "plant", syn=["fresh dill", "dill weed"])
S("duck-legs", "Duck legs", "Poultry Products", "meat", syn=["duck leg"])
S("eggplant", "Eggplant", "Vegetables and Vegetable Products", "plant", syn=["aubergine"])
S("egusi-seeds", "Egusi seeds", "Nut and Seed Products", "plant", syn=["egusi"], note="gourd (melon) seeds ground for West African soups; cucurbit seeds, not tree nuts")
S("fava-beans", "Fava beans", "Legumes and Legume Products", "plant", syn=["broad beans"])
S("fennel-bulb", "Fennel bulb", "Vegetables and Vegetable Products", "plant", syn=["fennel"])
S("five-spice-powder", "Five-spice powder", "Spices and Herbs", "plant", syn=["chinese five spice"], complete=False,
  note="ground spice blend (star anise, cassia/cinnamon, cloves, fennel seed, Sichuan peppercorn); pure spices, no major allergens; blends vary")
S("flattened-rice", "Flattened rice", "Cereal Grains and Pasta", "plant", syn=["poha", "beaten rice"])
S("galangal", "Galangal", "Spices and Herbs", "plant", syn=["greater galangal"])
S("glass-noodles", "Glass noodles", "Cereal Grains and Pasta", "plant", syn=["cellophane noodles", "bean threads"],
  note="starch noodles (mung bean or sweet potato) and water; gluten-free")
S("grape-leaves", "Grape leaves", "Vegetables and Vegetable Products", "plant", syn=["vine leaves"], note="brined or jarred leaves")
S("grapes", "Grapes", "Fruits and Fruit Juices", "plant")
S("green-beans", "Green beans", "Vegetables and Vegetable Products", "plant", syn=["string beans"])
S("green-cardamom", "Green cardamom", "Spices and Herbs", "plant", syn=["cardamom pods", "cardamom"])
S("green-chili", "Green chili", "Vegetables and Vegetable Products", "plant", syn=["green chilies", "green chillies"])
S("green-papaya", "Green papaya", "Vegetables and Vegetable Products", "plant", syn=["papaya"], note="unripe papaya used as a vegetable (som tam)")
S("ground-turmeric", "Ground turmeric", "Spices and Herbs", "plant", syn="ALIAS:turmeric")
S("ground-coriander", "Ground coriander", "Spices and Herbs", "plant", syn="ALIAS:coriander")
S("sweet-potato-noodles", "Sweet potato noodles", "Cereal Grains and Pasta", "plant", syn="ALIAS:glass-noodles")
S("sesame", "Sesame seeds", "Nut and Seed Products", "plant", contains=["sesame"], note="whole sesame seeds; sesame is an FDA major food allergen")
S("pectin", "Pectin", "Sweets", "plant", syn=["fruit pectin"], note="fruit-derived gelling agent (citrus or apple peel); no major allergens")
S("haddock", "Haddock", "Finfish and Shellfish Products", "fish", contains=["fish"])
S("hominy", "Hominy", "Vegetables and Vegetable Products", "plant", note="lime-treated (nixtamalized) dried corn")
S("jerk-seasoning", "Jerk seasoning", "Spices and Herbs", "plant", syn=["jerk rub"], complete=False,
  note="dry rub of allspice, thyme, scotch bonnet, garlic, onion, salt and spices; marinade versions may add soy sauce - check the label")
S("kale", "Kale", "Vegetables and Vegetable Products", "plant")
S("kaffir-lime", "Makrut (kaffir) lime leaves", "Spices and Herbs", "plant", syn=["kaffir lime leaves", "makrut lime"])
S("ketchup", "Ketchup", "Soups, Sauces, and Gravies", "plant", syn=["tomato ketchup"], complete=False,
  note="tomato concentrate, vinegar, sugar, salt and spices; no FDA major allergens in standard recipes")
S("leeks", "Leeks", "Vegetables and Vegetable Products", "plant")
S("lemongrass", "Lemongrass", "Spices and Herbs", "plant", syn=["fresh lemongrass"])
S("millet", "Millet", "Cereal Grains and Pasta", "plant")
S("millet-flour", "Millet flour", "Cereal Grains and Pasta", "plant", note="ground millet; gluten-free grain flour")
S("mango", "Mango", "Fruits and Fruit Juices", "plant")
S("maple-syrup", "Maple syrup", "Sweets", "plant")
S("okra", "Okra", "Vegetables and Vegetable Products", "plant", syn=["lady fingers"])
S("olives", "Olives", "Fruits and Fruit Juices", "plant", syn=["green olives", "black olives"])
S("orange-juice", "Orange juice", "Fruits and Fruit Juices", "plant")
S("oranges", "Oranges", "Fruits and Fruit Juices", "plant")
S("oregano", "Oregano", "Spices and Herbs", "plant", syn=["dried oregano"])
S("paprika", "Paprika", "Spices and Herbs", "plant", syn=["ground paprika"])
S("pickles", "Pickles", "Vegetables and Vegetable Products", "plant", syn=["dill pickles", "pickled cucumbers"])
S("pineapple", "Pineapple", "Fruits and Fruit Juices", "plant")
S("plantains", "Plantains", "Fruits and Fruit Juices", "plant", syn=["plantain"])
S("pomegranate-molasses", "Pomegranate molasses", "Sweets", "plant", syn=["pomegranate syrup"], note="reduced pomegranate juice, sometimes with sugar")
S("pomegranate-seeds", "Pomegranate seeds", "Fruits and Fruit Juices", "plant", syn=["pomegranate arils"])
S("potato-starch", "Potato starch", "Cereal Grains and Pasta", "plant", syn=["potato starch flour"])
S("prunes", "Prunes", "Fruits and Fruit Juices", "plant", syn=["dried plums"])
S("pumpkin", "Pumpkin", "Vegetables and Vegetable Products", "plant")
S("radishes", "Radishes", "Vegetables and Vegetable Products", "plant", syn=["radish"])
S("ras-el-hanout", "Ras el hanout", "Spices and Herbs", "plant", complete=False,
  note="Moroccan ground-spice blend; pure spices, no major allergens; recipes vary by shop")
S("red-cabbage", "Red cabbage", "Vegetables and Vegetable Products", "plant", syn=["purple cabbage"])
S("red-palm-oil", "Red palm oil", "Fats and Oils", "plant", syn=["palm oil"], note="unrefined elaeis oil; no major allergens")
S("red-pepper", "Red pepper", "Vegetables and Vegetable Products", "plant", syn=["red bell pepper", "red capsicum"])
S("rice-cakes", "Rice cakes", "Cereal Grains and Pasta", "plant", syn=["puffed rice cakes"])
S("rice-paper", "Rice paper", "Cereal Grains and Pasta", "plant", syn=["spring roll rice paper", "banh trang"], note="sheets of rice flour, tapioca or plain rice, water and salt")
S("rice-powder", "Rice powder", "Cereal Grains and Pasta", "plant", syn=["ground rice", "rice flour (coarse)"])
S("rosemary", "Rosemary", "Spices and Herbs", "plant", syn=["fresh rosemary", "dried rosemary"])
S("rum", "Rum", "Beverages", "plant", note="distilled sugarcane molasses; distillate carries no allergen protein")
S("sauerkraut", "Sauerkraut", "Vegetables and Vegetable Products", "plant", note="fermented cabbage and salt")
S("scotch-bonnet", "Scotch bonnet", "Vegetables and Vegetable Products", "plant", syn=["scotch bonnet chile"])
S("seaweed", "Seaweed", "Vegetables and Vegetable Products", "plant", syn=["nori", "kombu", "wakame"])
S("sichuan-peppercorns", "Sichuan peppercorns", "Spices and Herbs", "plant", syn=["szechuan peppercorns"])
S("smoked-paprika", "Smoked paprika", "Spices and Herbs", "plant", syn=["pimenton"])
S("sumac", "Sumac", "Spices and Herbs", "plant", syn=["ground sumac"])
S("swede", "Swede", "Vegetables and Vegetable Products", "plant", syn=["rutabaga"])
S("tamarind", "Tamarind", "Fruits and Fruit Juices", "plant", syn=["tamarind pulp"])
S("thai-chilies", "Thai chilies", "Vegetables and Vegetable Products", "plant", syn=["bird's eye chilies"])
S("thyme", "Thyme", "Spices and Herbs", "plant", syn=["fresh thyme", "dried thyme"])
S("turmeric", "Turmeric", "Spices and Herbs", "plant", syn=["haldi"])
S("umeboshi", "Umeboshi", "Fruits and Fruit Juices", "plant", note="salt-pickled ume plums, sometimes with shiso; no major allergens")
S("vanilla", "Vanilla", "Spices and Herbs", "plant", syn=["vanilla extract", "vanilla bean"], note="vanilla beans or extract (alcohol + water + vanilla); no major allergens")
S("watermelon", "Watermelon", "Fruits and Fruit Juices", "plant")
S("white-pepper", "White pepper", "Spices and Herbs", "plant", syn=["ground white pepper"])
S("white-vinegar", "White vinegar", "Beverages", "mineral", syn=["spirit vinegar"],
  note="acetic acid in water; no allergen protein; vegan")
S("yam", "Yam", "Vegetables and Vegetable Products", "plant", syn=["african yam", "name yam"])
S("jalapeno", "Jalapeno", "Vegetables and Vegetable Products", "plant", syn=["jalapenos"])
S("chipotle", "Chipotle", "Spices and Herbs", "plant", syn=["dried chipotle"], note="smoke-dried jalapeno; chipotle-in-adobo (in sauce) is a separate reviewed key")
S("chili-powder", "Chili powder", "Spices and Herbs", "plant", complete=False,
  note="US-style blend of ground chiles, cumin, garlic and oregano; pure spices, no major allergens; blends vary")
S("mild-curry-powder", "Mild curry powder", "Spices and Herbs", "plant", complete=False,
  note="ground-spice blend (turmeric, coriander, cumin, fenugreek, chile); pure spices; blends vary")
S("cornstarch", "Cornstarch", "Cereal Grains and Pasta", "plant", syn=["corn starch"])
S("black-pepper", "Black pepper", "Spices and Herbs", "plant", syn=["ground black pepper", "peppercorns"])
S("brown-sugar", "Brown sugar", "Sweets", "plant", syn=["light brown sugar", "dark brown sugar"],
  note="refined sugar with molasses; no major allergens")
S("red-wine", "Red wine", "Beverages", "plant", syn=["red cooking wine"],
  diet_overrides={"vegan": unk_diet("grape must; fining agents (isinglass, egg, casein) vary by producer and many wines are unfined - vegan verdict stays unknown until the producer is known"),
                  "vegetarian": unk_diet("fining agents vary by producer; many wines are unfined - unknown until the producer is known")},
  note="sulfites are a wine allergen of declaration but not one of the FDA major nine")
S("cola", "Cola", "Beverages", "plant", syn=["cola soft drink", "soda"],
  note="carbonated water, sweetener, caramel colour, phosphoric acid and natural flavours; no FDA major allergens; formulations vary by brand")
S("preserved-lemon", "Preserved lemon", "Fruits and Fruit Juices", "plant", syn=["preserved lemons", "lemon confit"],
  note="lemons cured in salt and their brine; no major allergens")
S("vegetable-oil", "Vegetable oil", "Fats and Oils", "plant", syn=["cooking oil", "sunflower oil", "canola oil"],
  note="refined oil blend (soybean/canola/sunflower); highly refined oils are not FDA major-allergen sources even when soybean-derived")
S("coconut-oil", "Coconut oil", "Fats and Oils", "plant", syn=["virgin coconut oil"],
  overrides={"treeNuts": ev_ref("reference", FDA, "coconut is botanically a fruit and the FDA does not classify coconut oil as a major allergen, but the canon's coconut entry hedges tree-nut state for nut-allergic households; hedge kept. " + fdc("Fats and Oils"))},
  note="pressed coconut fat; water-clear when refined")
S("green-lentils", "Green lentils", "Legumes and Legume Products", "plant", syn="ALIAS:lentils")
S("brown-lentils", "Brown lentils", "Legumes and Legume Products", "plant", syn="ALIAS:lentils")
S("red-lentils", "Red lentils", "Legumes and Legume Products", "plant", syn="ALIAS:lentils")
S("lentils", "Lentils", "Legumes and Legume Products", "plant")
S("cooked-lentils", "Cooked lentils", "Legumes and Legume Products", "plant", syn="ALIAS:lentils")
S("kidney-beans", "Kidney beans", "Legumes and Legume Products", "plant", syn=["red kidney beans"])
S("white-beans", "White beans", "Legumes and Legume Products", "plant", syn=["cannellini beans", "navy beans"])
S("ground-ginger", "Ground ginger", "Spices and Herbs", "plant", syn="ALIAS:ginger")
S("salt-pork", "Salt pork", "Pork Products", "meat", syn=["lardons"], note="salt-cured pork fatback")
S("roast-turkey", "Roast turkey", "Poultry Products", "meat", syn=["roasted turkey", "cooked turkey"])
S("beef-chuck", "Beef chuck", "Beef Products", "meat", syn=["chuck steak", "chuck roast"])
S("chicken-drumsticks", "Chicken drumsticks", "Poultry Products", "meat", syn=["chicken legs"])
S("lamb-chops", "Lamb chops", "Lamb, Veal, and Game Products", "meat", syn=["lamb chops"])
S("lamb-shanks", "Lamb shanks", "Lamb, Veal, and Game Products", "meat", syn=["lamb shank"])
S("pork-belly", "Pork belly", "Pork Products", "meat", syn=["fresh pork belly"])
S("pork-cutlets", "Pork cutlets", "Pork Products", "meat", syn=["pork loin cutlets"])
S("buttermilk", "Buttermilk", "Dairy and Egg Products", "dairy", contains=["milk"], syn=["cultured buttermilk"])
S("evaporated-milk", "Evaporated milk", "Dairy and Egg Products", "dairy", contains=["milk"], syn=["tinned evaporated milk"])
S("labneh", "Labneh", "Dairy and Egg Products", "dairy", contains=["milk"], syn=["labaneh", "strained yogurt cheese"],
  note="yogurt strained of whey with salt")
S("mozzarella", "Mozzarella", "Dairy and Egg Products", "dairy", contains=["milk"], syn=["fresh mozzarella", "mozzarella cheese"])
S("cheddar", "Cheddar", "Dairy and Egg Products", "dairy", contains=["milk"], syn=["cheddar cheese", "mature cheddar", "grated cheddar"])
S("sharp-cheddar", "Sharp cheddar", "Dairy and Egg Products", "dairy", contains=["milk"], syn="ALIAS:cheddar")
S("heavy-cream", "Heavy cream", "Dairy and Egg Products", "dairy", contains=["milk"], syn="ALIAS:cream")
S("whipping-cream", "Whipping cream", "Dairy and Egg Products", "dairy", contains=["milk"], syn="ALIAS:cream")
S("catfish", "Catfish", "Finfish and Shellfish Products", "fish", contains=["fish"], syn=["catfish fillets"])
S("tilapia", "Tilapia", "Finfish and Shellfish Products", "fish", contains=["fish"], syn=["tilapia fillets"])
S("sea-bass", "Sea bass", "Finfish and Shellfish Products", "fish", contains=["fish"], syn=["bass", "branzino"])
S("salt-cod", "Salt cod", "Finfish and Shellfish Products", "fish", contains=["fish"], syn=["bacalao", "baccala"], note="cod preserved in salt; rinse before use")
S("squid", "Squid", "Finfish and Shellfish Products", "fish", contains=["fish"], syn=["calamari"],
  mollusk=True,
  note="squid is a MOLLUSK, not a crustacean")
S("star-anise", "Star anise", "Spices and Herbs", "plant", syn=["anise stars"])

# --- compounds ---
COMPOUNDS = {}
def C(key, display, comps, complete, syn=(), allergen_overrides=None, diets=None, note=None, gluten=None, class_hint=None):
    COMPOUNDS[key] = dict(display=display, comps=comps, complete=complete, syn=list(syn),
                          ao={t: AL("unknown", e) for t, e in (allergen_overrides or {}).items()},
                          diets=diets or {}, note=note, gluten=gluten, class_hint=class_hint)

def comp(k, c, refnote): return {"key": k, "certainty": c, "evidence": ev("standard", "standard composition (retrieved %s)" % RETRIEVED, refnote)}

C("apricot-jam", "Apricot jam",
  [comp("apricots", "certain", "fruit preserved with sugar and pectin"),
   comp("sugar", "certain", "jam is fruit cooked with sugar"),
   comp("lemon-juice", "typical", "acid for set and flavour"),
   comp("pectin", "typical", "gelling agent in most commercial jams")],
  True, syn=["apricot preserves"],
  diets={"vegan": unk_diet("fruit, pectin and sugar; cane-sugar refining is vegan-safe in most but not all supply chains, so the vegan verdict stays unknown") ,
         "vegetarian": dstate("allowed", "fruit, pectin and sugar; no animal-derived ingredients (diet fact: allowed)"),
         "pescatarian": dstate("allowed", "no fish or flesh (diet fact: allowed)")},
  note="fruit jam; some recipes use gelatin - check the label when a vegan household asks")

C("baguette", "Baguette",
  [comp("wheat-flour", "certain", "traditional baguette is wheat flour, water, yeast and salt"),
   comp("water", "certain", "dough hydration"),
   comp("yeast", "certain", "leavening"),
   comp("salt", "certain", "dough seasoning")],
  True, syn=["french baguette", "baguette bread"],
  note="traditional baguette de tradition contains only wheat flour, water, yeast, salt (and a little malt/bean flour by French law); enriched sandwich breads are separate keys",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("burger-buns", "Burger buns",
  [comp("wheat-flour", "certain", "enriched wheat bun dough"),
   comp("milk-powder", "typical", "brioche-style buns carry milk powder or butter"),
   comp("sugar", "typical", "enriched dough sweetener"),
   comp("yeast", "certain", "leavening"),
   comp("salt", "certain", "dough seasoning"),
   comp("butter", "variable", "enriched doughs often use butter or oil"),
   comp("egg", "variable", "brioche-style buns include egg; basic buns do not")],
  False, syn=["burger buns", "hamburger buns"],
  allergen_overrides={"egg": ev("standard", "brand recipes vary", "brioche-style buns contain egg; basic wheat buns do not - state unknown until a product label is read"),
    "sesame": ev("standard", "topping varies", "seeded buns with a sesame topping are common; sesame presence is brand- and variety-dependent - unknown until a product label is read")},
  note="enriched wheat bun; milk is typical, egg and sesame topping vary by style",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("puff-pastry", "Puff pastry",
  [comp("wheat-flour", "certain", "laminated wheat dough"),
   comp("butter", "typical", "classic lamination fat is butter"),
   comp("water", "certain", "dough hydration"),
   comp("salt", "typical", "dough seasoning")],
  True, syn=["puff pastry sheet"],
  note="classic puff pastry is flour laminated with butter; all-butter and margarine versions both exist - butter is the standard reviewed composition",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("vanilla-ice-cream", "Vanilla ice cream",
  [comp("milk", "certain", "ice cream base is milk and cream"),
   comp("cream", "certain", "ice cream base is milk and cream"),
   comp("sugar", "certain", "sweetener"),
   comp("vanilla", "typical", "vanilla beans or extract flavouring"),
   comp("egg", "variable", "french (custard) base contains egg; philadelphia base does not")],
  False, syn=["vanilla ice cream"],
  allergen_overrides={"egg": ev("standard", "base style varies", "french custard base contains egg; philadelphia-style base does not - unknown until a product label is read")},
  note="dairy dessert; egg presence depends on base style")

C("beef-meatballs", "Beef meatballs",
  [comp("beef", "certain", "ground beef is the defining component"),
   comp("onion", "typical", "aromatic"),
   comp("spices", "typical", "seasoning"),
   comp("breadcrumbs", "variable", "many recipes bind with breadcrumbs"),
   comp("egg", "variable", "many recipes bind with egg")],
  False, syn=["beef meatballs"],
  allergen_overrides={
    "wheat": ev("standard", "recipe varies", "breadcrumbs in the binder carry wheat in many recipes; rusk-free recipes exist"),
    "milk": ev("standard", "recipe varies", "breadcrumbs carry milk through their bread component in many recipes"),
    "egg": ev("standard", "recipe varies", "egg is a common binder; not universal")},
  diets={"vegetarian": dstate("violated", "beef is animal flesh (diet fact: violated)"),
         "vegan": dstate("violated", "beef is animal flesh (diet fact: violated)"),
         "pescatarian": dstate("violated", "land-animal flesh; pescatarian diets exclude it (diet fact: violated)")},
  note="composition varies by recipe; binder allergens (wheat, milk via breadcrumbs, egg) are uncertain")

C("italian-sausage", "Italian sausage",
  [comp("pork", "certain", "pork is the defining meat"),
   comp("pork-fat", "typical", "fatback/shoulder fat"),
   comp("spices", "typical", "fennel and pepper seasoning"),
   comp("salt", "certain", "curing/seasoning salt"),
   comp("distilled-vinegar", "variable", "some fresh sausages are acidulated")],
  False, syn=["italian sausage"],
  allergen_overrides={
    "milk": ev("reference", "USDA FSIS Food Standards and Labeling Policy Book, https://www.usda.gov/sites/default/files/guidance-documents/FSIS-GD-2005-0003-Food-Standards-and-Labeling-Policy-Book.pdf (retrieved 2026-10-16)",
      "USDA permits dried-milk binders in sausage and some brands declare milk (e.g. cheese-containing italian-style sausage); milk is not inherent to the standard - presence is brand-dependent, unknown until a product label is read"),
    "wheat": ev("reference", "USDA FSIS Food Standards and Labeling Policy Book, https://www.usda.gov/sites/default/files/guidance-documents/FSIS-GD-2005-0003-Food-Standards-and-Labeling-Policy-Book.pdf (retrieved 2026-10-16)",
      "USDA permits cereal/vegetable-starch fillers in sausage and this fact's own note flags wheat fillers in some brands; presence is brand-dependent, unknown until a product label is read")},
  note="standard fresh italian sausage is pork, fat, salt and spices; some brands add milk solids or wheat fillers - check the label")

C("sausages", "Sausages",
  [comp("pork", "certain", "generic sausage is pork-based unless labelled otherwise"),
   comp("salt", "certain", "seasoning"),
   comp("spices", "typical", "seasoning"),
   comp("wheat-flour", "variable", "rusk/breadcrumb filler is common in british-style sausages"),
   comp("milk-powder", "variable", "milk powder filler appears in some brands")],
  False, syn=["fresh sausages"],
  allergen_overrides={
    "wheat": ev("standard", "brand recipes vary", "rusk or breadcrumb filler carries wheat in many brands; not universal"),
    "milk": ev("standard", "brand recipes vary", "milk-powder filler in some brands; not universal")},
  diets={"vegetarian": dstate("violated", "generic sausages are meat products (diet fact: violated)"),
         "vegan": dstate("violated", "generic sausages are meat products (diet fact: violated)"),
         "pescatarian": dstate("violated", "land-animal flesh (diet fact: violated)")},
  note="generic sausage key: filler allergens vary by brand and recipe")

C("smoked-sausage", "Smoked sausage",
  [comp("pork", "certain", "smoked sausage is pork-based unless labelled otherwise"),
   comp("salt", "certain", "curing salt"),
   comp("spices", "typical", "seasoning"),
   comp("wheat-flour", "variable", "rusk filler in some brands"),
   comp("milk-powder", "variable", "milk-powder filler in some brands")],
  False, syn=["smoked sausage", "kielbasa", "andouille"],
  allergen_overrides={
    "wheat": ev("standard", "brand recipes vary", "rusk or breadcrumb filler carries wheat in many brands; not universal"),
    "milk": ev("standard", "brand recipes vary", "milk-powder filler in some brands; not universal")},
  diets={"vegetarian": dstate("violated", "smoked sausage is a meat product (diet fact: violated)"),
         "vegan": dstate("violated", "smoked sausage is a meat product (diet fact: violated)"),
         "pescatarian": dstate("violated", "land-animal flesh (diet fact: violated)")},
  note="generic smoked sausage key: filler allergens vary by brand")

C("nduja", "Nduja",
  [comp("pork", "certain", "spreading calabrian salami is pork"),
   comp("pork-fat", "certain", "high fat ratio is defining"),
   comp("chili-peppers", "certain", "defining heat"),
   comp("salt", "certain", "curing salt")],
  False, syn=["'nduja"],
  note="fermented, spreadable; spice mix varies but stays within pork, fat, chile and salt")

C("chicharrones", "Chicharrones",
  [comp("pork", "certain", "fried pork belly or skin"),
   comp("salt", "certain", "seasoning"),
   comp("vegetable-oil-blend", "typical", "frying medium")],
  False, syn=["pork rinds", "chicharron"],
  note="fried pork skin/belly; some commercial rinds are dusted with seasonings that vary")

C("beef-vegetable-stock", "Beef vegetable stock",
  [comp("beef", "certain", "beef bones/meat define the stock"),
   comp("vegetables-mixed", "typical", "mirepoix aromatics"),
   comp("salt", "typical", "seasoning"),
   comp("stock-additives", "variable", "commercial stocks add flavourings/extracts that vary")],
  False, syn=["beef and vegetable stock"],
  allergen_overrides={t: ev("standard", "commercial additives vary",
      "commercial stock additives (yeast extract, hydrolysed proteins, milk solids) vary by brand; %s cannot be ruled out" % ALLERGEN_NAME[t])
    for t in ALLERGENS},
  diets={"vegetarian": dstate("violated", "beef stock is beef-based by definition (diet fact: violated)"),
         "vegan": dstate("violated", "beef stock is beef-based by definition (diet fact: violated)"),
         "pescatarian": dstate("violated", "land-animal flesh (diet fact: violated)")},
  note="commercial versions vary on additives; allergen-relevant additives stay uncertain")

C("broth", "Broth",
  [comp("vegetables-mixed", "certain", "generic 'broth' in the catalog is assumed vegetable-based; meat broths are separate keys (chicken-stock, beef-stock)"),
   comp("salt", "typical", "seasoning"),
   comp("stock-additives", "variable", "commercial broths add flavourings/extracts that vary")],
  False, syn=["cooking broth"],
  allergen_overrides={t: ev("standard", "broth base and additives vary",
      "generic 'broth' cannot rule %s in or out: bases include chicken/beef/vegetable/fish and commercial additives (yeast extract, hydrolysed proteins, milk solids) vary by brand" % ALLERGEN_NAME[t])
    for t in ALLERGENS},
  note="generic broth key: base and additives vary by product; every allergen state stays unknown - check the label for a specific product")

C("stock", "Stock",
  [comp("vegetables-mixed", "certain", "generic 'stock' in the catalog is assumed vegetable-based; meat stocks are separate keys (chicken-stock, beef-stock)"),
   comp("salt", "typical", "seasoning"),
   comp("stock-additives", "variable", "commercial stocks add flavourings/extracts that vary")],
  False, syn=["cooking stock"],
  allergen_overrides={t: ev("standard", "stock base and additives vary",
      "generic 'stock' cannot rule %s in or out: bases include chicken/beef/vegetable/fish and commercial additives vary by brand" % ALLERGEN_NAME[t])
    for t in ALLERGENS},
  note="generic stock key: base and additives vary by product; every allergen state stays unknown - check the label for a specific product")

C("dashi", "Dashi",
  [comp("seaweed", "certain", "kombu is the seaweed base of awase dashi"),
   comp("fish-sauce-part", "unknown", "stands in for the fish component (bonito/katsuobushi): typical in awase dashi but kombu-only and shiitake vegan dashi exist, so its presence is treated as uncertain")],
  False, syn=["japanese soup stock", "kombu dashi"],
  allergen_overrides={"fish": ev("standard", "dashi style varies", "awase dashi carries bonito (fish); kombu/shiitake vegan dashi does not - unknown until the style is known")},
  note="japanese soup stock; fish presence depends on style (awase vs kombu/shiitake)")

C("green-curry-paste", "Green curry paste",
  [comp("chili-peppers", "certain", "green chilies define the paste"),
   comp("garlic", "typical", "aromatic"),
   comp("lemongrass", "typical", "aromatic"),
   comp("kaffir-lime", "typical", "makrut lime leaves/zest"),
   comp("galangal", "typical", "aromatic rhizome"),
   comp("shrimp-paste", "variable", "standard thai pastes include shrimp paste (kapi); vegan variants exist"),
   comp("salt", "certain", "seasoning")],
  False, syn=["thai green curry paste"],
  allergen_overrides={"crustaceanShellfish": ev("standard", "brand recipes vary", "standard pastes include shrimp paste (kapi); some vegan-labelled pastes omit it - unknown until the label is read")},
  note="standard composition carries shrimp paste; vegan-labelled variants exist")

C("massaman-curry-paste", "Massaman curry paste",
  [comp("chili-peppers", "certain", "dried red chilies"),
   comp("lemongrass", "typical", "aromatic"),
   comp("galangal", "typical", "aromatic rhizome"),
   comp("garlic", "typical", "aromatic"),
   comp("spices", "typical", "warm spice blend (cardamom, cinnamon, cloves)"),
   comp("shrimp-paste", "variable", "standard thai pastes include shrimp paste (kapi); vegan variants exist"),
   comp("salt", "certain", "seasoning")],
  False, syn=["thai massaman curry paste"],
  allergen_overrides={"crustaceanShellfish": ev("standard", "brand recipes vary", "standard pastes include shrimp paste (kapi); some vegan-labelled pastes omit it - unknown until the label is read"),
                      "peanuts": ev("standard", "brand recipes vary", "some massaman pastes include peanuts; others do not - unknown until the label is read")},
  note="standard composition carries shrimp paste; peanut presence varies by brand")

C("black-bean-paste", "Black bean paste",
  [comp("soybeans", "certain", "chinese fermented black soybean paste (douchi/tausi) is soybean-based"),
   comp("salt", "certain", "fermentation salt"),
   comp("garlic", "typical", "aromatic in ready-to-use pastes"),
   comp("soybean-oil-refined", "typical", "oil medium in ready-to-use pastes"),
   comp("wheat-flour", "unknown", "some brands add wheat flour as thickener; presence is brand-dependent")],
  False, syn=["fermented black bean paste", "douchi", "tausi"],
  allergen_overrides={"wheat": ev("standard", "brand recipes vary", "wheat flour appears in some brands; not universal")},
  note="fermented black SOYBEANS; wheat thickener is brand-dependent")

C("hao-you", "Hao you (oyster sauce)",
  [comp("sugar", "certain", "oyster sauce is sweet"),
   comp("salt", "certain", "seasoning"),
   comp("wheat-flour", "typical", "standard oyster sauces carry wheat flour or wheat-based starch as thickener"),
   comp("soybeans", "unknown", "some brands add soy sauce; premium brands are oyster, sugar and salt only - presence is brand-dependent"),
   comp("potato-starch", "typical", "thickener")],
  False, syn=["hao you"],
  allergen_overrides={"soy": ev("standard", "brand recipes vary", "soy sauce/soybeans appear in some oyster-sauce brands; premium brands are oyster extract, sugar and salt only - unknown until the label is read"),
                      "crustaceanShellfish": ev("reference", FDA, "oyster is a MOLLUSK, not a crustacean; not an FDA major-food-allergen source (mollusk allergies exist outside the FDA major nine). " + fdc("Soups, Sauces, and Gravies"))},
  note="oyster-flavoured chinese sauce; the oyster is a mollusk (outside the FDA major nine), soy presence is brand-dependent")

C("zaatar", "Zaatar",
  [comp("thyme", "certain", "herb base"),
   comp("sumac", "certain", "tangy berry grind"),
   comp("sesame", "certain", "toasted sesame seeds are defining"),  # sesame has no fact; use sesame-oil? no - see note
   comp("salt", "certain", "seasoning")],
  True, syn=["za'atar", "zahtar"],
  note="middle-eastern herb blend; sesame seeds are a defining component")

C("tamarind-paste", "Tamarind paste",
  [comp("tamarind", "certain", "tamarind pulp is the base"),
   comp("water", "certain", "concentrate hydration")],
  True, syn=["tamarind concentrate"],
  note="seedless tamarind pulp, pressed; sometimes with water")


C("hot-sauce", "Hot sauce",
  [comp("chili-peppers", "certain", "chile mash or powder is the base"),
   comp("distilled-vinegar", "certain", "acid medium"),
   comp("salt", "certain", "seasoning/fermentation salt")],
  True, syn=["sriracha-style sauce"],
  note="standard vinegar-chile-salt sauce; no FDA major allergens; thickened or sweetened variants vary")

C("cranberry-sauce", "Cranberry sauce",
  [comp("cranberries", "certain", "fruit base"),
   comp("sugar", "certain", "sweetener"),
   comp("water", "certain", "cooking liquid"),
   comp("orange-juice", "variable", "some recipes add citrus")],
  True, syn=["cranberry relish"],
  note="fruit, sugar and water; no FDA major allergens")

C("ramen-noodles", "Ramen noodles",
  [comp("wheat-flour", "certain", "alkaline wheat noodles"),
   comp("water", "certain", "dough hydration"),
   comp("salt", "typical", "seasoning; kansui (alkaline salt) in fresh styles"),
   comp("egg", "unknown", "fresh ramen styles often include egg; most instant and dried styles do not")],
  False, syn=["instant ramen noodles", "fresh ramen noodles"],
  allergen_overrides={"egg": ev("standard", "style varies", "fresh ramen often contains egg; instant/dried usually does not - unknown until the product is known")},
  note="wheat noodle for ramen; egg presence is style-dependent",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("french-fries", "French fries",
  [comp("potato", "certain", "cut potatoes"),
   comp("vegetable-oil-blend", "certain", "frying medium"),
   comp("salt", "certain", "seasoning")],
  True, syn=["fries", "chips"],
  allergen_overrides={"wheat": ev("standard", "preparation varies", "battered or coated fries carry wheat; plain cut fries do not - unknown until the product or coating is known")},
  note="standard fries are potato, oil and salt; shared-fryer cross-contact with battered items is a kitchen practice, not ingredient composition; battered/coated preparations exist and seasoned coatings vary - check the label",
  diets={"vegan": dstate("allowed", "potato and oil; no animal-derived ingredients (diet fact: allowed)"),
         "vegetarian": dstate("allowed", "potato and oil (diet fact: allowed)"),
         "pescatarian": dstate("allowed", "no fish or flesh (diet fact: allowed)")})

C("baking-powder", "Baking powder",
  [comp("cornstarch", "certain", "starch filler keeps the powder dry"),
   comp("salt", "typical", "some formulations carry a trace; filler varies")],
  False, syn=["double-acting baking powder"],
  note="sodium bicarbonate + acid salt (cream of tartar, sodium aluminum sulfate or calcium phosphate) + starch filler; none of the nine FDA major allergens; filler starch varies (corn/potato)",
  allergen_overrides={t: ev("reference", FDA, "baking powder is bicarbonate + acid salt + starch filler; no %s source. " % ALLERGEN_NAME[t] + fdc("Cereal Grains and Pasta")) for t in ALLERGENS})

C("tortilla-chips", "Tortilla chips",
  [comp("masa-harina", "certain", "nixtamalized corn flour is the base"),
   comp("vegetable-oil-blend", "typical", "frying or baking oil"),
   comp("salt", "certain", "seasoning")],
  True, syn=["corn chips"],
  note="fried/baked masa triangles; mirrors the reviewed taco-shells composition")


C("spring-roll-wrappers", "Spring roll wrappers",
  [comp("wheat-flour", "certain", "wheat-flour sheets (chinese style)"),
   comp("water", "certain", "dough hydration"),
   comp("salt", "typical", "dough seasoning")],
  True, syn=["lumpia wrappers", "fried spring roll wrappers"],
  note="chinese spring roll wrappers are wheat-based; rice paper (fresh rolls) is a separate reviewed key",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("udon-noodles", "Udon noodles",
  [comp("wheat-flour", "certain", "thick wheat noodles"),
   comp("water", "certain", "dough hydration"),
   comp("salt", "certain", "dough seasoning")],
  True, syn=["udon"],
  note="plain wheat noodles; egg is not a standard udon ingredient",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("wheat-noodles", "Wheat noodles",
  [comp("wheat-flour", "certain", "chinese-style wheat noodles"),
   comp("water", "certain", "dough hydration"),
   comp("salt", "typical", "dough seasoning"),
   comp("egg", "variable", "some egg-containing styles exist; standard alkaline wheat noodles have no egg")],
  True, syn=["chinese egg-free wheat noodles", "lo mein noodles"],
  note="standard wheat noodles are flour, water and salt (often with kansui/alkaline salt); egg styles are a minority",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("noodles", "Noodles",
  [comp("wheat-flour", "certain", "generic 'noodles' in the catalog resolves to wheat noodles; rice/starch noodles are separate keys"),
   comp("water", "certain", "dough hydration"),
   comp("egg", "unknown", "egg presence is style-dependent (plain wheat vs egg noodle)")],
  False, syn=["generic noodles"],
  allergen_overrides={"egg": ev("standard", "style varies", "plain wheat noodles carry no egg; egg noodles do - unknown until the product is known")},
  note="generic noodle key resolved to wheat noodles; egg presence is style-dependent",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'wheat-flour'")})

C("cottage-cheese", "Cottage cheese",
  [comp("milk", "certain", "curdled skim milk"),
   comp("lactic-cultures", "certain", "culturing"),
   comp("salt", "typical", "dressing/seasoning"),
   comp("cream", "typical", "cream dressing")],
  True, syn=["cottage cheese curds"],
  note="acid-set curds with cream dressing; stabilizers (guar, starch) in some brands carry no major allergens")

C("pasta-dried", "Dried pasta",
  [comp("durum-wheat-flour", "certain", "semolina pasta"),
   comp("water", "certain", "dough hydration")],
  True, syn=[],
  note="dried durum pasta; identical composition to the reviewed 'pasta' fact",
  gluten={"state": "contains", "evidence": ev("standard", "compound composition", "gluten via certain/typical component 'durum-wheat-flour'")})

C("whole-wheat-flour", "Whole-wheat flour",
  [comp("wheat", "certain", "whole grain includes bran and germ")],
  True, syn=["wholemeal flour", "whole wheat flour"],
  note="whole-grain wheat; germ and bran included",
  gluten={"state": "contains", "evidence": ev("standard", "gluten is the protein of wheat, barley and rye", "Whole-wheat flour is gluten-bearing")})

C("black-vinegar", "Black vinegar",
  [comp("rice", "certain", "glutinous-rice base (chinkiang style)"),
   comp("wheat", "unknown", "wheat bran appears in the fermentation substrate of some chinkiang vinegars; presence is brand-dependent"),
   comp("salt", "typical", "seasoning"),
   comp("sugar", "typical", "some brands sweeten")],
  False, syn=["chinkiang vinegar", "chinese black vinegar", "zhenjiang vinegar"],
  allergen_overrides={"wheat": ev("standard", "brand recipes vary", "wheat bran in the fermentation substrate of some brands; not universal")},
  note="chinese black vinegar; wheat bran substrate is brand-dependent")


# ---------------- build ----------------
new_facts = {}
new_idents = []
ALIAS_SYNTHS = []

def table_key_display(tk):
    return tk.replace("-", " ").title()

# alias resolution: SIMPLE entries whose syn is "ALIAS:target" alias to another fact
ALIASES = {}
for k, v in SIMPLE.items():
    if v[1] and isinstance(v[1][0], str) and v[1][0].startswith("ALIAS:"):
        ALIASES[k] = v[1][0].split(":", 1)[1]

def table_key(bk):
    f = fold(bk)
    return f if (f in SIMPLE or f in COMPOUNDS or f in ALIASES) else None

missing_tables = [k for k in unresolved if table_key(k) is None]
if missing_tables:
    print("UNCOVERED:", missing_tables); sys.exit(1)

# identity collision check
claimed = {}
for e in idents:
    claimed[fold(e["key"])] = ("existing", e["key"])
    for s in e.get("synonyms") or []:
        claimed[fold(s)] = ("existing-syn", e["key"])
conflicts = []
def claim(f, src):
    if f in claimed:
        conflicts.append((f, src, claimed[f]))
    claimed[f] = ("new", src)

# aliases first, then every table key (bundle keys + component-only facts)
for bk in unresolved:
    tk = table_key(bk)
    if tk in ALIASES:
        claim(fold(bk), f"alias-identity {tk}->{ALIASES[tk]}")
table_keys = sorted(set(SIMPLE) | set(COMPOUNDS))
for tk in table_keys:
    if tk in ALIASES:
        continue  # alias folds were claimed in the alias pass
    if fold(tk) in facts:
        continue  # already-resolved fact: our table must not overwrite reviewed canon
    src = SIMPLE.get(tk) or COMPOUNDS.get(tk)
    syns = src["syn"] if isinstance(src, dict) else src[1]
    claim(fold(tk), f"identity {tk}")
    for s in syns or []:
        if fold(s) == fold(tk) or s.startswith("ALIAS:"):
            continue
        claim(fold(s), f"syn-of {tk}")

# stale existing identities (target fact missing) are repaired by our overwrite, not a conflict
stale = [c for c in conflicts if c[2][0] == "existing" and c[2][1] not in facts]
for c in stale:
    print(f"note: overwriting stale identity fold '{c[0]}' (was -> '{c[2][1]}', fact missing)")
conflicts = [c for c in conflicts if c not in stale]
if conflicts:
    print("FOLD COLLISIONS:"); [print(" ", c) for c in conflicts]; sys.exit(1)

# verify components resolve (existing or new)
new_fact_keys = {fold(k) for k in table_keys if k not in ALIASES}
for tk in table_keys:
    if tk in ALIASES: continue
    if tk not in SIMPLE:
        for cdef in COMPOUNDS[tk]["comps"]:
            ck = cdef["key"]
            if ck in facts: continue
            ckf = fold(ck)
            if ckf in new_fact_keys: continue
            print(f"component '{ck}' of {tk} resolves nowhere"); sys.exit(1)

def make_simple_fact(tk, disp, syns, cat, dtype, contains, opts):
    note = opts.get("note")
    al = simple_allergens(cat, contains=contains, overrides=opts.get("overrides"))
    if opts.get("mollusk"):
        al["crustaceanShellfish"] = {"state": "free", "evidence": ev_ref("reference", FDA,
            "squid is a molluscan shellfish, not a crustacean: the FDA major-food-allergen 'crustacean shellfish' covers crab, lobster and shrimp, not squid. " + fdc(cat))}
        al["molluscanShellfish"] = {"state": "contains", "evidence": ev_ref("reference", FDA,
            "molluscs count as shellfish for the app's shellfish restriction (the bundle classes molluscan shellfish as shellfish); the crustaceanShellfish token stays crustacean-only. " + fdc(cat))}
    diets = simple_diets(dtype, overrides=opts.get("diet_overrides"))
    f = {"key": tk, "allergens": al, "diets": diets}
    if note: f["note"] = note
    return f

for tk in list(table_keys) + [table_key(bk) for bk in unresolved if table_key(bk) in ALIASES]:
    fk = fold(tk)
    if tk not in ALIASES and fk in facts:
        continue  # reviewed canon fact exists: never overwrite
    if tk in ALIASES:
        target = ALIASES[tk]
        ALIAS_SYNTHS.append((table_key_display(tk).lower(), target))
        continue
    if tk in SIMPLE:
        disp, syns, cat, dtype, contains, opts = SIMPLE[tk]
        new_facts[fk] = make_simple_fact(fk, disp, syns, cat, dtype, contains, opts)
        kind = "simple"
    else:
        c = COMPOUNDS[tk]
        # derive contains allergens from certain/typical components
        derived = set()
        for cdef in c["comps"]:
            if cdef["certainty"] in ("certain", "typical"):
                cf = facts.get(cdef["key"]) or new_facts.get(fold(cdef["key"])) or {}
                for t, st in (cf.get("allergens") or {}).items():
                    if st["state"] == "contains": derived.add(t)
        al = {}
        for t in ALLERGENS:
            if t in c["ao"]: al[t] = c["ao"][t]
            elif t in derived:
                src = next(cd["key"] for cd in c["comps"] if cd["certainty"] in ("certain", "typical") and (facts.get(cd["key"]) or new_facts.get(fold(cd["key"]), {})).get("allergens", {}).get(t, {}).get("state") == "contains")
                al[t] = AL("contains", ev("standard", "compound composition", f"component '{src}' is a certain or typical ingredient"))
            elif t not in al:
                al[t] = AL("free", ev("standard", "compound composition",
                           f"closed from certain/typical components ({', '.join(cd['key'] for cd in c['comps'] if cd['certainty'] in ('certain','typical'))}); no source of {ALLERGEN_NAME[t]}"))
        f = {"key": fk, "components": c["comps"], "compositionComplete": c["complete"],
             "allergens": al}
        diets = dict(c["diets"])
        # derive diet verdicts where not overridden
        def cfact(ck): return facts.get(ck) or new_facts.get(fold(ck), {})
        for diet in ("vegetarian", "vegan", "pescatarian", "glutenFree", "dairyFree"):
            if diet in diets: continue
            verdict = None; saw_v = False
            for cdef in c["comps"]:
                if cdef["certainty"] == "unknown": verdict = "unknown"; break
                cf = cfact(cdef["key"])
                own = (cf.get("diets") or {}).get(diet, {}).get("state")
                if own and own != "unknown":
                    if own == "violated": saw_v = True
                elif cf.get("components"):
                    sub = None; sv = False
                    for sdef in cf["components"]:
                        if sdef["certainty"] == "unknown": sub = "unknown"; break
                        sf = cfact(sdef["key"])
                        so = (sf.get("diets") or {}).get(diet, {}).get("state")
                        if so == "violated": sv = True
                    sub = sub or ("violated" if sv else "allowed")
                    if sub == "violated": saw_v = True
                else:
                    if cf.get("allergens"):
                        pass
                    if diet == "glutenFree" and (cf.get("allergens", {}).get("wheat", {}).get("state") == "contains" or cf.get("gluten", {}).get("state") == "contains"):
                        saw_v = True
                    elif diet == "dairyFree" and cf.get("allergens", {}).get("milk", {}).get("state") == "contains":
                        saw_v = True
            verdict = verdict or ("violated" if saw_v else "allowed")
            diets[diet] = AL(verdict, ev("standard", "compound composition",
                {"violated": "violated via certain/typical components",
                 "allowed": f"allowed: no component violates {diet}",
                 "unknown": "composition incomplete: diet verdict unresolved"}[verdict]))
        f["diets"] = diets
        if c["gluten"]: f["gluten"] = c["gluten"]
        if c["note"]: f["note"] = c["note"]
        kind = "compound"
        new_facts[fk] = f
    entry = {"key": fk, "display": disp if tk in SIMPLE else COMPOUNDS[tk]["display"], "kind": kind,
             "synonyms": (syns if tk in SIMPLE else COMPOUNDS[tk]["syn"]) or []}
    if tk in SIMPLE and SIMPLE[tk][5].get("note"): entry["note"] = SIMPLE[tk][5]["note"]
    if tk in COMPOUNDS and COMPOUNDS[tk]["note"]: entry["note"] = COMPOUNDS[tk]["note"]
    new_idents.append(entry)

# attach alias synonyms after all identity entries exist (targets may be new facts)
for alias_syn, target in ALIAS_SYNTHS:
    entry = next((e for e in ident_doc["ingredients"] if e["key"] == target), None)
    if entry is None:
        entry = next((e for e in new_idents if e["key"] == fold(target)), None)
    if entry is None:
        if fold(target) not in facts:
            raise SystemExit(f"alias target '{target}' has no fact")
        entry = {"key": fold(target), "display": target.replace("-", " ").title(),
                 "kind": "simple", "synonyms": []}
        new_idents.append(entry)
    entry.setdefault("synonyms", [])
    if fold(alias_syn) != fold(target) and alias_syn not in entry["synonyms"]:
        entry["synonyms"].append(alias_syn)

print(f"new facts: {len(new_facts)}, new identities: {len(new_idents)}, aliases: {len(ALIAS_SYNTHS)}")
json.dump(new_facts, open("/tmp/fl11/new_facts.json", "w"), indent=2, ensure_ascii=False)
json.dump(new_idents, open("/tmp/fl11/new_idents.json", "w"), indent=2, ensure_ascii=False)

# ---- merge into the canon files, preserving existing entry order ----
facts_doc["facts"].update(new_facts)
ident_doc["ingredients"].extend(new_idents)

# ---- review-round-2 amendments: molluscs count as shellfish for the app's
# shellfish restriction. The reviewed bivalve facts carry no allergen states at
# all, which silently cleared a shellfish restriction; give each a
# molluscanShellfish contains state. crustaceanShellfish semantics stay
# crustacean-only (FDA major-9); compounds derive it through composition
# (oyster-sauce via its certain oyster component). hao-you is a separately
# authored oyster-sauce fact (no oyster component), so it is amended directly.
MOLLUSK_AMENDMENTS = {
    "oyster": "a bivalve mollusc",
    "clam": "a bivalve mollusc",
    "mussel": "a bivalve mollusc",
    "scallop": "a bivalve mollusc",
    "hao-you": "an oyster-derived sauce (hao you = oyster sauce)"
}
for mk, mdesc in MOLLUSK_AMENDMENTS.items():
    mf = facts_doc["facts"].get(mk)
    if not mf:
        sys.exit(f"amendment target missing: {mk}")
    mf.setdefault("allergens", {})["molluscanShellfish"] = {"state": "contains", "evidence": ev_ref("reference", FDA,
        f"{mk} is {mdesc}: molluscs count as shellfish for the app's shellfish restriction (bundle class alignment); the crustaceanShellfish token stays crustacean-only. " + fdc("Finfish and Shellfish Products"))}
    print(f"amended {mk}: molluscanShellfish contains")

# ---- missing-key amendments: a missing allergen key no longer clears
# (allergens.ts resolveCarries), so single substances that are free of every
# reviewed allergen get explicit free states instead of asking forever. Kept to
# substances with no protein source at all; anything brand-variable stays
# uncertain on purpose.
FREE_SUBSTANCE_AMENDMENTS = {
    "water": "water is an inorganic substance with no protein",
    "salt": "salt (sodium chloride) is an inorganic substance with no protein",
    "sugar": "sugar is refined sucrose from cane or beet with no protein",
}
FREE_TOKENS = ALLERGENS + ["molluscanShellfish"]
FREE_TOKEN_NAME = {**ALLERGEN_NAME, "molluscanShellfish": "molluscan shellfish"}
for fk, fdesc in FREE_SUBSTANCE_AMENDMENTS.items():
    ff = facts_doc["facts"].get(fk)
    if not ff:
        sys.exit(f"amendment target missing: {fk}")
    allergens = ff.setdefault("allergens", {})
    for t in FREE_TOKENS:
        if t in allergens:
            sys.exit(f"amendment target {fk} already reviews {t}; review it by hand")
        allergens[t] = {"state": "free", "evidence": ev_ref("reference", FDA,
            f"{fdesc}; FDA major food allergens are food proteins, so it carries no {FREE_TOKEN_NAME[t]}.")}
    print(f"amended {fk}: explicit free for {len(FREE_TOKENS)} allergens")

json.dump(facts_doc, open(FACTS, "w"), indent=2, ensure_ascii=False)
json.dump(ident_doc, open(IDENT, "w"), indent=2, ensure_ascii=False)

# ---- post-merge verification: TS-style resolution over all bundle keys ----
idx2 = {}
for e in ident_doc["ingredients"]:
    idx2[fold(e["key"])] = e["key"]
    for s in e.get("synonyms") or []:
        idx2[fold(s)] = e["key"]
still = [k for k in bundle_classes if (idx2.get(fold(k), fold(k))) not in facts_doc["facts"]]
if still:
    print("STILL UNRESOLVED:", still); sys.exit(1)
print(f"post-merge: all {len(bundle_classes)} bundle keys resolve (facts: {len(facts_doc['facts'])}, identities: {len(ident_doc['ingredients'])})")
