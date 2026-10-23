# Bundled Recipe Audit (food safety)

Regenerates from the committed command in `packages/FLFoodSafety/README.md`. Deterministic: byte-identical for the same rulebook and corpus — no timestamps, no locale dependence.

- Rulebook: `data/food-safety/rules.json` (schema 1; quotes retrieved 2026-10-11 from USDA FSIS, FDA, FoodSafety.gov or CDC)
- Corpus: `apps/ios/Resources/data.json` — 166 bundled recipes, all listed in the index below
- Scope: safety phrasing only — doneness by appearance, time-only protein cooking, raw-egg warnings, ambient thawing, leftovers held out, reheating without a thermometer. Rights, nutrition and language review are separate suites.
- Doneness standard: a food thermometer at the USDA FSIS safe minimum internal temperature. Appearance (colour, no pink, clear juices, firmness, browning) is never a safety verdict.

## Summary

| Metric | Value |
| --- | --- |
| Recipes audited | 166 |
| Recipes with flagged steps | 83 |
| Flagged steps (total) | 133 |
| appearanceDoneness flags | 45 |
| timeOnlyCooking flags | 72 |
| rawEggNoWarning flags | 0 |
| ambientThawing flags | 0 |
| leftoversHeldOut flags | 0 |
| reheatingWithoutThermometer flags | 16 |

## Recipe index

| ID | Recipe | Flagged steps |
| --- | --- | --- |
| 1 | Classic Egg Fried Rice | — |
| 2 | Simple Cheese Omelette | 1 |
| 3 | Garlic Butter Pasta | — |
| 4 | Chicken Stir-Fry | 1 |
| 5 | Tomato Egg Drop Soup | — |
| 6 | Avocado Toast with Egg | 1 |
| 7 | Black Bean Tacos | — |
| 8 | Overnight Oats | 1 |
| 9 | One-Pot Chicken Rice | 1 |
| 10 | Caprese Salad | — |
| 11 | Loaded Baked Potato | 1 |
| 12 | Peanut Butter Banana Smoothie | — |
| 13 | Vegetable Stir-Fry with Tofu | — |
| 14 | Mediterranean Chickpea Salad | — |
| 15 | Simple Salmon with Veggies | 1 |
| 16 | Quick Tuna Salad | — |
| 17 | Beef Taco Bowl | — |
| 18 | Spinach Mushroom Scramble | — |
| 19 | Coconut Curry Vegetables | — |
| 20 | Sweet Potato & Black Bean Bowl | — |
| 21 | Classic French Toast | 1 |
| 22 | Garlic Lemon Chicken | 1 |
| 23 | Mushroom Risotto | — |
| 24 | Egg & Veggie Breakfast Wrap | — |
| 25 | Banana Oat Pancakes | 1 |
| 26 | 10-minute couscous salad | — |
| 27 | Air fryer tuna pasta bake | 1 |
| 28 | Allotment salad | — |
| 29 | Artichoke & aubergine rice | 1 |
| 30 | Healthy chicken salad | 1 |
| 31 | Asparagus & broad bean fattoush with crispy asparagus ends | — |
| 32 | Aubergine, chilli & bacon pasta | 1 |
| 33 | Vegetarian enchiladas | — |
| 34 | Black bean & pineapple salad bowl | — |
| 35 | Black bean & tortilla soup | — |
| 36 | Bombay potato frittata | 3 |
| 37 | Burrito bowl with chipotle black beans | 1 |
| 38 | Butter bean curry | 1 |
| 39 | Cajun grilled chicken with lime black-eyed bean salad & guacamole | 1 |
| 40 | Caramelised red onion & anchovy pasta with gremolata | — |
| 41 | Cardamom chicken with lime leaves | 1 |
| 42 | Cauliflower, paneer & pea curry | — |
| 43 | Cavolo nero orecchiette | — |
| 44 | Celery soup | — |
| 45 | Chetna's end-of-summer veg curry | 2 |
| 46 | Chicken & chorizo jambalaya | 2 |
| 47 | Chicken & chorizo ragu | 2 |
| 48 | Chicken with crushed harissa chickpeas | 2 |
| 49 | Chicken jalfrezi | 1 |
| 50 | Chicken korma | 2 |
| 51 | Chicken, leek & brown rice stir-fry | 2 |
| 52 | Chicken & lemon skewers | 2 |
| 53 | Chicken madras | 1 |
| 54 | Chicken and mushrooms | 1 |
| 55 | Chicken parmesan | 1 |
| 56 | Chicken satay salad | 1 |
| 57 | Chicken & tzatziki wraps | 1 |
| 58 | Chinese chicken curry | 1 |
| 59 | Healthy chilli con carne | 2 |
| 60 | Coconut & squash dhansak | 2 |
| 61 | Cod with cucumber, avocado & mango salsa salad | 1 |
| 62 | Crab linguine with chilli & parsley | — |
| 63 | Creamy pesto & kale pasta | — |
| 64 | Creamy tomato risotto | — |
| 65 | Crispy grilled feta with saucy butter beans | — |
| 66 | Crunchy noodle salad | — |
| 67 | Curried cod | 1 |
| 68 | Curried satay noodles | — |
| 69 | Diet cola chicken | 2 |
| 70 | Double bean & roasted pepper chilli | 1 |
| 71 | Duck ragu with pappardelle & swede | 2 |
| 72 | Easiest ever seafood rice | — |
| 73 | Easy risotto with bacon & peas | — |
| 74 | Egg-fried noodles with beansprouts | — |
| 75 | Fresh salmon niçoise | 2 |
| 76 | Giant couscous salad with charred veg & tangy pesto | — |
| 77 | Ginger chicken udon noodles | 2 |
| 78 | Green goddess avocado salad | 1 |
| 79 | Halloumi, carrot & orange salad | — |
| 80 | Halloumi pasta | 1 |
| 81 | Healthy bolognese | 1 |
| 82 | Healthy chicken burritos | 1 |
| 83 | Healthy pad Thai | — |
| 84 | Healthy chicken pasta bake | 1 |
| 85 | Healthy gnocchi | 1 |
| 86 | Healthy tikka masala | 2 |
| 87 | Hummus flatbread pizzas with roasted veg | 1 |
| 88 | Indian chickpeas with poached eggs | 1 |
| 89 | Italian borlotti bean, pumpkin & farro soup | — |
| 90 | Italian vegetable soup | — |
| 91 | Jerk chicken burger | 1 |
| 92 | Jerk-style cauliflower with coconut rice | 1 |
| 93 | Kidney bean curry | — |
| 94 | Masala frittata with avocado salsa | 2 |
| 95 | Mexican bean soup with guacamole | — |
| 96 | Mexican chicken stew with quinoa & beans | 1 |
| 97 | Tomato penne with avocado | — |
| 98 | Miso noodles with fried eggs | — |
| 99 | Moroccan aubergine & chickpea salad | — |
| 100 | Moroccan chicken | 1 |
| 101 | Moroccan chicken stew | 3 |
| 102 | Moroccan-style chickpea soup | — |
| 103 | Moroccan chickpea, squash & cavolo nero stew | — |
| 104 | Nduja & spring greens pasta | — |
| 105 | Nutty chicken satay strips | 1 |
| 106 | One-pan beef stew with vegetable mash | 1 |
| 107 | One-pot garlicky chicken thighs & giant cous cous | 2 |
| 108 | One-pot goulash pasta | 2 |
| 109 | Tomato & pasta soup | — |
| 110 | Paillard of chicken with lemon & herbs | — |
| 111 | Pasta with pine nuts, broccoli, sardines & fennel | — |
| 112 | Peanut lime salad | — |
| 113 | Pasta arrabbiata with aubergine | — |
| 114 | Sausage traybake | — |
| 115 | Pomegranate chicken with almond couscous | 2 |
| 116 | Prawn & salmon burgers with spicy mayo | 1 |
| 117 | Pulled chicken & black bean chilli | 2 |
| 118 | Quick chicken hummus bowl | — |
| 119 | Salade niçoise | — |
| 120 | Salmon salad with sesame dressing | 1 |
| 121 | Sardine tomato pasta with gremolata | 1 |
| 122 | Sweet potato & peanut curry | — |
| 123 | Sausage & kale minestrone | — |
| 124 | Sea bass with sizzled ginger, chilli & spring onions | 3 |
| 125 | Sesame chicken salad | 1 |
| 126 | Sichuan smacked cucumber noodles | — |
| 127 | Quick and easy fish stew | 1 |
| 128 | Smoky beans on toast | — |
| 129 | Smoky chickpea salad | — |
| 130 | Smoky tomato, chipotle & charred corn soup | 1 |
| 131 | Smoky white bean & ricotta traybake | — |
| 132 | Healthy spaghetti bolognese | — |
| 133 | Somerset stew with cheddar & parsley mash | — |
| 134 | Soy-baked potatoes with tuna sriracha mayo | 2 |
| 135 | Spiced carrot & lentil soup | — |
| 136 | Spiced lentil & butternut squash soup | — |
| 137 | Spicy bean & avocado quesadillas | — |
| 138 | Spicy cucumber & watermelon salad | — |
| 139 | Spicy harissa bean stew | 1 |
| 140 | Spicy root & lentil casserole | 1 |
| 141 | Spicy tofu tahini noodle salad | — |
| 142 | Spinach, sweet potato & lentil dhal | — |
| 143 | Spring chicken in a pot | — |
| 144 | Spring tabbouleh | — |
| 145 | Spring vegetable & cauliflower tabbouleh | — |
| 146 | Sticky aubergine & tomato salad | — |
| 147 | Sticky miso aubergine traybake | 1 |
| 148 | Super-veg pasta | — |
| 149 | Superhealthy salmon burgers | 1 |
| 150 | Superhealthy Singapore noodles | — |
| 151 | Taco salad | — |
| 152 | Thai-style steamed fish | — |
| 153 | Tomato & black bean taco salad | — |
| 154 | Tomato, pepper & bean one pot | 1 |
| 155 | Tomato soup & hummus crispbreads | 1 |
| 156 | Tomato & thyme cod | 2 |
| 157 | Tuna, bean & olive salad | — |
| 158 | Tuna, caper & chilli spaghetti | 1 |
| 159 | The ultimate makeover: Chicken pie | 1 |
| 160 | Vegan chickpea curry jacket potatoes | — |
| 161 | Vegan chilli | — |
| 162 | Vegetarian ramen | 1 |
| 163 | Veggie olive wraps with mustard vinaigrette | — |
| 164 | Venetian duck ragu | 2 |
| 165 | Warm cauliflower salad | — |
| 166 | Zesty haddock with crushed potatoes & peas | 1 |

