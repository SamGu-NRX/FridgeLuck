# Shelf-life guidance — fridge, freezer, pantry

> **QUALITY GUIDANCE, NOT SAFETY CERTIFICATION.** These are food-quality windows from USDA's FoodKeeper data. They say when food is at its best, never that food *is* safe. Food can be unsafe before any date in this table; when in doubt, throw it out. Safety rules (cooling windows, reheating temperatures, storage limits) live in `rules.json` and always win over these quality windows.

Source: USDA Food Safety and Inspection Service, *FoodKeeper Data* (`foodkeeper.json`, data version 108, file dated Sep 7, 2018), <https://www.fsis.usda.gov/shared/data/EN/foodkeeper.json>, retrieved 2026-10-11. Where a row's value is a textual metric, it is quoted as the data states it.

## Coverage

All 50 core ingredients in `apps/ios/Resources/data.json` (`ingredients`). "Product" is the FoodKeeper row used, with its product ID. A dash means FoodKeeper gives no value for that storage method.

| Ingredient | FoodKeeper product | Pantry | Fridge | Freezer | Notes |
| --- | --- | --- | --- | --- | --- |
| apple | Apples · #248 | 3 weeks | 4–6 weeks | 8 months | Freezing guidance applies to cooked product.
| avocado | Avocados · #250 | When Ripe | 3–4 days | Not Recommended | Ripe is when this item is tender, fully developed and ready to eat.
| banana | Bananas · #251 | When Ripe | 3 days | 2–3 months | Ripe is when this item is tender, fully developed and ready to eat.
| bell pepper | Peppers · #296 | — | 4–14 days | 6–8 months |
| black beans | Beans (dried) · #333 | 1–2 years | — | — |
| bread | Bread (homemade) · #574 | 3–5 days | 2–3 months | — | May have shorter shelf life due to lack of preservatives.
| broccoli | Broccoli and broccoli raab (rapini) · #276 | — | 3–5 days | 10–12 months |
| butter | Butter · #1 | — | 1–2 months | 6–9 months | May be left at room temperature for 1 - 2 days.
| canned tuna | Tuna (canned) · #618 | 3 years | — | — |
| carrot | Carrots, parsnips · #279 | — | 2–3 weeks | 10–12 months |
| celery | Celery · #281 | — | 1–2 weeks | 10–12 months |
| cheese | Cheese (hard such as cheddar, swiss, block parmesan) · #3 | — | 6 months | 6 months |
| chicken breast | Stuffed, raw chicken breasts · #131 | — | 1–2 days | 9 months |
| chickpea | Beans (dried) · #333 | 1–2 years | — | — |
| cilantro | Herbs · #288 | — | 7–10 days | 1–2 months |
| coconut milk | Coconut milk (canned) · #602 | 2–5 years | — | 3 months |
| corn | Corn on the cob · #282 | — | 1–2 days | 8 months |
| cucumber | Cucumbers · #283 | — | 4–6 days | Not Recommended |
| cumin | Cumin (ground, dried, commercially bottled or purchased in bulk, opened or unopened) · #473 | 3–4 years | — | — |
| egg | Eggs (in shell) · #21 | — | 3–5 weeks | Not Recommended |
| frozen peas | Vegetables · #331 | — | 3–4 days | 10–18 months | Recommendation is for storage after cooking.
| garlic | Garlic · #285 | 1 month | 3–14 days | 1 month | Store unbroken bulbs in pantry.
| ginger | Ginger root · #286 | 2–5 days | 2–3 weeks | 6 months |
| green onion | Onions (spring or green) · #295 | 1 month | 1 week | 10–12 months |
| ground beef | Beef (ground) · #43 | — | 1–2 days | 3–4 months |
| honey | Honey · #345 | 2 years | — | — |
| lemon | Citrus fruit (lemon, lime, orange, grapefruit, tangerines, clementines) · #256 | 10 days | 10–21 days | Not Recommended |
| lettuce | Lettuce (iceberg, romaine) · #290 | — | 1–2 weeks | Not Recommended |
| lime | Citrus fruit (lemon, lime, orange, grapefruit, tangerines, clementines) · #256 | 10 days | 10–21 days | Not Recommended |
| milk | Milk (plain or flavored) · #27 | — | Package use-by date | 3 months |
| mushroom | Mushrooms · #292 | — | 3–7 days | 10–12 months |
| oats | Oats (whole grain) · #585 | 4 months | — | 8 months |
| olive oil | Oils (olive or vegetable) · #227 | 6–12 months | — | — |
| onion | Onions (yellow, white, red, etc.) · #294 | 1 month | 2 months | 10–12 months |
| pasta | Pasta (dry, without eggs) · #335 | 2 years | — | — |
| peanut butter | Peanut butter (commercial) · #387 | 6–24 months | 2–3 months | — |
| potato | Potatoes · #297 | 1–2 months | 1–2 weeks | 10–12 months | This is the recommended storage method for whole potatoes.
| red pepper flakes | Spice/spices (ground) · #238 | 2–3 years | — | — |
| rice | Rice (white or wild) · #338 | 2 years | — | — |
| salmon | Fatty fish (bluefish, catfish, mackerel, mullet, salmon, tuna, etc.) · #146 | — | 1–2 days | 2–3 months |
| sesame oil | Sesame oil · #612 | 2 years | — | — |
| sour cream | Sour cream · #29 | — | Package use-by date | Not Recommended |
| soy sauce | Soy sauce or teriyaki sauce · #360 | 3 years | — | — | Refrigeration ensures that commercial sauces and condiments stay fresh for a longer period of time.
| spinach | Lettuce (leaf, spinach) · #291 | — | 3–7 days | Not Recommended |
| sweet potato | Yams/sweet potatoes · #422 | 2–3 weeks | — | — |
| tofu | Tofu · #168 | — | 1 week | 5 months |
| tomato | Tomatoes · #306 | When Ripe | — | 2 months | Until Ripe, then 7 days. Ripe is when this item is tender, fully developed and ready to eat. Refrigeration may affect flavor; USDA recommends pantry storage.
| tortilla | Tortillas (flour) · #196 | 3 months | — | 6 months |
| yogurt | Yogurt · #33 | — | 1–2 weeks | 1–2 months |
| zucchini | Zucchini (fresh, whole) · #547 | — | 1 week | 10 months |

