# Packing-evidence scan (why packing generalization is unmeasured)

Protocol: word-boundary scan of FNDDS portionDescription + modifier text over the full corpus.

- Corpus: 5432 survey foods, 22194 portions scanned, 8319 parse into canonical household units

## Raw term counts over the full corpus portion text

| Term | All portions | Parsed household rows |
|---|---|---|
| canned | 4 | 1 |
| can | 261 | 152 |
| jar | 54 | 0 |
| bag | 342 | 0 |
| bottle | 218 | 0 |
| box | 45 | 0 |
| pouch | 123 | 0 |
| package | 204 | 83 |
| pack | 2 | 1 |
| carton | 2 | 0 |
| tub | 53 | 0 |

Container words hit the corpus overwhelmingly as quantity units —
"1 can (5 oz) yields", "1 package (4.5 oz)" — which is the
portion's own unit, not a packing qualifier on the grams.

## Qualifier-level hits in parsed household rows

1 parsed row(s) would classify as
packing via qualifier text:

- fdcId 2706477 'Corned beef hash' — '1 cup, canned' → canned; survives into the conversion table: False (dedup keeps an earlier same-key row)

Conversion-table labels: 558 state, 0 packing.

## Conclusion

FNDDS attaches no packing evidence to household portions that survives into the pinned conversion table: container words appear as quantity units ('1 can', '1 package'), and qualifier-level hits are absent from the table after (food, unit, magnitude) dedup. The table carries 0 packing labels; packing matching in MassConversionKit is exercised only by synthetic unit tests, so packing generalization is UNMEASURED.

Packing matching is exercised only by synthetic unit tests
(`testCannedQueryPrefersCannedPacking` and friends); packing
generalization is unmeasured against real data.