## Findings

### 2 — Simple Cheese Omelette

- **Step 3** — `timeOnlyCooking` — rule `raw-eggs-firm`
  - Step text: “Pour in eggs, let set 1 minute”
  - Problem: “eggs” is cooked for a stated time with no thermometer check — time alone never establishes doneness — US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety: “Cook eggs until both the yolk and the white are firm. Scrambled eggs should not be runny.” (<https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)

### 4 — Chicken Stir-Fry

- **Step 4** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Sear chicken 3-4 min until golden”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Sear chicken 3-4 min until golden”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 6 — Avocado Toast with Egg

- **Step 1** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Toast bread until golden”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 8 — Overnight Oats

- **Step 7** — `timeOnlyCooking` — rule `leftovers-reheat-165`
  - Step text: “Eat cold or microwave 1 min”
  - Problem: “microwave” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 9 — One-Pot Chicken Rice

- **Step 2** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat oil in pot, brown chicken 4-5 min”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 11 — Loaded Baked Potato

- **Step 4** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Bake 40-45 minutes until tender”
  - Problem: “bake” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 15 — Simple Salmon with Veggies

- **Step 7** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Bake 15-18 minutes until fish flakes”
  - Problem: “fish” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 21 — Classic French Toast

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Cook each side 2-3 min until golden”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 22 — Garlic Lemon Chicken

- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Sear chicken 4 min each side”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 25 — Banana Oat Pancakes

- **Step 6** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Cook 2-3 min per side until golden”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 27 — Air fryer tuna pasta bake

- **Step 8** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Air-fry for 5 mins until golden, then cover with foil and cook for a further 5 mins until bubbling. Serve warm with salad.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 29 — Artichoke & aubergine rice

- **Step 4** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Nestle the aubergine and artichokes into the mixture, pour over the rest of the stock and cook for 20 mins more or until the rice is cooked through. Chop the parsley leaves, stir through with the lemon juice and season well. Bring the whole pan to the table and spoon into bowls, with the lemon wedges on the side.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 30 — Healthy chicken salad

- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Cover the chicken with cold water, bring to the boil, then cook for 10 mins. Remove from the pan and tear into shreds. Stir together the fish sauce, lime zest, juice and sugar until sugar dissolves.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 32 — Aubergine, chilli & bacon pasta