Catalog coverage beyond the core 50: FoodKeeper has 660 product rows covering the USDA ingredient catalog's common items; the app should resolve an ingredient to a FoodKeeper row (by name, then keywords) before falling back to the category row. This table pins the core 50 so the app's default guidance is reviewable; extending the pinned table to the full catalog is follow-up work, not a blocker.

## Comparison with the app's current guidance

The v9 migration (`apps/ios/Platform/Persistence/Database/Migrations.swift`) creates `ingredient_shelf_life_profiles` (fridge/pantry/freezer days) **with no seed data — zero bundled profiles** (verified by repo search this cycle: nothing writes the table at seed time). There are therefore no structured profiles to disagree with; the comparison below is against the 50 storage-hint strings bundled in `data.json`. Every core ingredient appears; "disagree" rows are the actionable list.

| Ingredient | App hint (data.json) | FoodKeeper (pantry / fridge / freezer) | Verdict |
| --- | --- | --- | --- |
| apple | Room temp 1 week, fridge 4-6 weeks | 3 weeks / 4–6 weeks / 8 months | agree — hint "Room temp 1 week, fridge 4-6 weeks" sits inside FoodKeeper's pantry 3 weeks / fridge 4–6 weeks. |
| avocado | Room temp until ripe, then fridge | When Ripe / 3–4 days / Not Recommended | agree — hint "Room temp until ripe, then fridge" matches FoodKeeper's pantry "When Ripe" then fridge 3–4 days. |
| banana | Room temp until ripe, then fridge | When Ripe / 3 days / 2–3 months | agree — hint matches FoodKeeper (pantry until ripe; fridge 3 days for ripe fruit). |
| bell pepper | Refrigerate in crisper drawer | — / 4–14 days / 6–8 months | agree — hint "Refrigerate in crisper drawer" is consistent with fridge 4–14 days (no time stated). |
| black beans | Canned: pantry 2 years | 1–2 years / — / — | **not sourced** — FoodKeeper has no canned-beans row; the closest row is dried Beans (pantry 1–2 years). The app's "Canned: pantry 2 years" is not covered by this dataset. |
| bread | Room temp 3-5 days, freeze for longer | 3–5 days / 2–3 months / — | partial — FoodKeeper row is homemade bread: pantry 3–5 days (hint agrees); FoodKeeper also lists fridge 2–3 months, though refrigeration stales bread — the app's "freeze for longer" is the better move and FoodKeeper gives no bread-freezer figure. |
| broccoli | Refrigerate, use within 5 days | — / 3–5 days / 10–12 months | agree — hint "use within 5 days" falls inside fridge 3–5 days at the boundary. |
| butter | Refrigerate or freeze | — / 1–2 months / 6–9 months | agree — hint "Refrigerate or freeze" matches fridge 1–2 months / freezer 6–9 months; FoodKeeper also allows 1–2 days at room temperature, which the hint does not mention. |
| canned tuna | Pantry 2-5 years | 3 years / — / — | **disagree** — hint "Pantry 2-5 years" vs FoodKeeper canned Tuna pantry 3 years. The app's upper bound (5 years) exceeds the sourced value. |
| carrot | Refrigerate in bag | — / 2–3 weeks / 10–12 months | agree — hint "Refrigerate in bag" is consistent with fridge 2–3 weeks (no time stated). |
| celery | Refrigerate in water | — / 1–2 weeks / 10–12 months | agree — hint "Refrigerate in water" — FoodKeeper fridge 1–2 weeks; the water-storage method keeps stems crisp and does not conflict. |
| cheese | Wrap tightly, refrigerate | — / 6 months / 6 months | agree — hint "Wrap tightly, refrigerate" — FoodKeeper hard cheese fridge 6 months; no conflict. |
| chicken breast | Use within 2 days or freeze | — / 1–2 days / 9 months | agree — hint "Use within 2 days or freeze" matches fridge 1–2 days / freezer 9 months. |
| chickpea | Canned: pantry 2 years | 1–2 years / — / — | **not sourced** — same as black beans — FoodKeeper has no canned-beans row; dried Beans pantry is 1–2 years. |
| cilantro | Refrigerate stems in water | — / 7–10 days / 1–2 months | agree — hint "Refrigerate stems in water" — FoodKeeper fresh herbs fridge 7–10 days; no time conflict. |
| coconut milk | Canned: pantry 2 years | 2–5 years / — / 3 months | partial — hint "Canned: pantry 2 years" vs FoodKeeper canned coconut milk pantry 2–5 years — the hint is more conservative (not unsafe); FoodKeeper adds freezer 3 months. |
| corn | Refrigerate, use within 3 days | — / 1–2 days / 8 months | **disagree** — hint "use within 3 days" vs FoodKeeper corn on the cob fridge 1–2 days. The app allows a day beyond the sourced window. |
| cucumber | Refrigerate, use within 1 week | — / 4–6 days / Not Recommended | agree — hint "use within 1 week" inside FoodKeeper fridge 4–6 days at the boundary (conservative). |
| cumin | Cool dark place | 3–4 years / — / — | agree — hint "Cool dark place" — FoodKeeper pantry 3–4 years. |
| egg | Refrigerate, use within 3 weeks | — / 3–5 weeks / Not Recommended | agree — hint "use within 3 weeks" sits inside FoodKeeper fridge 3–5 weeks (conservative). |
| frozen peas | Keep frozen until use | — / 3–4 days / 10–18 months | agree — hint "Keep frozen until use" matches freezer 10–18 months; FoodKeeper adds "cook as directed" for safety. |
| garlic | Store in cool, dry place | 1 month / 3–14 days / 1 month | partial — hint "Store in cool, dry place" matches pantry for unbroken bulbs (FoodKeeper: 1 month); FoodKeeper adds fridge 3–14 days, which the hint does not cover. |
| ginger | Refrigerate or freeze | 2–5 days / 2–3 weeks / 6 months | agree — hint "Refrigerate or freeze" matches fridge 2–3 weeks / freezer 6 months. |
| green onion | Refrigerate in glass of water | 1 month / 1 week / 10–12 months | agree — hint "Refrigerate in glass of water" — FoodKeeper green onions fridge 1 week; no conflict. |
| ground beef | Use within 2 days or freeze | — / 1–2 days / 3–4 months | agree — hint "Use within 2 days or freeze" matches fridge 1–2 days / freezer 3–4 months. |
| honey | Room temp, sealed | 2 years / — / — | agree — hint "Room temp, sealed" — FoodKeeper pantry 2 years. |
| lemon | Room temp 1 week, fridge 4 weeks | 10 days / 10–21 days / Not Recommended | **disagree** — hint "fridge 4 weeks" exceeds FoodKeeper's fridge 10–21 days (sourced maximum 21 days). |
| lettuce | Refrigerate, use within 1 week | — / 1–2 weeks / Not Recommended | agree — hint "use within 1 week" inside FoodKeeper fridge 1–2 weeks. |
| lime | Room temp 1 week, fridge 4 weeks | 10 days / 10–21 days / Not Recommended | **disagree** — same as lemon — the hint's fridge figure (4 weeks) exceeds the sourced 21-day maximum. |
| milk | Refrigerate, use by date | — / Package use-by date / 3 months | agree — hint "use by date" matches FoodKeeper's fridge "Package use-by date"; freezer 3 months not mentioned in the hint. |
| mushroom | Refrigerate in paper bag | — / 3–7 days / 10–12 months | agree — hint "Refrigerate in paper bag" — FoodKeeper fridge 3–7 days; no conflict. |
| oats | Cool dry place, sealed | 4 months / — / 8 months | agree — hint "Cool dry place, sealed" — FoodKeeper pantry 4 months / freezer 8 months. |
| olive oil | Cool dark place, sealed | 6–12 months / — / — | agree — hint "Cool dark place, sealed" — FoodKeeper pantry 6–12 months. |
| onion | Store in cool, dark place | 1 month / 2 months / 10–12 months | agree — hint "Store in cool, dark place" matches FoodKeeper pantry guidance for whole onions (1 month pantry / 2 months DOP). |
| pasta | Dry: cool, dark place | 2 years / — / — | agree — hint "Dry: cool, dark place" — FoodKeeper pantry 2 years. |
| peanut butter | Room temp, sealed | 6–24 months / 2–3 months / — | agree — hint "Room temp, sealed" — FoodKeeper commercial peanut butter pantry 6–24 months, 2–3 months after opening. |
| potato | Cool dark place, not fridge | 1–2 months / 1–2 weeks / 10–12 months | agree — hint "Cool dark place, not fridge" matches FoodKeeper (pantry 1–2 months; "recommended storage method for whole potatoes"). |
| red pepper flakes | Cool dark place | 2–3 years / — / — | agree — hint "Cool dark place" — FoodKeeper ground spices pantry 2–3 years. |
| rice | Store in airtight container | 2 years / — / — | agree — hint "airtight container" — FoodKeeper white/wild rice pantry 2 years. |
| salmon | Refrigerate 2 days, freeze longer | — / 1–2 days / 2–3 months | partial — hint "Refrigerate 2 days" — FoodKeeper fatty fish fridge is 1–2 days; the hint states only the upper bound and could read as a safe 2-day window without "or freeze". |
| sesame oil | Cool dark place | 2 years / — / — | agree — hint "Cool dark place" — FoodKeeper pantry 2 years. |
| sour cream | Refrigerate, check date | — / Package use-by date / Not Recommended | agree — hint "check date" matches FoodKeeper's "Package use-by date"; freezing not recommended. |
| soy sauce | Refrigerate after opening | 3 years / — / — | agree — hint "Refrigerate after opening" — FoodKeeper pantry 3 years sealed; refrigeration keeps it fresh longer. |
| spinach | Refrigerate, use within 5 days | — / 3–7 days / Not Recommended | agree — hint "use within 5 days" inside FoodKeeper leafy-greens fridge 3–7 days. |
| sweet potato | Cool dark place, not fridge | 2–3 weeks / — / — | partial — hint "Cool dark place, not fridge" — FoodKeeper pantry 2–3 weeks, no fridge row; the hint gives no window. |
| tofu | Refrigerate in water, change daily | — / 1 week / 5 months | agree — hint "Refrigerate in water, change daily" — FoodKeeper fridge 1 week / freezer 5 months; the water method is a usage convention, not a FoodKeeper conflict. |
| tomato | Store at room temperature | When Ripe / — / 2 months | agree — hint "Store at room temperature" matches FoodKeeper (pantry "When Ripe", then 7 days; "USDA recommends pantry storage"). |
| tortilla | Room temp 1 week, freeze longer | 3 months / — / 6 months | **disagree** — hint "Room temp 1 week" vs FoodKeeper flour tortillas pantry 3 months / freezer 6 months. The app is far more conservative than the sourced value. |
| yogurt | Refrigerate, check date | — / 1–2 weeks / 1–2 months | agree — hint "check date" — FoodKeeper fridge 1–2 weeks / freezer 1–2 months. |
| zucchini | Refrigerate, use within 5 days | — / 1 week / 10 months | agree — hint "use within 5 days" inside FoodKeeper fridge 1 week (conservative). |

**Summary:** 38 agree, 5 partial, 5 disagree (`canned tuna` pantry window wider than sourced, `corn` fridge window a day longer, `lemon`/`lime` fridge windows beyond the sourced 21-day maximum, `tortilla` room-temp window far shorter than sourced), and 2 app hints (`black beans`, `chickpea` canned) have no FoodKeeper counterpart at all. When the app seeds `ingredient_shelf_life_profiles`, seed from the FoodKeeper table above (freezer 0 = not recommended), re-run this comparison, and keep the quality-guidance disclaimer on every surface (see `COPY.md`, "Shelf-life copy").
