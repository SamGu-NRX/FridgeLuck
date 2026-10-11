# Conversion checks: food-group-held-out recovery and conversion-path plumbing

Both checks run the shipped `MassConversionKit` matcher over the
pinned FNDDS table. Unknown conversions are never fabricated into a
number, so every recovered figure comes from matched evidence.

## Food-group-held-out recovery (leave-one-WWEIA-category-out)

Protocol: leave-one-WWEIA-category-out: the entire category is withheld per arm — 167 arms.
Withholding the entire category means no other record for the same
food can remain in the lookup while its sibling is queried (the
earlier every-10th-entry split left same-food records in training,
which overstated recovery).

### Aggregate across arms

- Withheld entries: 7288 across 167 arms
- Recovered by the matcher: 6731 (2 exact, 6729 partial)
- Unknown (no entry matched): 557
- Median rel. error: 20.6% (mean 76.3%)
- Within ±25%: 3658 · within ±50%: 5059

Worst matched-elsewhere recoveries (aggregate):

| Food | Unit | Withheld g | Matched g | Rel. error | Withheld category |
|---|---|---|---|---|---|
| Cookie, tea, Japanese | small | 2 | 360 | 17900.0% | Cookies and brownies |
| Potato sticks, flavored | stick | 3 | 450 | 14900.0% | Potato chips |
| Potato sticks, fry shaped | stick | 3 | 450 | 14900.0% | Potato chips |
| Potato sticks, plain | stick | 3 | 350 | 11566.7% | Potato chips |
| Cookie, tea, Japanese | medium | 5 | 480 | 9500.0% | Cookies and brownies |

### Per-category arms (sorted by category name)

Each row is one leave-one-category-out arm: the entire WWEIA
category was withheld from the lookup and every entry in it was
queried against the remaining table.