- **Step 6** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a large frying pan. Add the aubergine and cook for 8 mins until soft. Add the bacon and fry until cooked through, adding the garlic and chilli for the final min. Tip in the tomatoes, increase the heat and cook for 10 mins until thickened, stirring regularly.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 36 — Bombay potato frittata

- **Step 7** — `timeOnlyCooking` — rule `leftovers-reheat-165`
  - Step text: “Cook the potatoes in a pan of boiling water for 6 mins, or until tender. Drain and leave to steam-dry. Meanwhile, put the spinach in a heatproof bowl with 1 tbsp water. Cover and microwave for 3 mins on high, or until wilted.”
  - Problem: “microwave” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 8** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the rapeseed oil in a medium non-stick frying pan. Add the onion and cook over a medium heat for 10 mins until golden and sticky. Stir in the garlic, ground coriander, ground cumin, mustard seeds and turmeric, and cook for 1 min more. Add the tomatoes and wilted spinach and cook for another 3 mins, then add the potatoes.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 9** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the grill to medium. Lightly beat the eggs with the chilli and most of the fresh coriander and pour over the potato mixture. Grill for 4-5 mins, or until golden and just set, with a very slight wobble in the middle.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the centre of the egg dish or the yolk reaches 71 °C (160 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 37 — Burrito bowl with chipotle black beans

- **Step 6** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Cook the rice following pack instructions, then drain and return to the pan to keep warm. In a frying pan, heat the oil, add the garlic and fry for 2 mins or until golden. Add the beans, vinegar, honey and chipotle. Season and warm through for 2 mins.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 38 — Butter bean curry

- **Step 12** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “For the raita, toss the bananas in the lime juice. Add the cucumber, onion, chilli and remaining coriander. Warm the rice following pack instructions and serve with half the curry and raita. Cool and chill the rest of the curry and raita to make our butter bean curry wraps. The curry will keep chilled for up to three days. The raita keeps chilled for a day.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 39 — Cajun grilled chicken with lime black-eyed bean salad & guacamole

- **Step 9** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the grill. Line a grill pan with foil, place the chicken breasts on it and grill for 5 mins, checking occasionally. Once golden brown, turn and grill for a further 5-7 mins. Check the middle of the breasts after 5 mins and, if cooked through, remove from the heat.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 9** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the grill. Line a grill pan with foil, place the chicken breasts on it and grill for 5 mins, checking occasionally. Once golden brown, turn and grill for a further 5-7 mins. Check the middle of the breasts after 5 mins and, if cooked through, remove from the heat.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 41 — Cardamom chicken with lime leaves

- **Step 9** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Stir in the aubergine, bring to the boil then cover the pan and simmer for 15 mins. Stir well, and add the chicken and lime leaves. Push them under the liquid and scatter over the green pepper. Cover the pan and leave to cook for 40 mins. Remove the chicken, shred in to medium-sized pieces and return to the sauce.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 45 — Chetna's end-of-summer veg curry

- **Step 8** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a pan over medium heat and toast the mustard seeds until popping. Add the onions and cook for 8-10 mins until golden and softened. Add the garlic, ginger and chilli, and cook for 1 min more.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 10** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Add the spice mix and remaining veg, season and mix well. Cook for another 8-10 mins until the veg is cooked through but still has a bite. Once cool, will keep frozen for two months. Defrost thoroughly and reheat until piping hot. Stir in the yogurt and warm through gently – don’t boil, or the yogurt will split. Taste for seasoning, scatter over the herbs and serve.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 10** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Add the spice mix and remaining veg, season and mix well. Cook for another 8-10 mins until the veg is cooked through but still has a bite. Once cool, will keep frozen for two months. Defrost thoroughly and reheat until piping hot. Stir in the yogurt and warm through gently – don’t boil, or the yogurt will split. Taste for seasoning, scatter over the herbs and serve.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 46 — Chicken & chorizo jambalaya

- **Step 1** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat 1 tbsp olive oil in a large frying pan with a lid over a medium-high heat and brown 2 chopped chicken breasts for 5-8 mins until golden.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 1** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat 1 tbsp olive oil in a large frying pan with a lid over a medium-high heat and brown 2 chopped chicken breasts for 5-8 mins until golden.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Stir the chicken back in with 250g long grain rice, add the 400g can of tomatoes and 350ml chicken stock. Cover and simmer over a medium heat for 20-25 mins until the rice is tender.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 47 — Chicken & chorizo ragu

- **Step 2** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Fry the chorizo over a medium heat in a large saucepan or flameproof casserole dish for 5 mins or until it releases its oil and starts to char at the edges. Add the onion and fry for 5 mins more or until soft. Tip in the garlic and cook for 2 mins before stirring in the paprika and sundried tomatoes. Add the chicken thighs and fry for 2 mins each side until they are well coated in the spices and beginning to brown.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 3** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Pour in the chopped tomatoes and stock, and turn the heat down. Cover and cook for 40 mins until the chicken is falling apart and the sauce is thick. Stir the lemon juice through. Serve by piling spoonfuls of the ragu into hot jacket potatoes with parsley sprinkled over and a dollop of soured cream, if you like.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 48 — Chicken with crushed harissa chickpeas

- **Step 3** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat 1 tbsp of oil in a frying pan over a medium heat and fry the onions and peppers for 7 mins until softened and golden.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the grill to high. Put the chicken on a baking tray lined with foil, and grill for 3-4 mins each side, or until golden and cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the grill to high. Put the chicken on a baking tray lined with foil, and grill for 3-4 mins each side, or until golden and cooked through.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 49 — Chicken jalfrezi

- **Step 8** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Add the sauce you prepared earlier to the cooked chicken and simmer for around 10-20 minutes, adding a splash of water if it gets too thick.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 50 — Chicken korma

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Add 50g ground almonds, 4 tbsp sultanas, 400ml chicken stock and ¼ tsp golden caster sugar.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 6** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Give everything a good mix, then cover and simmer for 10 mins or until the chicken is cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 6** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Give everything a good mix, then cover and simmer for 10 mins or until the chicken is cooked through.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 51 — Chicken, leek & brown rice stir-fry

- **Step 6** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a frying pan over a high heat and fry the chicken for 3 mins. Stir in the chorizo and cook for 2 mins more until the chicken is light golden and the chorizo has released its fat. Scoop the chicken and chorizo into a bowl using a slotted spoon, leaving as much oil in the pan as you can. Set aside.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 6** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the oil in a frying pan over a high heat and fry the chicken for 3 mins. Stir in the chorizo and cook for 2 mins more until the chicken is light golden and the chorizo has released its fat. Scoop the chicken and chorizo into a bowl using a slotted spoon, leaving as much oil in the pan as you can. Set aside.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 8** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Drizzle in the soy sauce and vinegar and scatter in the rice, breaking up any large chunks with a wooden spoon. Stir the chicken and chorizo back into the pan and toss everything together to combine. Cook for 3 mins until the rice is heated through, then serve.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 52 — Chicken & lemon skewers

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “When you’re ready to cook the chicken, heat your grill to a medium heat and line the grill tray with foil. Thread the chicken onto the soaked wooden or metal skewers and grill for 15-20 mins, turning halfway through, until browned and cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 6** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Warm the flatbreads under the grill for a couple of seconds, then serve them topped with the lettuce, chicken, red onion, remaining lemon juice and mint, and any optional extras such as extra yogurt or pickled cabbage, chilli sauce and hummus.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 53 — Chicken madras

- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Pour in 400g can chopped tomatoes, along with a big pinch of salt, cover and cook on a low heat for 30 mins, until the chicken is tender.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 54 — Chicken and mushrooms

- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Add the final tbsp oil and cook shallots for 5 mins. Add the stock and vinegar, bubble for 1-2 mins. Return the chicken, pancetta and mushrooms and cook for 15 mins. Add the peas and parsley and cook for 2 mins more, then serve.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 55 — Chicken parmesan

- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat grill to High and cook the chicken for 5 mins each side, then remove.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 56 — Chicken satay salad

- **Step 3** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Pour the tamari into a large dish and stir in the curry powder, cumin, garlic and honey. Mix well. Slice the chicken breasts in half horizontally to make 4 fillets in total, then add to the marinade and mix well to coat. Set aside in the fridge for at least 1 hr, or overnight, to allow the flavours to penetrate the chicken.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 57 — Chicken & tzatziki wraps

- **Step 4** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “For the tzatziki, tip the grated cucumber and yogurt into a bowl, mix well and season. Set aside. Season the chicken with salt and pepper and rub with 1 tbsp of the olive oil. Heat the remaining oil in a pan over a medium heat. Cook the chicken for 8-10 mins until cooked through and golden brown.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “For the tzatziki, tip the grated cucumber and yogurt into a bowl, mix well and season. Set aside. Season the chicken with salt and pepper and rub with 1 tbsp of the olive oil. Heat the remaining oil in a pan over a medium heat. Cook the chicken for 8-10 mins until cooked through and golden brown.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 58 — Chinese chicken curry

- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Wipe out the pan and fry the chicken in the remaining oil until it is browned all over. Tip the sauce back into the pan and bring everything to a simmer, stir in the peas and cook for 5 minutes. Add a little water if you need to thin the sauce. Serve with rice.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 59 — Healthy chilli con carne

- **Step 5** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Add the onion to the pan, with extra oil if needed, and cook until softened. Stir in the garlic, cumin and chipotle paste, and cook for 1 min. Sieve the kidney beans, reserving the sauce. Add this sauce, along with the chopped tomatoes and a can full of water, to the pan. Stir well, then return the meat to the pan. Bring to a simmer, then cook, covered, for 2 hrs or until the beef is tender (or bake in the oven for 3 hrs at 160C/140C fan/gas 3).”
  - Problem: “bake” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Add the reserved kidney beans and lime zest, season and warm through. Serve with a scattering of coriander leaves, the lime wedges to squeeze over, and rice, if you like.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 60 — Coconut & squash dhansak

- **Step 4** — `timeOnlyCooking` — rule `leftovers-reheat-165`
  - Step text: “Heat the oil in a large pan. Put the squash in a bowl with a splash of water. Cover with cling film and microwave on High for 10 mins or until tender. Meanwhile, add the onions to the hot oil and cook for a few mins until soft. Add the curry paste, tomatoes and coconut milk, and simmer for 10 mins until thickened to a rich sauce.”
  - Problem: “microwave” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 4** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Heat the oil in a large pan. Put the squash in a bowl with a splash of water. Cover with cling film and microwave on High for 10 mins or until tender. Meanwhile, add the onions to the hot oil and cook for a few mins until soft. Add the curry paste, tomatoes and coconut milk, and simmer for 10 mins until thickened to a rich sauce.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)
