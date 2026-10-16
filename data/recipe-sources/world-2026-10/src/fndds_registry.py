"""FNDDS household-measure registry for the world-2026-10 packet.

Every row points into the MassConversionKit pinned FNDDS table
(apps/ios/Tools/mass-conversion-check/Sources/MassConversionKit/Resources/
mass_conversion_table.json on FridgeLuck PR #50's branch obv/fl-l2-mass-evidence,
which pins dataset edition 2024-10-31 with archive/survey sha256 hashes).

At build time the compiler reads the pinned table from the environment path
FNDDS_TABLE (default /tmp/mck.json) and resolves grams for (food, unit).
Derived rows are marked in DERIVED: they are arithmetic on a pinned row
(1 US tablespoon = 0.5 US fluid ounce) and say so in their evidence quote.
"""

# (line_name, unit) -> (fndds_food, fndds_unit)   [all names lowercased; the
# compiler looks them up case-insensitively against the pinned table]
DIRECT = {
    ("garlic", "clove"): ("garlic, raw", "clove"),
    ("garlic", "tsp"): ("garlic, raw", "tsp"),
    ("eggs", "large"): ("egg, whole, raw", "egg"),
    ("cooked white rice", "cup"): ("rice, white, cooked, no added fat", "cup"),
    ("cooked brown rice", "cup"): ("rice, brown, cooked, no added fat", "cup"),
    ("cooked glutinous rice", "cup"): ("rice, white, cooked, glutinous", "cup"),
    ("rice", "cup"): ("rice, white, cooked, no added fat", "cup"),
    ("rice noodles", "cup"): ("rice noodles, cooked", "cup"),
    ("noodles", "cup"): ("noodles, cooked", "cup"),
    ("chickpeas", "cup"): ("chickpeas, from canned, no added fat", "cup"),
    ("lentils", "cup"): ("lentils, from dried, no added fat", "cup"),
    ("kidney beans", "cup"): ("kidney beans, from canned, no added fat", "cup"),
    ("quinoa", "cup"): ("quinoa, no added fat", "cup"),
    ("edamame", "cup"): ("edamame, cooked", "cup"),
    ("milk", "cup"): ("milk, whole", "cup"),
    ("coconut milk", "cup"): ("coconut milk", "cup"),
    ("coconut cream", "cup"): ("coconut milk", "cup"),
    ("cream", "cup"): ("cream, heavy", "cup"),
    ("olive oil", "tbsp"): ("olive oil", "tbsp"),
    ("sesame oil", "tbsp"): ("sesame oil", "tbsp"),
    ("coconut oil", "tbsp"): ("coconut oil", "tbsp"),
    ("nuoc mam", "tbsp"): ("fish sauce", "tbsp"),
    ("hao you", "tbsp"): ("oyster sauce", "tbsp"),
    ("black beans", "cup"): ("black beans, from dried, no added fat", "cup"),
    ("canned black beans", "cup"): ("black beans, from canned, no added fat", "cup"),
    ("brown sugar", "tsp"): ("sugar, brown", "tsp"),
    ("mustard", "tbsp"): ("mustard", "tbsp"),
    ("mayonnaise", "tbsp"): ("mayonnaise, regular", "tbsp"),
    ("sour cream", "tbsp"): ("sour cream, regular", "tbsp"),
    ("white vinegar", "tbsp"): ("vinegar", "tbsp"),
    ("red wine vinegar", "tbsp"): ("vinegar", "tbsp"),
    ("hoisin sauce", "tbsp"): ("hoisin sauce", "tbsp"),
    ("soy sauce", "tbsp"): ("soy sauce", "tbsp"),
    ("honey", "tbsp"): ("honey", "tbsp"),
    ("peanut butter", "tbsp"): ("peanut butter", "tbsp"),
    ("tahini", "tbsp"): ("tahini", "tbsp"),
    ("greek yogurt", "cup"): ("yogurt, greek, whole milk, plain", "cup"),
    ("yogurt", "cup"): ("yogurt, whole milk, plain", "cup"),
    ("oats", "cup"): ("oats, raw", "cup"),
    ("spinach", "cup"): ("spinach, raw", "cup"),
    ("cilantro", "cup"): ("cilantro, raw", "cup"),
    ("basil", "tbsp"): ("basil, raw", "tbsp"),
    ("basil", "cup"): ("basil, raw", "cup"),
    ("broccoli", "cup"): ("broccoli, raw", "cup"),
    ("carrot", "cup"): ("carrots, raw", "cup"),
    ("napa cabbage", "cup"): ("cabbage, chinese, raw", "cup"),
    ("cabbage", "cup"): ("cabbage, green, raw", "cup"),
    ("mushrooms", "cup"): ("mushrooms, raw", "cup"),
    ("cucumber", "cup"): ("cucumber, raw", "cup"),
    ("tomato", "cup"): ("tomatoes, raw", "cup"),
    ("tomato", "slice"): ("tomatoes, raw", "slice"),
    ("bell pepper", "cup"): ("peppers, sweet, green, raw", "cup"),
    ("scallions", "cup"): ("onions, green, raw", "cup"),
    ("eggplant", "cup"): ("eggplant, raw", "cup"),
    ("corn", "cup"): ("corn, raw", "cup"),
    ("peas", "cup"): ("green peas, frozen, cooked, no added fat", "cup"),
    ("avocado", "cup"): ("avocado, raw", "cup"),
    ("avocado", "slice"): ("avocado, raw", "slice"),
    ("mango", "cup"): ("mango, raw", "cup"),
    ("pineapple", "cup"): ("pineapple, raw", "cup"),
    ("banana", "cup"): ("banana, raw", "cup"),
    ("plantain", "cup"): ("plantain, cooked, no added fat", "cup"),
    ("plantain", "slice"): ("plantain, cooked, no added fat", "slice"),
    ("cassava", "cup"): ("cassava, cooked", "cup"),
    ("seaweed", "strip"): ("seaweed, dried", "strip"),
    ("walnuts", "cup"): ("walnuts, excluding honey roasted", "cup"),
    ("cashews", "cup"): ("cashews, unroasted", "cup"),
    ("peanuts", "cup"): ("peanuts, honey roasted", "cup"),
    ("sesame seeds", "cup"): ("sesame seeds", "cup"),
    ("sugar", "tsp"): ("sugar, white, granulated or lump", "tsp"),
    ("sugar", "tbsp"): ("sugar, white, granulated or lump", "tbsp"),
    ("sugar", "cup"): ("sugar, white, granulated or lump", "cup"),
    ("parmesan", "cup"): ("cheese, parmesan, dry grated", "cup"),
    ("parmesan", "tbsp"): ("cheese, parmesan, dry grated", "tbsp"),
    ("cheddar", "cup"): ("cheese, cheddar", "cup"),
    ("cheddar", "slice"): ("cheese, cheddar", "slice"),
    ("mozzarella", "cup"): ("cheese, mozzarella, part skim", "cup"),
    ("feta", "cup"): ("cheese, feta", "cup"),
    ("paneer", "cup"): ("cheese, paneer", "cup"),
    ("bread", "slice"): ("bread, wheat or cracked wheat, made from home recipe or purchased at bakery", "slice"),
    ("pork belly", "slice"): ("pork, belly", "slice"),
    ("pork belly", "oz"): ("pork, belly", "oz"),
}

