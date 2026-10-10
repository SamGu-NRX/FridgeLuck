# Conversion checks: held-out recovery and 100-meal yield

Both checks run the shipped `MassConversionKit` matcher over the
pinned FNDDS table. Unknown conversions are never fabricated into a
number, so yield is a coverage metric.

## Held-out recovery (every 10th entry withheld, deterministic)

- Withheld entries: 729
- Recovered by the matcher: 711 (9 exact, 702 partial)
- Unknown (no entry matched): 18
- Median rel. error: 0.0% (mean 32.7%)
- Within ±25%: 563 · within ±50%: 650

Worst matched-elsewhere recoveries:

| Food | Unit | Withheld g | Matched g | Rel. error |
|---|---|---|---|---|
| Cereal, O's, plain | piece | 0.1 | 8 | 7900.0% |
| Quail egg, canned | egg | 9 | 145 | 1511.1% |
| Candy, cotton | cup | 10 | 160 | 1500.0% |
| Potato chips, popped, NFS | cup | 20 | 160 | 700.0% |
| Candy, fruit snacks | piece | 2 | 10 | 400.0% |

## 100-meal conversion yield (100 meals × 3 ingredients)

- Ingredients: 300
- Converted with evidence: 300 (98 exact, 202 partial) — 100.0% yield
- Unknown: 0
- Fully converted meals: 100/100 — 100.0% meal yield

Meal queries are intake-style (first three words of the FNDDS
description). Because those words are a token prefix of the source
description, they always overlap it — so this check validates the
end-to-end conversion path (unit choice, lookup, evidence levels)
over census-derived meals, not name-resolution difficulty. The
held-out check above covers resolution error; real-world coverage
of partial user input is not measured here.