| Category | n | Matched | Unknown | Exact | Partial | Median rel. err | Mean rel. err | Within ±25% | Within ±50% |
|---|---|---|---|---|---|---|---|---|---|
| Apple juice | 3 | 3 | 0 | 0 | 3 | 3.2% | 9.7% | 2 | 3 |
| Apples | 10 | 7 | 3 | 0 | 7 | 12.0% | 20.7% | 4 | 7 |
| Baby food: cereals | 14 | 14 | 0 | 0 | 14 | 147.4% | 147.4% | 7 | 7 |
| Baby food: fruit | 13 | 13 | 0 | 0 | 13 | — | — | 13 | 13 |
| Baby food: meat and dinners | 11 | 11 | 0 | 0 | 11 | — | 9.1% | 10 | 10 |
| Baby food: mixtures | 12 | 12 | 0 | 1 | 11 | — | — | 12 | 12 |
| Baby food: snacks and sweets | 13 | 10 | 3 | 0 | 10 | 937.5% | 1059.3% | 2 | 2 |
| Baby food: vegetables | 14 | 14 | 0 | 0 | 14 | — | — | 14 | 14 |
| Baby food: yogurt | 2 | 2 | 0 | 1 | 1 | — | — | 2 | 2 |
| Baby juice | 6 | 6 | 0 | 0 | 6 | 25.8% | 17.2% | 2 | 6 |
| Baby water | 2 | 2 | 0 | 0 | 2 | 37.5% | 37.5% | 1 | 1 |
| Bacon | 26 | 26 | 0 | 0 | 26 | 92.0% | 132.6% | 4 | 4 |
| Bagels and English muffins | 42 | 40 | 2 | 0 | 40 | 37.4% | 38.3% | 13 | 28 |
| Bananas | 3 | 3 | 0 | 0 | 3 | 35.7% | 45.2% | 0 | 2 |
| Bean, pea, legume dishes | 24 | 23 | 1 | 0 | 23 | 17.6% | 24.5% | 16 | 18 |
| Beans, peas, legumes | 74 | 73 | 1 | 0 | 73 | 27.0% | 72.4% | 30 | 54 |
| Beef, excludes ground | 88 | 87 | 1 | 0 | 87 | — | 24.6% | 59 | 70 |
| Beer | 8 | 6 | 2 | 0 | 6 | — | 0.6% | 6 | 6 |
| Biscuits, muffins, quick breads | 79 | 65 | 14 | 0 | 65 | 65.4% | 100.3% | 19 | 29 |
| Blueberries and other berries | 12 | 12 | 0 | 0 | 12 | 10.0% | 17.3% | 9 | 11 |
| Bottled water | 2 | 2 | 0 | 0 | 2 | 12.5% | 12.5% | 2 | 2 |
| Broccoli | 26 | 26 | 0 | 0 | 26 | 56.7% | 56.6% | 11 | 12 |
| Burritos and tacos | 89 | 89 | 0 | 0 | 89 | 45.5% | 54.4% | 23 | 49 |
| Butter and animal fats | 27 | 24 | 3 | 0 | 24 | 11.6% | 19.0% | 18 | 22 |
| Cabbage | 11 | 11 | 0 | 0 | 11 | 11.1% | 18.6% | 9 | 9 |
| Cakes and pies | 95 | 85 | 10 | 0 | 85 | 56.0% | 69.5% | 19 | 38 |
| Candy containing chocolate | 52 | 52 | 0 | 0 | 52 | 4.5% | 50.5% | 35 | 42 |
| Candy not containing chocolate | 47 | 40 | 7 | 0 | 40 | 52.8% | 165.5% | 18 | 19 |
| Carrots | 20 | 20 | 0 | 0 | 20 | 12.7% | 16.6% | 14 | 20 |
| Cereal bars | 2 | 2 | 0 | 0 | 2 | 12.5% | 12.5% | 2 | 2 |
| Cheese | 124 | 112 | 12 | 0 | 112 | 33.3% | 61.5% | 24 | 70 |
| Chicken fillet sandwiches | 4 | 4 | 0 | 0 | 4 | — | — | 4 | 4 |
| Chicken patties, nuggets and tenders | 14 | 12 | 2 | 0 | 12 | 7.1% | 19.6% | 10 | 10 |
| Chicken, whole pieces | 309 | 309 | 0 | 0 | 309 | 3.7% | 18.3% | 188 | 294 |
| Citrus fruits | 11 | 11 | 0 | 0 | 11 | 27.0% | 22.8% | 5 | 11 |
| Citrus juice | 13 | 13 | 0 | 0 | 13 | 11.3% | 15.0% | 7 | 13 |
| Coffee | 440 | 399 | 41 | 0 | 399 | 3.2% | 14.5% | 300 | 366 |
| Cold cuts and cured meats | 86 | 74 | 12 | 0 | 74 | 43.2% | 98.4% | 32 | 43 |
| Coleslaw, non-lettuce salads | 17 | 17 | 0 | 0 | 17 | 22.6% | 26.7% | 9 | 16 |
| Cookies and brownies | 135 | 102 | 33 | 0 | 102 | 303.6% | 797.6% | 3 | 9 |
| Corn | 20 | 20 | 0 | 0 | 20 | 20.6% | 19.4% | 12 | 20 |
| Cottage/ricotta cheese | 17 | 17 | 0 | 0 | 17 | 8.0% | 15.6% | 15 | 15 |
| Crackers, excludes saltines | 47 | 46 | 1 | 0 | 46 | 60.0% | 149.1% | 11 | 23 |
| Cream and cream substitutes | 32 | 32 | 0 | 0 | 32 | — | 28.6% | 25 | 25 |
| Cream cheese, sour cream, whipped cream | 22 | 22 | 0 | 0 | 22 | 3.3% | 58.3% | 18 | 18 |
| Deli and cured meat sandwiches | 86 | 86 | 0 | 0 | 86 | 36.8% | 29.6% | 30 | 85 |
| Diet soft drinks | 26 | 26 | 0 | 0 | 26 | 3.3% | 7.5% | 23 | 26 |
| Diet sport and energy drinks | 28 | 28 | 0 | 0 | 28 | 3.3% | 7.1% | 27 | 27 |
| Dips, gravies, other sauces | 61 | 60 | 1 | 0 | 60 | 1.7% | 11.9% | 41 | 60 |
| Doughnuts, sweet rolls, pastries | 61 | 55 | 6 | 0 | 55 | 44.4% | 111.7% | 13 | 34 |
| Dried fruits | 19 | 18 | 1 | 0 | 18 | 15.6% | 35.5% | 15 | 16 |
| Egg rolls, dumplings, sushi | 36 | 30 | 6 | 0 | 30 | 62.7% | 121.0% | 11 | 13 |
| Egg/breakfast sandwiches | 80 | 80 | 0 | 0 | 80 | 14.7% | 19.2% | 59 | 74 |
| Eggs and omelets | 270 | 151 | 119 | 0 | 151 | 29.6% | 51.1% | 29 | 84 |
| Enhanced water | 4 | 4 | 0 | 0 | 4 | 37.5% | 37.5% | 2 | 2 |
| Fish | 202 | 179 | 23 | 0 | 179 | — | 28.8% | 104 | 144 |
| Flavored milk, lowfat | 14 | 14 | 0 | 0 | 14 | 1.6% | 1.6% | 14 | 14 |
| Flavored milk, nonfat | 18 | 18 | 0 | 0 | 18 | 1.6% | 1.3% | 18 | 18 |
| Flavored milk, reduced fat | 24 | 24 | 0 | 0 | 24 | 1.6% | 8.7% | 22 | 22 |
| Flavored milk, whole | 8 | 8 | 0 | 0 | 8 | 1.6% | 6.1% | 8 | 8 |
| Flavored or carbonated water | 10 | 10 | 0 | 0 | 10 | — | 8.6% | 8 | 10 |
| Formula, prepared from powder | 50 | 50 | 0 | 0 | 50 | 1.6% | 1.2% | 50 | 50 |
| Formula, ready-to-feed | 17 | 17 | 0 | 0 | 17 | — | 0.1% | 17 | 17 |
| Frankfurter sandwiches | 1 | 1 | 0 | 0 | 1 | 35.2% | 35.2% | 0 | 1 |
| Frankfurters | 10 | 10 | 0 | 0 | 10 | 30.5% | 35.3% | 5 | 5 |
| French fries and other fried white potatoes | 56 | 56 | 0 | 0 | 56 | 43.2% | 71.9% | 24 | 28 |
| Fried rice and lo/chow mein | 44 | 44 | 0 | 0 | 44 | 32.1% | 39.3% | 14 | 31 |
| Fried vegetables | 29 | 29 | 0 | 0 | 29 | 47.7% | 102.1% | 10 | 17 |
| Fruit drinks | 56 | 47 | 9 | 0 | 47 | 3.3% | 13.8% | 28 | 47 |
| Gelatins, ices, sorbets | 19 | 12 | 7 | 0 | 12 | 8.3% | 17.2% | 10 | 10 |
| Grapes | 1 | 1 | 0 | 0 | 1 | 10.0% | 10.0% | 1 | 1 |
| Grits and other cooked cereals | 46 | 45 | 1 | 0 | 45 | 39.5% | 47.2% | 11 | 29 |
| Ground beef | 9 | 9 | 0 | 0 | 9 | — | 7.1% | 8 | 9 |
| Human milk | 2 | 2 | 0 | 0 | 2 | 0.9% | 0.9% | 2 | 2 |
| Ice cream and frozen dairy desserts | 29 | 29 | 0 | 0 | 29 | 37.1% | 35.3% | 11 | 23 |
| Jams, syrups, toppings | 52 | 45 | 7 | 0 | 45 | 21.9% | 25.0% | 37 | 40 |
| Lamb, goat, game | 21 | 11 | 10 | 0 | 11 | 3.7% | 63.4% | 6 | 8 |
| Lettuce and lettuce salads | 14 | 14 | 0 | 0 | 14 | 151.1% | 182.7% | 4 | 4 |
| Liquor and cocktails | 68 | 33 | 35 | 0 | 33 | — | 3.0% | 33 | 33 |
| Liver and organ meats | 23 | 10 | 13 | 0 | 10 | 20.1% | 40.7% | 5 | 6 |
| Macaroni and cheese | 16 | 16 | 0 | 0 | 16 | 6.1% | 18.2% | 12 | 13 |
| Mango and papaya | 5 | 5 | 0 | 0 | 5 | 41.3% | 31.6% | 2 | 5 |
| Margarine | 19 | 19 | 0 | 0 | 19 | — | 22.1% | 16 | 17 |
| Mashed potatoes and white potato mixtures | 65 | 65 | 0 | 0 | 65 | 19.3% | 20.4% | 44 | 64 |
| Mayonnaise | 19 | 18 | 1 | 0 | 18 | 7.5% | 12.0% | 16 | 17 |
| Meat and BBQ sandwiches | 10 | 10 | 0 | 0 | 10 | 20.5% | 13.8% | 8 | 10 |
| Meat mixed dishes | 229 | 229 | 0 | 0 | 229 | 12.9% | 18.6% | 154 | 222 |
| Melons | 4 | 4 | 0 | 0 | 4 | 12.9% | 9.7% | 4 | 4 |
| Milk shakes and other dairy drinks | 29 | 28 | 1 | 0 | 28 | 8.9% | 23.4% | 20 | 22 |
| Milk, lowfat | 6 | 4 | 2 | 0 | 4 | 0.8% | 0.8% | 4 | 4 |
| Milk, nonfat | 8 | 8 | 0 | 0 | 8 | 1.6% | 1.2% | 8 | 8 |
| Milk, reduced fat | 8 | 8 | 0 | 0 | 8 | 0.8% | 0.8% | 8 | 8 |
| Milk, whole | 14 | 12 | 2 | 0 | 12 | 1.6% | 7.3% | 10 | 12 |
| Mustard and other condiments | 34 | 25 | 9 | 0 | 25 | 3.3% | 18.1% | 16 | 23 |
| Nachos | 7 | 7 | 0 | 0 | 7 | 29.6% | 36.4% | 3 | 5 |
| Not included in a food category | 72 | 64 | 8 | 0 | 64 | 30.4% | 70.6% | 13 | 50 |
| Nutritional beverages | 35 | 35 | 0 | 0 | 35 | 3.1% | 5.8% | 33 | 34 |
| Nuts and seeds | 176 | 109 | 67 | 0 | 109 | 33.1% | 242.4% | 38 | 59 |
| Oatmeal | 40 | 39 | 1 | 0 | 39 | 32.4% | 102.2% | 14 | 25 |
| Olives, pickles, pickled vegetables | 37 | 34 | 3 | 0 | 34 | 25.8% | 39.8% | 17 | 26 |
| Onions | 11 | 9 | 2 | 0 | 9 | 27.9% | 57.9% | 3 | 6 |
| Other Mexican mixed dishes | 52 | 51 | 1 | 0 | 51 | 20.6% | 35.1% | 31 | 40 |
| Other dark green vegetables | 50 | 50 | 0 | 0 | 50 | 29.6% | 66.3% | 16 | 39 |
| Other diet drinks | 10 | 10 | 0 | 0 | 10 | 1.7% | 8.0% | 8 | 10 |
| Other fruit juice | 20 | 20 | 0 | 0 | 20 | 25.8% | 19.7% | 7 | 20 |
| Other fruits and fruit salads | 42 | 39 | 3 | 0 | 39 | 30.9% | 60.1% | 17 | 29 |
| Other red and orange vegetables | 53 | 53 | 0 | 0 | 53 | 32.0% | 83.5% | 15 | 31 |
| Other starchy vegetables | 43 | 42 | 1 | 0 | 42 | 12.1% | 20.1% | 35 | 38 |
| Other vegetables and combinations | 201 | 197 | 4 | 0 | 197 | 22.2% | 47.8% | 111 | 145 |
| Pancakes, waffles, French toast | 23 | 22 | 1 | 0 | 22 | 65.1% | 64.9% | 4 | 7 |
| Pasta mixed dishes, excludes macaroni and cheese | 228 | 228 | 0 | 0 | 228 | 4.0% | 45.7% | 182 | 196 |
| Pasta sauces, tomato-based | 11 | 11 | 0 | 0 | 11 | — | 5.0% | 10 | 11 |
| Pasta, noodles, cooked grains | 32 | 27 | 5 | 0 | 27 | 65.2% | 94.9% | 8 | 12 |
| Peaches and nectarines | 6 | 6 | 0 | 0 | 6 | 6.5% | 15.4% | 5 | 5 |
| Pears | 5 | 5 | 0 | 0 | 5 | — | 3.2% | 5 | 5 |
| Pineapple | 6 | 6 | 0 | 0 | 6 | 3.3% | 13.4% | 5 | 5 |
| Pizza | 89 | 89 | 0 | 0 | 89 | 37.3% | 54.4% | 28 | 56 |
| Plant-based milk | 34 | 34 | 0 | 0 | 34 | 0.8% | 3.8% | 34 | 34 |
| Plant-based yogurt | 3 | 3 | 0 | 0 | 3 | 8.0% | 5.3% | 3 | 3 |
| Popcorn | 30 | 30 | 0 | 0 | 30 | 640.0% | 1110.2% | 0 | 1 |
| Pork | 62 | 62 | 0 | 0 | 62 | 1.8% | 51.4% | 37 | 47 |
| Potato chips | 30 | 30 | 0 | 0 | 30 | 125.0% | 1602.6% | 2 | 6 |
| Poultry mixed dishes | 119 | 119 | 0 | 0 | 119 | 4.0% | 19.1% | 92 | 109 |
| Pretzels/snack mix | 67 | 67 | 0 | 0 | 67 | 66.0% | 80.1% | 19 | 26 |
| Protein and nutritional powders | 11 | 9 | 2 | 0 | 9 | 32.4% | 87.4% | 4 | 5 |
| Pudding | 26 | 21 | 5 | 0 | 21 | 38.5% | 43.1% | 9 | 14 |
| Ramen and Asian broth-based soups | 16 | 16 | 0 | 0 | 16 | 4.1% | 20.7% | 11 | 12 |
| Ready-to-eat cereal, higher sugar (>21.2g/100g) | 22 | 22 | 0 | 0 | 22 | 33.0% | 168.7% | 10 | 14 |
| Ready-to-eat cereal, lower sugar (=<21.2g/100g) | 21 | 21 | 0 | 0 | 21 | 40.0% | 518.6% | 6 | 13 |
| Rice | 31 | 31 | 0 | 0 | 31 | 12.8% | 20.4% | 25 | 28 |
| Rice mixed dishes | 131 | 131 | 0 | 0 | 131 | 14.4% | 22.6% | 84 | 121 |
| Rolls and buns | 7 | 7 | 0 | 0 | 7 | 45.6% | 63.2% | 2 | 4 |
| Salad dressings and vegetable oils | 102 | 102 | 0 | 0 | 102 | 7.5% | 13.9% | 79 | 99 |
| Saltine crackers | 5 | 5 | 0 | 0 | 5 | — | — | 5 | 5 |
| Sausages | 58 | 46 | 12 | 0 | 46 | 29.5% | 56.2% | 16 | 25 |
| Seafood mixed dishes | 82 | 81 | 1 | 0 | 81 | 11.2% | 17.3% | 59 | 79 |
| Seafood sandwiches | 8 | 8 | 0 | 0 | 8 | 15.8% | 16.0% | 4 | 8 |
| Shellfish | 40 | 35 | 5 | 0 | 35 | 6.2% | 21.6% | 22 | 31 |
| Smoothies and grain drinks | 95 | 88 | 7 | 0 | 88 | 68.1% | 49.4% | 37 | 43 |
| Soft drinks | 26 | 26 | 0 | 0 | 26 | 3.2% | 4.5% | 24 | 26 |
| Soups, broth-based | 70 | 70 | 0 | 0 | 70 | 4.1% | 25.8% | 39 | 59 |
| Soups, cream-based | 23 | 23 | 0 | 0 | 23 | — | 11.3% | 22 | 22 |
| Soy and meat-alternative products | 22 | 20 | 2 | 0 | 20 | 27.8% | 33.8% | 9 | 14 |
| Soy-based condiments | 10 | 9 | 1 | 0 | 9 | — | 2.6% | 9 | 9 |
| Spinach | 15 | 15 | 0 | 0 | 15 | 20.9% | 47.9% | 8 | 14 |
| Sport and energy drinks | 46 | 45 | 1 | 0 | 45 | 3.2% | 9.9% | 40 | 40 |
| Stir-fry and soy-based sauce mixtures | 69 | 68 | 1 | 0 | 68 | 16.7% | 19.8% | 42 | 67 |
| Strawberries | 3 | 3 | 0 | 0 | 3 | 10.0% | 18.7% | 2 | 3 |
| String beans | 20 | 20 | 0 | 0 | 20 | 13.8% | 14.4% | 19 | 20 |
| Sugar substitutes | 10 | 10 | 0 | 0 | 10 | 23.6% | 173.0% | 5 | 7 |
| Sugars and honey | 15 | 13 | 2 | 0 | 13 | 30.0% | 35.9% | 5 | 9 |
| Tap water | 4 | 4 | 0 | 0 | 4 | 1.7% | 19.6% | 3 | 3 |
| Tea | 86 | 85 | 1 | 0 | 85 | 30.4% | 44.0% | 33 | 55 |
| Tomato-based condiments | 17 | 15 | 2 | 0 | 15 | 5.9% | 16.7% | 12 | 13 |
| Tomatoes | 8 | 8 | 0 | 0 | 8 | 36.5% | 49.9% | 2 | 6 |
| Tortilla, corn, other chips | 36 | 35 | 1 | 0 | 35 | 211.1% | 741.4% | 6 | 8 |
| Tortillas | 18 | 10 | 8 | 0 | 10 | 157.1% | 192.8% | 0 | 0 |
| Turkey, duck, other poultry | 66 | 64 | 2 | 0 | 64 | 3.6% | 19.5% | 42 | 55 |
| Turnovers and other grain-based items | 16 | 13 | 3 | 0 | 13 | 51.6% | 42.2% | 3 | 6 |
| Vegetable dishes | 35 | 33 | 2 | 0 | 33 | 23.2% | 32.2% | 21 | 26 |
| Vegetable juice | 11 | 11 | 0 | 0 | 11 | 25.8% | 24.0% | 4 | 11 |
| Vegetable sandwiches/burgers | 9 | 8 | 1 | 0 | 8 | 28.5% | 28.5% | 0 | 8 |
| White potatoes, baked or boiled | 180 | 180 | 0 | 0 | 180 | 56.2% | 52.5% | 34 | 73 |
| Wine | 13 | 12 | 1 | 0 | 12 | — | 0.4% | 12 | 12 |
| Yeast breads | 104 | 104 | 0 | 0 | 104 | 276.9% | 279.7% | 5 | 5 |
| Yogurt, Greek | 14 | 14 | 0 | 0 | 14 | — | 0.1% | 14 | 14 |
| Yogurt, regular | 15 | 15 | 0 | 0 | 15 | — | 2.0% | 14 | 15 |

## 100-meal conversion-path plumbing check (NOT a yield study)

Label: conversion-path plumbing check: prefix queries always overlap their source description — not a name-resolution measure, not a yield study.

- Ingredients: 300
- Converted with evidence: 300 (98 exact, 202 partial) — 100.0% conversion rate
- Unknown: 0
- Fully converted meals: 100/100 — 100.0% of meals

Meal queries are intake-style (first three words of the FNDDS
description). Because those words are a token prefix of the source
description, they always overlap it — so this check validates the
end-to-end conversion path (unit choice, lookup, evidence levels)
over census-derived meals. It is plumbing, not a yield study:
successful conversion of generated meal bundles says nothing about
cooking yield. Cooking-yield sensitivity is derived source-bound in
`yield_sensitivity.{json,md}`; real-world coverage of partial user
input is not measured here.