- **Step 5** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Warm the naan breads in a low oven or in the toaster. Drain any liquid from the squash, then add to the sauce with the lentils, spinach and some seasoning. Simmer for a further 2-3 mins to wilt the spinach, then stir in the coconut yogurt. Serve with the warm naan and a dollop of extra yogurt.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 61 — Cod with cucumber, avocado & mango salsa salad

- **Step 7** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Heat oven to 200C/180C fan/gas 6. Put the cod fillets in a shallow ovenproof dish and pour over half the lime juice, with a little of the zest, then grind over some black pepper. Bake for 8 mins or until the fish flakes easily but is still moist.”
  - Problem: “cod” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 67 — Curried cod

- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Cook for 8-10 mins until thickened slightly, then top with the cod. Cover and cook for another 5-10 mins until the fish is cooked through. Scatter over the lemon zest and coriander, then serve with the lemon wedges to squeeze over.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 7** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Cook for 8-10 mins until thickened slightly, then top with the cod. Cover and cook for another 5-10 mins until the fish is cooked through. Scatter over the lemon zest and coriander, then serve with the lemon wedges to squeeze over.”
  - Problem: “cod” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 69 — Diet cola chicken

- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the oil in a large non-stick saucepan over a high heat. Season, then brown the chicken thighs all over for 4-5 mins. Remove with tongs and set aside on a plate.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Stir in the oregano, brown sugar, mustard, Worcestershire sauce, tomato purée, diet cola, remaining stock and ketchup. Bring to the boil, then reduce the heat, add the chicken back to the pan and simmer for 10 mins, covered, until the chicken is cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 6** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Stir in the oregano, brown sugar, mustard, Worcestershire sauce, tomato purée, diet cola, remaining stock and ketchup. Bring to the boil, then reduce the heat, add the chicken back to the pan and simmer for 10 mins, covered, until the chicken is cooked through.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 70 — Double bean & roasted pepper chilli

- **Step 5** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “At this stage you can cool and chill the sauce if making ahead. Otherwise add the kidney and black beans, and the remaining roasted peppers, cut into bite-sized pieces, then reheat. (This makes a large batch, so once the sauce is ready it might be easier to split it between two pans when you add the beans and peppers.) Once bubbling and the beans are hot, season to taste and serve.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 71 — Duck ragu with pappardelle & swede

- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Turn the heat up, then pour in the red wine and cook for 2 mins until it has reduced a little. Spoon in the tomato purée and tip in the can of tomatoes along with the stock, stir and bring to the boil, then turn the heat down to low and return the duck breasts to the pan, cover and simmer very gently for 40-45 mins or until the meat is tender.”
  - Problem: “duck” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Remove the duck breasts with a slotted spoon, put in a bowl, turn the heat up and reduce the tomato sauce for 10 mins until thick enough to coat your pasta. Use two forks to shred the duck, then tip the meat back into the sauce. Add the red wine vinegar and raisins, then season to taste. Set aside.”
  - Problem: “duck” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 75 — Fresh salmon niçoise

- **Step 6** — `timeOnlyCooking` — rule `raw-eggs-firm`
  - Step text: “Boil the potatoes in the base of a steamer for 10 mins. Add the eggs (top up with boiling water from the kettle if they’re not submerged). Tip the green beans into a pan and put the steamer on top, then cook for 8 mins more.”
  - Problem: “eggs” is cooked for a stated time with no thermometer check — time alone never establishes doneness — US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety: “Cook eggs until both the yolk and the white are firm. Scrambled eggs should not be runny.” (<https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)
- **Step 7** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Remove the potatoes and eggs from the steamer, but don’t drain. Add the salmon to the water and cook for 5 mins. Stir the warm potatoes into the dressing.”
  - Problem: “salmon” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 77 — Ginger chicken udon noodles

- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a large, deep frying pan over a medium-high heat and, once hot, stir-fry the chicken and cabbage for 5-7 mins until browned and almost cooked through. Add the ginger and chilli, and cook for a few minutes more until fragrant.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 8** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Add the remaining ingredients, except the coriander and pickled ginger, and fry until the chicken is cooked and the noodles are tender, about 1-2 mins more. Season, adding more soy, vinegar or mirin, if you like. Top with the coriander and pickled ginger, if using.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 78 — Green goddess avocado salad

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “If using raw chicken, heat the oil in a frying pan over a medium-high heat. Season the chicken all over and fry for 7-8 mins each side, covering with a lid for the final 5 mins until cooked through. Set aside to rest for 10 mins, then slice.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 80 — Halloumi pasta

- **Step 6** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Drain the pasta and toss in the sauce along with the parsley, halloumi and baby plum tomatoes. Serve half straightaway, then leave the remainder for another day. Will keep covered and chilled for up to three days. Reheat in a pan with a dash of water over a medium heat until piping hot.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 81 — Healthy bolognese

- **Step 6** — `timeOnlyCooking` — rule `whole-cut-pork-145-rest-3`
  - Step text: “Tip in the pork and stir-fry until it changes colour, breaking it up as you go so there are no large clumps. Add the tomatoes, vinegar and bouillon, then cover the pan and cook for 10 mins over a low heat until the tomatoes burst and the pork is cooked and tender. Add the linguine and basil and plenty of pepper, and toss well before serving.”
  - Problem: “pork” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the cut, away from bone, fat or gristle reads 63 °C (145 °F), then rest 3 minutes — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 82 — Healthy chicken burritos

- **Step 6** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Meanwhile, in a dry frying pan, toast the spices gently over a low heat for 2-3 mins until fragrant, then tip in the beans, along with their liquid, the sweetcorn, tomato purée and garlic. Mix well and turn the heat up to medium so the mixture bubbles, then stir in the rice, chicken and coriander. Cook for 3-4 mins until piping hot. Will keep chilled for up to a day. Leave to cool completely first. Reheat in a pan or the microwave until piping hot.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 84 — Healthy chicken pasta bake

- **Step 10** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Mix the ricotta in a bowl with 5 tbsp of the pasta water and spread across the top of the pasta. Sprinkle over the cheddar, then bake for 35 mins. Scatter with a few extra basil leaves, if you like, and serve.”
  - Problem: “bake” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 85 — Healthy gnocchi

- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Add the gnocchi, cover and cook for another 2-3 mins, then uncover and stir in the crème fraîche. Simmer for another 5 mins, adding a splash of boiling water if needed, until the gnocchi is cooked through. Serve in bowls sprinkled with the parmesan, fresh parsley and a little black pepper to finish.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 86 — Healthy tikka masala

- **Step 5** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Heat 1 tbsp of the oil in a flameproof casserole dish over a medium heat. Add the onion mixture and fry for 15 mins. Tip into a bowl and wipe out the pan.”
  - Problem: “casserole” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Add the remaining oil and the chicken and fry for 5-7 mins, or until lightly brown. Stir in the tikka spice and cayenne and fry for a further minute. Tip the onion mixture back into the pan, along with the tomatoes and 1 can full of water. Bring to the boil, then reduce to a simmer and cook, uncovered, for 15 mins. Stir in the almonds and spinach and cook for a further 10 mins. Season, then stir though the yogurt and coriander. Serve with brown rice.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 87 — Hummus flatbread pizzas with roasted veg

- **Step 4** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat a large non-stick dry frying pan over a low heat. Knead one of the dough halves briefly on a well-floured work surface until it’s smooth and elastic, then roll out into a roughly 17cm circle. Put the flatbread in the pan and cook for 3 mins, then flip and cook for 3 mins more until cooked through. Transfer to a serving plate. Repeat with the second dough half.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 88 — Indian chickpeas with poached eggs

- **Step 8** — `timeOnlyCooking` — rule `raw-eggs-firm`
  - Step text: “Once the water is at a rolling boil, crack in your eggs and poach for 2 mins, then remove with a slotted spoon. Stir the spring onion tops into the chickpeas, then very lightly crush a few of the chickpeas with a fork or potato masher. Spoon the chickpea mixture onto plates, scatter with the reserved coriander and top with the eggs. Serve with an extra sprinkle of cumin, if you like.”
  - Problem: “eggs” is cooked for a stated time with no thermometer check — time alone never establishes doneness — US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety: “Cook eggs until both the yolk and the white are firm. Scrambled eggs should not be runny.” (<https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)

### 91 — Jerk chicken burger

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat a griddle pan until hot and cook the chicken for 4-5 mins each side or until cooked through. Remove from the heat. Meanwhile, toast the cut sides of the buns for 1-2 mins.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat a griddle pan until hot and cook the chicken for 4-5 mins each side or until cooked through. Remove from the heat. Meanwhile, toast the cut sides of the buns for 1-2 mins.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 92 — Jerk-style cauliflower with coconut rice

