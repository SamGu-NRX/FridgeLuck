"""FNDDS household-measure registry for the breakfast-2026-10 packet.

Same pinned extract as world-2026-10: the MassConversionKit pinned FNDDS table
(apps/ios/Tools/mass-conversion-check/Sources/MassConversionKit/Resources/
mass_conversion_table.json on FridgeLuck PR #50's branch obv/fl-l2-mass-evidence,
dataset edition 2024-10-31 with archive/survey sha256 hashes). Every (food, unit)
pair below was verified present in that pinned table at build time. DIRECT rows
reuse the world-2026-10 registry's mappings where the same line unit is used;
new line names point at the same pinned table rows. DERIVED rows are arithmetic
on a pinned row and say so.

At build time the compiler reads the pinned table from the environment path
FNDDS_TABLE (default /tmp/mck.json) and resolves grams for (food, unit).
"""

# (line_name, unit) -> (fndds_food, fndds_unit)   [all names lowercased; the
# compiler looks them up case-insensitively against the pinned table]
DIRECT = {
    ('avocado', 'slice'): ('avocado, raw', 'slice'),
    ('banana', 'cup'): ('banana, raw', 'cup'),
    ('bell peppers', 'cup'): ('peppers, sweet, green, raw', 'cup'),
    ('black beans', 'cup'): ('black beans, from dried, no added fat', 'cup'),
    ('bread', 'slice'): ('bread, wheat or cracked wheat, made from home recipe or purchased at bakery', 'slice'),
    ('chickpeas', 'cup'): ('chickpeas, from canned, no added fat', 'cup'),
    ('cilantro', 'cup'): ('cilantro, raw', 'cup'),
    ('coconut milk', 'cup'): ('coconut milk', 'cup'),
    ('cooked glutinous rice', 'cup'): ('rice, white, cooked, glutinous', 'cup'),
    ('cooked white rice', 'cup'): ('rice, white, cooked, no added fat', 'cup'),
    ('cottage cheese', 'cup'): ('cheese, cottage, low fat', 'cup'),
    ('eggs', 'large'): ('egg, whole, raw', 'egg'),
    ('fish sauce', 'tbsp'): ('fish sauce', 'tbsp'),
    ('frozen peas', 'cup'): ('green peas, frozen, cooked, no added fat', 'cup'),
    ('garlic', 'clove'): ('garlic, raw', 'clove'),
    ('greek yogurt', 'cup'): ('yogurt, greek, whole milk, plain', 'cup'),
    ('green onions', 'cup'): ('onions, green, raw', 'cup'),
    ('honey', 'tbsp'): ('honey', 'tbsp'),
    ('mango', 'cup'): ('mango, raw', 'cup'),
    ('milk', 'cup'): ('milk, whole', 'cup'),
    ('mushrooms', 'cup'): ('mushrooms, raw', 'cup'),
    ('oats', 'cup'): ('oats, raw', 'cup'),
    ('olive oil', 'tbsp'): ('olive oil', 'tbsp'),
    ('parsley', 'cup'): ('parsley, raw', 'cup'),
    ('plantains', 'cup'): ('plantain, cooked, no added fat', 'cup'),
    ('radishes', 'cup'): ('radish', 'cup'),
    ('seaweed', 'strip'): ('seaweed, dried', 'strip'),
    ('sesame oil', 'tbsp'): ('sesame oil', 'tbsp'),
    ('soy sauce', 'tbsp'): ('soy sauce', 'tbsp'),
    ('spinach', 'cup'): ('spinach, raw', 'cup'),
    ('sugar', 'tsp'): ('sugar, white, granulated or lump', 'tsp'),
    ('tahini', 'tbsp'): ('tahini', 'tbsp'),
    ('tomato', 'cup'): ('tomatoes, raw', 'cup'),
    ('tomato', 'slice'): ('tomatoes, raw', 'slice'),
}

# (line_name, unit) -> (fndds_food, fndds_unit, factor)
DERIVED = {
    ('cilantro', 'tbsp'): ('cilantro, raw', 'cup', 0.0625),
    ('green onions', 'tbsp'): ('onions, green, raw', 'cup', 0.0625),
    ('lemon juice', 'tbsp'): ('lemon juice, 100%, freshly squeezed', 'floz', 0.5),
    ('lemon juice', 'tsp'): ('lemon juice, 100%, freshly squeezed', 'floz', 0.16666666666666666),
    ('lime juice', 'tbsp'): ('lime juice, 100%, freshly squeezed', 'floz', 0.5),
    ('olive oil', 'tsp'): ('olive oil', 'tbsp', 0.3333333333333333),
    ('parsley', 'tbsp'): ('parsley, raw', 'cup', 0.0625),
    ('soy sauce', 'tsp'): ('soy sauce', 'tbsp', 0.3333333333333333),
}

SOURCE_NAME = "USDA FoodData Central Survey Foods (FNDDS), edition 2024-10-31, as pinned by MassConversionKit (FridgeLuck PR #50 branch obv/fl-l2-mass-evidence)"
SOURCE_URL = "https://fdc.nal.usda.gov/fdc-datasets/foodData_513.surveyDownload.json.zip?cachebust=2024103101"
RETRIEVED = "2024-10-31"
