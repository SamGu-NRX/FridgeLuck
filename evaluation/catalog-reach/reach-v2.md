# Catalog reach v2: named households and diet gates

Ten written pantries resolved against the app ingredient space (exact match
with snake_case and plural-fold candidates; unresolved names disclosed
below). Diet eligibility follows the app gate: a recipe is eligible only
when its bundle claim is `true`. Medians across the ten pantries; "exact"
needs every required line in the pantry, "near" allows at most 2 missing.

## Diet-eligible cookable recipes (median across the 10 pantries)

| diet | shipped exact | new exact | shipped near | new near | near delta |
|---|---|---|---|---|---|
| omnivore | 2.0 | 2.0 | 129.5 | 129.5 | +0 |
| vegetarian | 0.0 | 1.0 | 3.0 | 83.5 | +80.5 |
| vegan | 0.0 | 0.0 | 0.0 | 23.5 | +23.5 |
| gluten_free | 0.0 | 0.5 | 5.5 | 60.0 | +54.5 |
| dairy_free | 0.0 | 0.0 | 3.0 | 59.5 | +56.5 |

## Claims marked true (catalog-wide)

| diet | shipped | new build |
|---|---|---|
| dairy_free | 9 | 306 |
| gluten_free | 13 | 336 |
| vegan | 2 | 121 |
| vegetarian | 7 | 327 |

## Per-pantry detail (new build)

| pantry | resolved/requested | unresolved | cookable exact | cookable near | vegetarian near | vegan near | gluten_free near | dairy_free near |
|---|---|---|---|---|---|---|---|---|
| starter_apartment | 11/14 | cheddar, canned tomatoes, salt | 2 | 160 | 92 | 23 | 73 | 70 |
| family_freezer | 10/14 | peas, flour tortillas, cheddar, salsa | 3 | 128 | 59 | 24 | 63 | 62 |
| vegan_pantry | 13/15 | lentils, vegetable stock | 2 | 104 | 59 | 37 | 47 | 62 |
| gluten_free_household | 12/14 | corn tortillas, salsa | 8 | 193 | 110 | 27 | 96 | 91 |
| student_minimal | 9/12 | cheddar, hot dogs, instant ramen | 1 | 154 | 90 | 17 | 62 | 53 |
| baker | 5/13 | flour, sugar, brown sugar, baking powder, vanilla extract, chocolate chips, apples, cinnamon | 1 | 124 | 81 | 16 | 58 | 44 |
| pescatarian | 11/14 | shrimp, parmesan, capers | 5 | 174 | 93 | 32 | 86 | 90 |
| keto_household | 10/13 | bacon, chicken thighs, almonds | 2 | 131 | 86 | 25 | 58 | 57 |
| south_asian | 8/14 | basmati rice, ghee, turmeric, garam masala, red lentils, green chilies | 0 | 91 | 45 | 17 | 45 | 47 |
| empty_nesters | 5/12 | chicken thighs, pork chops, frozen vegetables, cream of mushroom soup, apples, orange juice, saltine crackers | 0 | 94 | 46 | 23 | 43 | 53 |