- **Step 4** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Meanwhile, put the rice in a large pan with 450ml water, the bouillon and thyme. Bring to the boil, cover and cook for 10 mins, then add the peppers and spring onions, cover again and simmer for 10-15 mins more until the rice is tender. Check towards the end that the water hasn’t run dry as you may need to add a splash more. Add the beans and yogurt and warm through. If you're following the Healthy Diet Plan, serve half the cauliflower and rice, then chill the rest for another day. Will keep for up to two days in the fridge.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 94 — Masala frittata with avocado salsa

- **Step 2** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a medium non-stick, ovenproof frying pan. Tip in the sliced onions and cook over a medium heat for about 10 mins until soft and golden. Add the Madras paste and fry for 1 min more, then tip in half the tomatoes and half the chilli. Cook until the mixture is thick and the tomatoes have all burst.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 3** — `timeOnlyCooking` — rule `raw-eggs-firm`
  - Step text: “Heat the grill to high. Add half the coriander to the eggs and season, then pour over the spicy onion mixture. Stir gently once or twice, then cook over a low heat for 8-10 mins until almost set. Transfer to the grill for 3-5 mins until set.”
  - Problem: “eggs” is cooked for a stated time with no thermometer check — time alone never establishes doneness — US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety: “Cook eggs until both the yolk and the white are firm. Scrambled eggs should not be runny.” (<https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)

### 96 — Mexican chicken stew with quinoa & beans

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a deep frying pan and fry the onions and peppers for a few mins until softened. Stir in the chipotle paste for a minute, followed by the tomatoes. Add up to a tomato can-full of water to cover the chicken and bring to a gentle simmer. Add the chicken breasts and gently simmer, turning the chicken occasionally, for 20 mins until the chicken is cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the oil in a deep frying pan and fry the onions and peppers for a few mins until softened. Stir in the chipotle paste for a minute, followed by the tomatoes. Add up to a tomato can-full of water to cover the chicken and bring to a gentle simmer. Add the chicken breasts and gently simmer, turning the chicken occasionally, for 20 mins until the chicken is cooked through.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 100 — Moroccan chicken

- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Bring to a simmer, then cook for 30 mins until the chicken is cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 7** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Bring to a simmer, then cook for 30 mins until the chicken is cooked through.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 101 — Moroccan chicken stew

- **Step 9** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “In a large, dry pan, gently toast the almonds for 2 mins until golden – don’t take your eyes off them, as they burn easily – then set aside.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 11** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Add the chicken thighs, skin-side down, and cook until the skin is golden and crisp, then turn and cook to lightly golden on the flesh side.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 12** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Add the red peppers, lemon slices, olives, stock or bone broth and dates or apricots (and chilli, if using). Simmer with the lid on for about 40 mins until the chicken is cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 105 — Nutty chicken satay strips

- **Step 3** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Add 2 skinless chicken breast fillets, cut into strips, and mix well. Arrange on the baking sheet, spaced apart, and bake in the oven for 8-10 mins until cooked, but still juicy.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 106 — One-pan beef stew with vegetable mash

