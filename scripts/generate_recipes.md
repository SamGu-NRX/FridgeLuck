# Recipe Generation Guide

## Overview

The bundled `data.json` ships with 25 starter recipes and 50 ingredients. 
To reach 1000+ recipes, use LLM batch generation with the prompts below.

## Ingredient Database

The 50 ingredients (IDs 1-50) are sourced from USDA FoodData Central with
per-100g nutrition values (calories, protein, carbs, fat, fiber, sugar, sodium).

To add more ingredients, append to the `ingredients` object in `data.json`
with sequential IDs (51, 52, ...) following the format:

```
"51": ["ingredient_name", cal, protein, carbs, fat, fiber, sugar, sodium, "unit", "storage tip"]
```

## Batch Generation Prompt

Use this prompt with Claude, GPT-4, or similar to generate recipes in batches of 50:

```
Generate 50 recipes in this exact JSON array format. Each recipe is an array:
[id, "Title", time_minutes, servings, required_ingredients, optional_ingredients, "Instructions", tag_bitmask]

Where:
- required_ingredients: [[ingredient_id, grams], ...] — ingredients that MUST be present
- optional_ingredients: [[ingredient_id, grams], ...] — nice to have but not required
- tag_bitmask: integer bitmask from these tags (bit positions):
  0=quick, 1=vegetarian, 2=vegan, 3=asian, 4=breakfast, 5=budget, 
  6=comfort, 7=mediterranean, 8=mexican, 9=high_protein, 10=low_carb, 11=one_pot

Available ingredients (ID: name):
1: egg, 2: rice, 3: soy_sauce, 4: chicken_breast, 5: onion, 6: garlic,
7: tomato, 8: bell_pepper, 9: pasta, 10: potato, 11: carrot, 12: cheese,
13: milk, 14: butter, 15: bread, 16: olive_oil, 17: lemon, 18: mushroom,
19: spinach, 20: banana, 21: green_onion, 22: sesame_oil, 23: tofu,
24: broccoli, 25: cucumber, 26: avocado, 27: black_beans, 28: tortilla,
29: lime, 30: ginger, 31: oats, 32: yogurt, 33: honey, 34: corn,
35: chickpea, 36: salmon, 37: sweet_potato, 38: ground_beef, 39: lettuce,
40: apple, 41: peanut_butter, 42: frozen_peas, 43: canned_tuna,
44: celery, 45: zucchini, 46: red_pepper_flakes, 47: cumin,
48: cilantro, 49: coconut_milk, 50: sour_cream

Requirements:
- Use realistic gram quantities (e.g., 1 egg = 50g, not 500g)
- 3-6 required ingredients per recipe, 0-3 optional
- Diverse cuisines and meal types
- Start IDs at [START_ID]
- Each recipe must have clear, numbered instructions
- Mix quick (10-15 min) and moderate (20-45 min) cook times
- Student-friendly: minimal equipment, common techniques

Output ONLY the JSON arrays, one per line, wrapped in [ ].
```

## Verification Script

After generating, verify data quality:

1. All ingredient IDs exist (1-50, or extended range)
2. Gram quantities are realistic (no single ingredient > 1000g)
3. No duplicate recipe titles
4. Tag bitmasks are valid (0 to 4095 for 12 tags)
5. Each recipe has at least 2 required ingredients
6. Instructions are present and numbered

## Target Distribution

| Category              | Count | Tag bits to include |
|-----------------------|-------|---------------------|
| Quick meals (<15 min) | 200   | bit 0 (quick)       |
| Asian-inspired        | 150   | bit 3 (asian)       |
| Mediterranean         | 100   | bit 7               |
| Mexican-inspired      | 100   | bit 8               |
| Breakfast             | 100   | bit 4               |
| Soups & stews         | 100   | bit 11 (one_pot)    |
| Pasta dishes          | 100   | —                   |
| Salads & bowls        | 80    | —                   |
| Budget meals          | 100   | bit 5 (budget)      |
| **Total**             | ~1030 |                     |

Categories overlap — a quick Asian breakfast counts in multiple buckets.
Run 20 batches of 50 recipes each to reach the target.
