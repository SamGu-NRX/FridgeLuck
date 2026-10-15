# Validation — world-2026-10 originals packet

Every command below was run in this packet directory. Recorded outputs are
verbatim from the final verification pass on 2026-10-15.

## Environment

- Repo checkout: `SamGu-NRX/FridgeLuck`, branch
  `obv/burst5-fridgeluck-rcp-originals-world`, based on
  `obv/burst5-fridgeluck-spec-recipes`.
- Pinned recipes suite at `/tmp/fl-suite/evaluation/suites/recipes`
  (`rs.py`, `bands.py`, `allergens.json`, pinned `canon/rules.json`
  snapshot — `overhaul/food-safety-canon @ 2e03467d`).
- Pinned FNDDS household-measure table from PR #50's MassConversionKit
  evidence at `/tmp/mck.json` (7,288 portion rows, 4,733 foods).

## 1. Build

```
$ python3 src/build_corpus.py
canon: canon rulebook: suite-pinned snapshot canon/rules.json (overhaul/food-safety-canon @ 2e03467d)
built 179 recipes -> .../world-2026-10/originals.jsonl
lines: 1190/1251 resolved; vegetarian 99/179
```

1,190 of 1,251 ingredient lines resolve through record-carried FNDDS
conversions; the remaining 61 are recipe-stated metric masses and unknown
("to taste") lines, each carrying its own evidence kind or note.

The builder prints `vegetarian 99/179` with its build-time classifier; the
packet checker's gate is stricter (it also resolves canon keyword classes
for every line) and counts 98/179. The checker's count is the release
number; the one-recipe delta is a classifier difference, not a data
change between the two runs.

## 2. Packet checker (rights, recomputed quantities, pinned lint, gates)

```
$ python3 src/check_packet.py
checked 179 records
vegetarian 98/179 (54.7%); slots {'dinner': 112, 'lunch': 58, 'breakfast': 35}
PASS: rights, quantities, pinned lint, and release gates all clean
```

The checker independently recomputes every household-line grams value from
the pinned FNDDS table and validates each `conversion_ref` against the row
that supports it (fdcId-checked), runs the pinned `rs.lint_recipe` over all
179 records with the fixture-plus-extension classification table and the
pinned canon, enforces the rights manifest, and applies the release gates
(vegetarian ≥ 1/3, claims gate, FSIS-noted extension classes). Exit code 0.

## 3. Planted-failure tests

```
$ python3 src/test_check_packet.py
CAUGHT   stripped poultry safety check -> fl-world-0038: R3 required doneness class meat_poultry (minimum 165 F, rest 0 min) has no thermometer check naming that class and minimum — checks must cover each ingredient's ACTUAL class, not an unrelated one
CAUGHT   deleted ground-meat check step -> fl-world-0039: R3 required doneness class meat_ground (minimum 160 F, rest 0 min) has no thermometer check naming that class and minimum — checks must cover each ingredient's ACTUAL class, not an unrelated one
CAUGHT   corrupted carried grams -> fl-world-0001: ingredient[2] 'soy sauce' carries grams 55.0, but the pinned FNDDS row fdcId 2707442 supports 32.0
CAUGHT   forged conversion_ref -> fl-world-0001: ingredient[2] 'soy sauce' cites conversion_ref 'fndds:000000000', which is not the pinned row fndds:2707442 supporting it
CAUGHT   deleted rights-manifest entry -> fl-world-0134: source_ref 'fl-world:ackee-and-saltfish' has no rights-manifest entry
CAUGHT   downgraded rights_status -> fl-world-0134: rights_status 'scraped' is not 'original'
CAUGHT   blanked rights author -> fl-world-0134: rights-manifest entry 'fl-world:ackee-and-saltfish' missing 'author'
CAUGHT   unsupported cuisine 'french' -> fl-world-0001: cuisine 'french' outside the suite vocabulary
CAUGHT   broken cuisine/world_cuisine mapping -> fl-world-0001: cuisine 'italian' does not match the region mapping for 'korean'
CAUGHT   unknown quantity with blank note -> fl-world-0001: ingredient[1] 'gochujang' unknown quantity carries no note
CAUGHT   zero source_grams -> fl-world-0001: ingredient[0] 'chicken thighs' source_grams 0 is not a positive mass
CAUGHT   unsubstantiated diet claim -> fl-world-0001: ships claims the packet does not substantiate
CAUGHT   broken id sequence -> record[4]: id 'fl-world-9999' breaks the fl-world-NNNN sequence
CAUGHT   meal slot 'brunch' -> fl-world-0001: meal_slots ['brunch'] outside the declared slots
14/14 planted failures caught
```

Exit code 0.

## 4. Composition

```
regions: korean 20, japanese 19, chinese 18, thai 17, vietnamese 16,
         middle_eastern 20, north_african 11, west_african 12,
         caribbean 14, latin_american 15, eastern_european 17
modules: east_asia 57, south_east_asia 33, mena 31, americas_europe 58
slot assignments: 205 (dinner 112, lunch 58, breakfast 35)
vegetarian (canon-aware, conservative): 98/179 (54.7%)
```

## Not checked

- No Apple host in this environment: the corpus is data-only (Python build +
  JSONL), so nothing here exercises Xcode or hosted macOS CI. The records
  are RS v1 and were validated with the pinned recipes suite, but no
  bundle-v2 compile of this packet (through the bundle compiler from PR
  #162) has been run — that integration is deliberately not attempted here
  because this packet ships originals, not a compiled bundle.
- The suite-runner validator from PR #113 cannot run on this packet as-is
  (hardcoded `fl-original-NNNN` IDs and `overhaul/original-recipes`
  provenance form); see README "Suite-runner integration gap". The packet
  checker covers the same checks with packet-local evidence paths, and the
  planted-failure tests demonstrate it detects the defect classes that
  matter.
- Sensory plausibility of 179 recipes was not taste-tested; the quantities
  are internally consistent with pinned conversions, but flavor-level
  accuracy is the author's judgment.