- **Step 7** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “You can eat half the stew and mash now, then chill the rest to reheat and eat another day. Will keep chilled for a few days. Reheat the stew in a pan until piping hot. The mash can be reheated in the microwave. Serve with broccoli or peas, if you like.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 107 — One-pot garlicky chicken thighs & giant cous cous

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Season the chicken, then put skin-side down in a wide, ovenproof frying pan, roughly 30cm wide. Turn it up to a medium-low heat, then cook for 8-10 mins until the skin is golden.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Season the chicken, then put skin-side down in a wide, ovenproof frying pan, roughly 30cm wide. Turn it up to a medium-low heat, then cook for 8-10 mins until the skin is golden.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 8** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Pour in 675ml cold water, stirring well. Season, bring to the boil, then reduce to a simmer and nestle the chicken thighs back in, skin-side up. Put in the oven for 18-20 mins.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 108 — One-pot goulash pasta

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a large lidded pan over a medium heat and fry the onions for 10 mins, stirring frequently until golden. Add the mince, breaking apart any lumps with a wooden spoon. Stir in the peppers and cook for 5 mins.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `ground-meat-160`
  - Step text: “Heat the oil in a large lidded pan over a medium heat and fry the onions for 10 mins, stirring frequently until golden. Add the mince, breaking apart any lumps with a wooden spoon. Stir in the peppers and cook for 5 mins.”
  - Problem: “mince” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the patty or the thickest part of the ground-meat portion reads 71 °C (160 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Add the garlic, thyme and paprika, and stir well. Tip in the tomatoes, tomato purée and stock, and bring to the boil. Reduce the heat and simmer, covered, for 10 mins. Tip in the penne, put the lid back on and bring back to the boil. Reduce the heat again and simmer for another 12 mins until the penne is tender. Leave to stand for 5 mins, then divide half the pasta between two plates and serve. Leave the remainder to cool, then keep chilled for up to four days. Reheat in a pan over a low heat with a splash of water until piping hot. Try our Healthy Diet Plan, packed with 7 days of nourishing breakfasts, lunches and dinners – available exclusively within the Good Food app.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 115 — Pomegranate chicken with almond couscous

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Push the onion to one side of the pan, add the chicken fillets and brown on all sides. Stir in the tagine paste or harissa and the pomegranate juice, then crumble in the rest of the stock cube and season well. Simmer, uncovered, for 10 mins until the sauce has thickened and the chicken is cooked through. Stir through the pomegranate seeds, saving a few to scatter over before serving.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 6** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “After 5 mins, fluff up the couscous with a fork and stir through the almonds and mint. Serve the chicken on the couscous with the sauce spooned over.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 116 — Prawn & salmon burgers with spicy mayo

- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the remaining oil in a large frying pan and fry the burgers for 3-4 mins each side or until they have a nice crust and the fish is cooked through. Serve with the salad on the side or in toasted burger buns, if you like, with a good dollop of the spicy mayo.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the centre of the patty or the thickest part of the ground-meat portion reaches 71 °C (160 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 7** — `timeOnlyCooking` — rule `ground-meat-160`
  - Step text: “Heat the remaining oil in a large frying pan and fry the burgers for 3-4 mins each side or until they have a nice crust and the fish is cooked through. Serve with the salad on the side or in toasted burger buns, if you like, with a good dollop of the spicy mayo.”
  - Problem: “burger” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the patty or the thickest part of the ground-meat portion reads 71 °C (160 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 117 — Pulled chicken & black bean chilli

- **Step 4** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the oil in a shallow saucepan or casserole dish with a lid. Tip in the onions and cook over a medium-low heat for 5 mins until softened. Add the chicken and turn up the heat to medium. Stir in the garlic, a small pinch of sugar, the oregano, cumin seeds and some seasoning. Cook for a couple of minutes, then add the chipotle and cook for a few minutes more. Pour in the passata, 100ml water and add the stock. Season and bring to a simmer.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 5** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Cover with a lid and cook for 40-50 mins, stirring occasionally until the chicken is tender. Shred the chicken into the sauce using two forks, then stir through the beans. Simmer for 5 mins more, then turn off the heat. Squeeze in the lime juice. Can be kept chilled for three days and frozen for up to two months. Defrost thoroughly and reheat. Serve with rice or tortilla wraps, and some coriander, feta, lime wedges and red onion on the side, if you like.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 120 — Salmon salad with sesame dressing

- **Step 7** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Steam the potatoes and beans in a steamer basket set over a pan of boiling water for 8 mins. Arrange the salmon fillets on top and steam for a further 6-8 mins, or until the salmon flakes easily when tested with a fork.”
  - Problem: “salmon” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 121 — Sardine tomato pasta with gremolata

- **Step 4** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Cook the pasta following pack instructions in a large pan of boiling salted water. Heat 1 tbsp oil from the can of sardines in a non-stick frying pan over a medium heat and sizzle the capers and half the garlic for 1-2 mins until fragrant. Tip in the tomatoes and fry for 4-5 mins more until softened and bursting. Stir in the sardines and rocket, tossing a few times to break up the fish and wilt the leaves. Season.”
  - Problem: “fish” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 124 — Sea bass with sizzled ginger, chilli & spring onions

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Once hot, fry the sea bass fillets, skin-side down, for 5 mins or until the skin is very crisp and golden. The fish will be almost cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Once hot, fry the sea bass fillets, skin-side down, for 5 mins or until the skin is very crisp and golden. The fish will be almost cooked through.”
  - Problem: “bass” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Turn over, cook for another 30 seconds - 1 minute, then transfer to a serving plate and keep warm. You’ll need to fry the sea bass fillets in 2 batches.”
  - Problem: “bass” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat 2 tbsp sunflower oil, then fry the large knob of peeled ginger, cut into matchsticks, 3 thinly sliced garlic cloves and 3 thinly shredded red chillies for about 2 mins until golden.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 125 — Sesame chicken salad

- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Put the chicken in a pan and pour over cold water to cover. Tip the soya beans into a steamer. Bring the pan to a gentle simmer, then cook the chicken for 8 mins with the beans above.”
  - Problem: “chicken” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 127 — Quick and easy fish stew

- **Step 7** — `timeOnlyCooking` — rule `flesh-shellfish-145`
  - Step text: “Add the fish, scatter over the prawns and cook for 2 mins more until lightly cooked. Ladle into bowls and serve with a spoon.”
  - Problem: “prawns” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the thickest piece reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 130 — Smoky tomato, chipotle & charred corn soup

- **Step 5** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Heat the oil in a casserole dish and fry the onion for 10 mins until beginning to soften. Add the garlic, ground coriander and coriander stalks, and cook for 1 min. Stir though the tomatoes, stock and chipotle and bring to a simmer. Cook, covered, over a low heat for 20 mins, stirring occasionally.”
  - Problem: “casserole” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 134 — Soy-baked potatoes with tuna sriracha mayo

- **Step 4** — `timeOnlyCooking` — rule `leftovers-reheat-165`
  - Step text: “Prick the potatoes all over using a fork, then microwave on high for 10-15 mins, or until softened. Heat the oven to 200C/180C fan/gas 6, or turn on the air-fryer.”
  - Problem: “microwave” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in several places (microwave: cover, rotate and check more than one spot, then allow a resting time before the final check) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “When the potatoes are tender, score them lightly with a sharp knife, then pour over the soy sauce and toss quickly to coat. Bake in the oven for 15-20 mins or the air-fryer at 200C for 5 mins to crisp up the skins. Meanwhile, combine the dressing ingredients with the remaining lemon juice and drizzle this over the spinach. Split the potatoes in half, fill with the tuna mayo and serve with the spinach.”
  - Problem: “tuna” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 139 — Spicy harissa bean stew

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a large flameproof casserole dish over a medium heat and cook the red onions and peppers for 15 mins until starting to soften and turning golden at the edges. Add the tomatoes, turn the heat up to medium-high and cook until they blister, about 2-3 mins.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 5** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Heat the oil in a large flameproof casserole dish over a medium heat and cook the red onions and peppers for 15 mins until starting to soften and turning golden at the edges. Add the tomatoes, turn the heat up to medium-high and cook until they blister, about 2-3 mins.”
  - Problem: “casserole” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 140 — Spicy root & lentil casserole

- **Step 6** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a large pan and cook the onion and garlic over a medium heat for 3-4 minutes until softened, stirring occasionally. Tip in the potatoes, carrots and parsnips, turn up the heat and cook for 6-7 minutes, stirring, until the vegetables are golden.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 147 — Sticky miso aubergine traybake

- **Step 4** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Heat the grill to its highest setting and slide the aubergines under for 5 mins until bubbling (watch closely so the parchment doesn’t catch). Warm the rice following pack instructions, then top with the aubergines, sesame seeds and spring onions.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 149 — Superhealthy salmon burgers

- **Step 2** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Tip the salmon into a food processor with the paste, ginger, soy and chopped coriander. Pulse until roughly minced. Tip out the mix and shape into 4 burgers. Heat the oil in a non-stick frying pan, then fry the burgers for 4-5 mins on each side, turning until crisp and cooked through.”
  - Problem: “cooked through” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the thickest part of the fillet or the centre of the portion reaches 63 °C (145 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 2** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Tip the salmon into a food processor with the paste, ginger, soy and chopped coriander. Pulse until roughly minced. Tip out the mix and shape into 4 burgers. Heat the oil in a non-stick frying pan, then fry the burgers for 4-5 mins on each side, turning until crisp and cooked through.”
  - Problem: “salmon” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 154 — Tomato, pepper & bean one pot

- **Step 3** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a large pan or casserole on a medium heat. Fry the onion, celery and carrots for 10 mins until soft and golden, then add the peppers and fry for another 5 mins.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 3** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Heat the oil in a large pan or casserole on a medium heat. Fry the onion, celery and carrots for 10 mins until soft and golden, then add the peppers and fry for another 5 mins.”
  - Problem: “casserole” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 155 — Tomato soup & hummus crispbreads

- **Step 8** — `reheatingWithoutThermometer` — rule `leftovers-reheat-165`
  - Step text: “Pour in the passata and stock, bring to the boil, then cover and simmer over a medium heat for 30 mins, stirring occasionally until the vegetables are tender. Remove from the heat and whizz until smooth using a hand blender. Eat half now and chill the rest. Will keep chilled for up to three days. To reheat, cook portions in a pan over a low heat with a dash of water until piping hot.”
  - Problem: reheating without a thermometer check — leftovers must reach 74 °C (165 °F) — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer reads 74 °C (165 °F), checking in several places; sauces, soups and gravies to a rolling boil. (Source: USDA FSIS — Safe Minimum Internal Temperature Chart / Leftovers and Food Safety, retrieved 2026-10-11)

### 156 — Tomato & thyme cod

- **Step 3** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Simmer 5 mins, then slip 4 cod fillets into the sauce.”
  - Problem: “cod” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 4** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Cover and gently cook for 8-10 mins until the cod flakes easily. Serve with baked or steamed potatoes.”
  - Problem: “cod” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 158 — Tuna, caper & chilli spaghetti

- **Step 5** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Heat the oil in a wide frying pan over a very low heat, and gently cook the garlic and chilli to infuse the oil. Remove from the heat if the garlic is turning past light golden, as this will make it bitter.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the innermost part of the thigh and wing and the thickest part of the breast reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")

### 159 — The ultimate makeover: Chicken pie

- **Step 7** — `appearanceDoneness` — rule `thermometer-only-reliable`
  - Step text: “Cut each sheet of filo into 4 squares or rectangles. Layer them on top of the filling, brushing each sheet with some of the oil as you go. Lightly scrunch up the filo so it doesn’t lie completely flat and tuck the edges into the sides of the dish, or lay them on the edges if the dish has a rim. Grind over a little pepper, place the dish on a baking sheet, then bake for 20-25 mins until the pastry is golden and the sauce is bubbling. Serve immediately.”
  - Problem: “golden” states doneness by appearance — appearance never establishes safety or doneness — USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety: “Appearance and color are not reliable indicators of safety or doneness. Studies have shown that using a food thermometer is the only way to tell if harmful bacteria have been destroyed, yet only about 15% of people consistently use a food thermometer.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety>)
  - Proposed safe rewrite: Cook until the centre of the dish (check more than one place in a large or irregularly shaped dish) reaches 74 °C (165 °F) on a food thermometer — check at the timer rather than judging appearance. (Source: USDA Food Safety and Inspection Service (FSIS) — Doneness Versus Safety, https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/doneness-versus-safety, retrieved 2026-10-11: "Appearance and color are not reliable indicators of safety or doneness.")
- **Step 7** — `timeOnlyCooking` — rule `casseroles-165`
  - Step text: “Cut each sheet of filo into 4 squares or rectangles. Layer them on top of the filling, brushing each sheet with some of the oil as you go. Lightly scrunch up the filo so it doesn’t lie completely flat and tuck the edges into the sides of the dish, or lay them on the edges if the dish has a rim. Grind over a little pepper, place the dish on a baking sheet, then bake for 20-25 mins until the pastry is golden and the sauce is bubbling. Serve immediately.”
  - Problem: “bake” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Reheat until a food thermometer in the centre of the dish (check more than one place in a large or irregularly shaped dish) reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 162 — Vegetarian ramen

- **Step 3** — `timeOnlyCooking` — rule `raw-eggs-firm`
  - Step text: “Meanwhile, simmer the egg for 6 mins from boiling, run it under cold water to stop it cooking, then peel it. Toast the sesame seeds in a frying pan.”
  - Problem: “egg” is cooked for a stated time with no thermometer check — time alone never establishes doneness — US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety: “Cook eggs until both the yolk and the white are firm. Scrambled eggs should not be runny.” (<https://www.fda.gov/food/buy-store-serve-safe-food/what-you-need-know-about-egg-safety>)
  - Proposed safe rewrite: Cook until a food thermometer in the centre of the egg dish or the yolk reads 71 °C (160 °F) — the timer only tells you when to check. (Source: US Food and Drug Administration (FDA) — What You Need to Know About Egg Safety, retrieved 2026-10-11)

### 164 — Venetian duck ragu

- **Step 5** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Heat the oil in a large pan. Add the duck legs and brown on all sides for about 10 mins. Remove to a plate and set aside. Add the onions to the pan and cook for 5 mins until softened. Add the garlic and cook for a further 1 min, then stir in the cinnamon and flour and cook for a further min. Return the duck to the pan, add the wine, tomatoes, stock, herbs, sugar and seasoning. Bring to a simmer, then lower the heat, cover with a lid and cook for 2 hrs, stirring every now and then.”
  - Problem: “duck” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)
- **Step 6** — `timeOnlyCooking` — rule `poultry-all-cuts-165`
  - Step text: “Carefully lift the duck legs out of the sauce and place on a plate – they will be very tender so try not to lose any of the meat. Pull off and discard the fat, then shred the meat with 2 forks and discard the bones. Add the meat back to the sauce with the milk and simmer, uncovered, for a further 10-15 mins while you cook the pasta.”
  - Problem: “duck” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the innermost part of the thigh and wing and the thickest part of the breast reads 74 °C (165 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

### 166 — Zesty haddock with crushed potatoes & peas

- **Step 4** — `timeOnlyCooking` — rule `flesh-fish-145`
  - Step text: “Dust the fish in the flour, tapping off any excess and season. Heat remaining oil in a non-stick frying pan. Fry the fish for 2-3 mins on each side until cooked, then add the dressing and warm through. Serve with the crush and broccoli.”
  - Problem: “fish” is cooked for a stated time with no thermometer check — time alone never establishes doneness — USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart: “Cook all food to these minimum internal temperatures, as measured with a food thermometer, before removing food from the heat source. For reasons of personal preference, consumers may choose to cook food to higher temperatures.” (<https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/food-safety-basics/safe-temperature-chart/>)
  - Proposed safe rewrite: Cook until a food thermometer in the thickest part of the fillet or the centre of the portion reads 63 °C (145 °F) — the timer only tells you when to check. (Source: USDA Food Safety and Inspection Service (FSIS) — Safe Minimum Internal Temperature Chart, retrieved 2026-10-11)

## Regeneration

```sh
swift build -c release --package-path packages/FLFoodSafety
packages/FLFoodSafety/.build/release/flfoodsafety-audit --repo-root . > data/food-safety/BUNDLED-RECIPE-AUDIT.md
```

