# Cooking-yield sensitivity (source-bound raw/cooked pairs)

Protocol: raw-to-cooked survey-food pairs: same WWEIA category, same normalized description stem (state words removed), shared canonical household unit with differing per-unit grams; ratio = cooked grams per unit / raw grams per unit; per-unit nutrients from SurveyFoods per-100g anchors (208 kcal, 203 protein, 204 fat, 205 carbohydrate) of each side.

- Pairs: 22 across 9 WWEIA categories
- Ratio spread (cooked g/unit ÷ raw g/unit): 0.600 – 1.736 (median) – 4.250
- Per-unit kcal delta (cooked − raw): -27.0 – +61.5 (median) – +159.3
- Missing inputs (explicit, never filled): 7 — {'no shared unit with differing grams': 7}

The ratio is a mass-yield factor observed between two survey foods
of the same stem, not a universal cooking rule: it conflates water
loss/gain with per-100g density changes, and per-unit macro deltas
show the combined effect of both (per-unit grams × per-100g
nutrients). Nothing in MassConversionKit applies a yield factor;
this arm quantifies how much per-unit energy and macros move
between raw and cooked forms of the same food stem.

This arm is NOT the 100-meal check: converting generated three-food
bundles is conversion-path plumbing (`conversion_checks.md`), not a
yield study.

| Category | Raw food | g/unit | Cooked food | g/unit | Ratio | Δ kcal/unit | Δ protein g/unit | Δ fat g/unit | Δ carb g/unit |
|---|---|---|---|---|---|---|---|---|---|
| Apples | Apple, raw | 125 | Apple, baked | 190 | 1.520 | +138.4 | +0.4 | +5.7 | +24.6 |
| Bananas | Banana, raw | 225 | Banana, baked | 140 | 0.622 | +7.2 | -0.5 | +3.9 | -5.7 |
| Broccoli | Broccoli raab, raw | 40 | Broccoli raab, cooked | 170 | 4.250 | +69.4 | +4.2 | +5.2 | +3.8 |
| Broccoli | Broccoli, chinese, raw | 36 | Broccoli, Chinese, cooked | 88 | 2.444 | +34.6 | +0.6 | +2.7 | +2.5 |
| Cabbage | Cabbage, red, raw | 90 | Cabbage, red, cooked | 155 | 1.722 | +59.3 | +0.8 | +4.2 | +4.5 |
| Lettuce and lettuce salads | Lettuce, raw | 35 | Lettuce, cooked | 86 | 2.457 | +35.1 | +0.6 | +2.6 | +2.3 |
| Onions | Onions, green, raw | 100 | Onions, green, cooked | 225 | 2.250 | +109.8 | +2.9 | +7.0 | +11.5 |
| Other dark green vegetables | Beet greens, raw | 38 | Beet greens, cooked | 150 | 3.947 | +63.6 | +2.6 | +4.3 | +5.1 |
| Other dark green vegetables | Chard, raw | 36 | Chard, cooked | 150 | 4.167 | +59.2 | +2.2 | +4.4 | +4.5 |
| Other dark green vegetables | Cress, raw | 50 | Cress, cooked | 140 | 2.800 | +65.2 | +2.5 | +4.5 | +5.3 |
| Other dark green vegetables | Dandelion greens, raw | 55 | Dandelion greens, cooked | 110 | 2.000 | +53.4 | +1.6 | +3.4 | +5.5 |
| Other dark green vegetables | Watercress, raw | 34 | Watercress, cooked | 142 | 4.176 | +47.4 | +2.6 | +4.0 | +1.5 |
| Other vegetables and combinations | Bean sprouts, raw | 90 | Bean sprouts, cooked | 115 | 1.278 | +106.4 | +8.5 | +7.8 | +1.6 |
| Other vegetables and combinations | Broccoflower, raw | 64 | Broccoflower, cooked | 90 | 1.406 | +29.7 | +0.8 | +2.5 | +1.6 |
| Other vegetables and combinations | Celery, raw | 120 | Celery, cooked | 155 | 1.292 | +44.7 | +0.2 | +4.3 | +1.4 |
| Other vegetables and combinations | Cucumber, raw | 120 | Cucumber, cooked | 185 | 1.542 | +64.0 | +0.6 | +5.7 | +2.7 |
| Other vegetables and combinations | Kohlrabi, raw | 135 | Kohlrabi, cooked | 170 | 1.259 | +50.2 | +0.6 | +4.5 | +2.3 |
| Other vegetables and combinations | Rutabaga, raw | 140 | Rutabaga, cooked | 245 | 1.750 | +102.5 | +1.3 | +6.9 | +9.9 |
| Other vegetables and combinations | Turnip, raw | 130 | Turnip, cooked | 235 | 1.808 | +90.5 | +1.1 | +6.5 | +7.4 |
| Shellfish | Clams, raw | 225 | Clams, fried | 135 | 0.600 | +117.0 | -15.4 | +15.3 | +11.4 |
| Shellfish | Oysters, raw | 225 | Oysters, steamed | 135 | 0.600 | -27.0 | -3.1 | -0.9 | -1.5 |
| Shellfish | Oysters, raw | 225 | Oysters, fried | 135 | 0.600 | +159.3 | -4.4 | +14.4 | +12.5 |

## Missing inputs (explicit)

| Category | Raw food | Cooked food | Unit | Reason |
|---|---|---|---|---|
| Fish | Fish, salmon, raw | Fish, salmon, grilled | — | no shared unit with differing grams |
| Fish | Fish, salmon, raw | Fish, salmon, fried | — | no shared unit with differing grams |
| Fish | Fish, salmon, raw | Fish, salmon, steamed | — | no shared unit with differing grams |
| Fish | Fish, tuna, raw | Fish, tuna, cooked | — | no shared unit with differing grams |
| Mustard and other condiments | Garlic, raw | Garlic, cooked | — | no shared unit with differing grams |
| Mustard and other condiments | Peppers, hot, raw | Peppers, hot, cooked | — | no shared unit with differing grams |
| Other vegetables and combinations | Fennel bulb, raw | Fennel bulb, cooked | — | no shared unit with differing grams |