# Rows derived arithmetically from a pinned FNDDS row (1 US tbsp = 0.5 US floz).
DERIVED = {
    ("lime juice", "tbsp"): ("lime juice, 100%, freshly squeezed", "floz", 0.5),
    ("lemon juice", "tbsp"): ("lemon juice, 100%, freshly squeezed", "floz", 0.5),
    ("orange juice", "tbsp"): ("orange juice, 100%, freshly squeezed", "floz", 0.5),
    ("soy sauce", "tsp"): ("soy sauce", "tbsp", 1 / 3),
    ("nuoc mam", "tsp"): ("fish sauce", "tbsp", 1 / 3),
}

SOURCE_NAME = (
    "USDA FoodData Central Survey Foods (FNDDS), edition 2024-10-31, as pinned "
    "by MassConversionKit (FridgeLuck PR #50 branch obv/fl-l2-mass-evidence)"
)
SOURCE_URL = "https://fdc.nal.usda.gov/fdc-datasets/foodData_513.surveyDownload.json.zip?cachebust=2024103101"
SOURCE_PIN = (
    "apps/ios/Tools/mass-conversion-check/Sources/MassConversionKit/Resources/"
    "mass_conversion_table.json, archive sha256 dfb06ae7ddc397ccd570b91c14b75438ab2ba39f64f22d321f61d4a52a77f3eb"
)
RETRIEVED = "2024-10-31"
