# pantry-2026-10 — pantry-first originals packet

30 original lunch/dinner recipes (RS v1), each anchored to at least one of
the ten written household pantries in `evaluation/catalog-reach/pantries-v2.json`,
with every pantry gaining at least two exactly-cookable dishes.

## Layout

- `src/recipes_pantry.py` — recipe sources (DSL: region, title, slots, minutes,
  servings, ingredients, steps, keywords). No breakfast slots: the
  breakfast-2026-10 packet owns that slot.
- `src/build_corpus.py` — deterministic builder → `originals.jsonl`
  (RS v1 + conversions + provenance), reusing the world-2026-10 packet's
  pinned FNDDS registry, safety-line source, classification extension, and
  suite linter.
- `src/check_packet.py` — packet checker: reuses the world packet checker on
  adapted record copies (`fl-world-NNNN` ids, translated back on output) with
  the packet's own rights manifest, plus a pantry-signal gate (every dish is
  named by a pantry item, and its signature non-staple lines are stocked).
- `src/run_reach.py` — reach measurement: shipped bundle vs shipped + packet,
  via the repository's unchanged `reach_report_v2.analyze_bundle`. Recipe
  names map to bundle ingredient keys explicitly (`NAME_TO_KEY`); a missing
  mapping fails loud.
- `tests/test_pantry_packet_gates.py` — planted-failure tests for the
  checker gates (rights coverage and basis, pantry-signal anchoring and
  signature stocking, colour/time doneness lint, vegetarian floor) plus a
  green control and a name→key mapping coverage test.
- `evidence/originals-rights-manifest.json` — one original-rights entry per
  record.
- `evidence/reach-after.json` — per-pantry exact-cookable additions.

## Bridge reality (measured, not assumed)

The reach evaluator works on exact ingredient IDs resolved from the shipped
bundle. Several pantry-fixture items — olive oil, cheddar, soy sauce, curry
powder, peanut butter, turmeric, cinnamon, sugar, bananas, apples, pork chops,
cauliflower, among others — resolve to app ingredient IDs that never match the
bundle key a recipe line would carry, so they can never make a dish exactly
cookable for any written pantry. Every recipe here is anchored strictly on
verified bridges (rice, egg, garlic, pasta, milk, butter, onion, potato, corn,
chicken breast, spinach, chickpeas, cumin, quinoa, tofu, black beans,
broccoli, canned tuna, bread, yogurt, cilantro, ginger, salmon, lemon, oats,
zucchini, avocado), so frying uses butter or a dry nonstick pan and seasoning
relies on salt and black pepper. `run_reach.py` is the ground truth; the
pantry-signal gate in `check_packet.py` is a fast design guard, not the
measurement.

Measured result (`python3 src/run_reach.py`): exact-cookable counts per
pantry rise 2→8 (starter), 3→10 (family), 2→6 (vegan), 8→12 (gluten-free),
1→3 (student), 1→3 (baker), 5→13 (pescatarian), 2→4 (keto), 0→2
(south-asian), 0→2 (empty-nesters); median 2.0 → 5.0, and every pantry ends
with at least two exact dishes.

## Commands

```bash
python3 src/build_corpus.py        # rebuild originals.jsonl
python3 src/check_packet.py        # rights, quantities, lint, gates
python3 src/run_reach.py           # pantry reach measurement
python3 -m pytest tests -q         # planted-failure tests (packet)
python3 -m pytest -q               # from the repository root: full suite
```

`build_corpus.py` must be rerun (and the manifest regenerated) after any
change to `src/recipes_pantry.py`; `check_packet.py` and `run_reach.py` read
the built `originals.jsonl`, not the DSL.

## Rights

All 30 records are original to this packet (author Sam Gu, basis noted in the
manifest). No third-party recipe text, no diet claims in source records, and
every meat/poultry/fish/egg cooking step carries the FSIS thermometer check.
