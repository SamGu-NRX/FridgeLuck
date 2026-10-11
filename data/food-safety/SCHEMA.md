# data/food-safety/SCHEMA.md

The reviewed food-safety rulebook. `rules.json` is the single source of truth for
doneness checks, appearance limits, cooling and thawing windows, cross-contamination
steps and high-risk-group notes. `packages/FLFoodSafety` decodes this file and fails
loudly on a schema violation. `COPY.md` tells writers and LeChef how to phrase it.

## Design rules

1. **No rule without a source.** Every rule carries `citation_ids`, and every
   cited citation carries `org`, `title`, `url`, `retrieved` and at least one
   verbatim `quote` (plus optional `second_quote` … `tenth_quote`) from the live
   page. A validator test in `packages/FLFoodSafety` asserts this and fails loudly
   on a rule with no resolvable, fully-attributed citation.
2. **Doneness is a thermometer test.** Meat, poultry, fish, eggs and leftovers
   state a checkable internal temperature with placement and rest time. Colour,
   "no pink", clear juices and firmness appear only as `visual_cues_insufficient`.
   Timers say when to check; they never decide doneness.
3. **Advisory, never certification.** The guidance reduces risk; it never certifies
   that food is safe. Shelf-life numbers in `SHELF-LIFE.json` are quality guidance
   from USDA FoodKeeper data and never a safety claim.
4. **Rescaling.** A time change is supported only where a reviewed rule supports it
   (thickness, pan size, quantity in the pan, cook-from-frozen +50%). Otherwise the
   step says to check with a thermometer rather than trust the timer.

## RS alignment (suite C corpus linter)

rules.json `food_class` values and minimums are the exact `FSIS_TEMP_F` map in
`evaluation/suites/recipes/rs.py` (branch `eval/scorecard-runner`): meat_poultry 165,
meat_ground 160, meat_whole_cut_pork 145, meat_whole_cut_red 145, flesh_fish 145,
flesh_shellfish 145, egg 160, leftovers 165. A corpus safety field names one of these
classes with `temp_f` at or above the class minimum, `method: "thermometer"` and a
non-empty `source`; the Swift linter's forbidden-phrase set mirrors rs.py's
`_COLOUR_OR_TIME_DONENESS` regex plus "juices run clear" (FSIS explicitly rejects juice
colour), and COPY.md's never-say list matches the same set.

## File shape

```text
{
  "schema_version": 1,                    // integer, must equal 1
  "retrieved": "2026-10-11",              // date the quotes were verified
  "name": string, "description": string,
  "citations": [                          // ≥ 1; the source registry
    {
      "id": string,                       // unique, referenced by rules
      "org": string,                      // publishing body: USDA FSIS, FDA, FoodSafety.gov, CDC
      "title": string,                    // page or dataset title
      "url": string,                      // absolute http(s) URL of the source
      "retrieved": string,                // ISO date the quote was verified against the live page
      "page_last_updated": string?,       // stated last-updated date when the page shows one
      "quote": string,                    // VERBATIM text from the source (never paraphrased)
      "second_quote" … "tenth_quote": string?  // additional verbatim quotes from the same source
    }
  ],
  "rules": [                              // ≥ 1
    {
      "id": string,                       // unique, kebab-case
      "topic": string,                    // doneness | reheating | cooling_window | danger_zone |
                                          // leftover_storage_window | cooling_method | thawing |
                                          // cross_contamination | hygiene | raw_egg | rest_time |
                                          // thermometer | appearance_not_sufficient | high_risk_groups
      "food_class": string?,              // the RS FSIS class from evaluation/suites/recipes/rs.py
                                          // (branch eval/scorecard-runner): meat_poultry 165 °F |
                                          // meat_ground 160 | meat_whole_cut_pork 145 |
                                          // meat_whole_cut_red 145 | flesh_fish 145 |
                                          // flesh_shellfish 145 | egg 160 | leftovers 165
      "summary": string,                  // one reviewed sentence
      "check"?: {                         // present for doneness/rest rules
        "kind": "thermometer" | "rest",
        "temp_f": number, "temp_c": number,
        "rest_minutes": number,           // 0 when none
        "placement"?: string,
        "alternative_temp_f"?: number     // e.g. ham 140 °F for USDA-inspected plants
      },
      "match_keywords"?: [string],        // lowercase ingredient/step keywords for the lookup
      "rs_note"?: string,                 // how the rule maps onto the RS corpus safety field
      "published_appearance_alternative_note"?: string,  // a cue a source publishes that the app still never uses as a verdict
      "visual_cues_insufficient"?: [string],  // cues that must never decide doneness
      "high_risk_groups"?: [string],
      "citation_ids": [string]            // ≥ 1, every id must resolve to citations[]
    }
  ]
}
```

## Validation contract (enforced by tests)

- The JSON parses; unknown rule or citation keys fail decoding (strict).
- `schema_version == 1`; `retrieved` is an ISO date.
- Every `food_class` is one of the eight RS FSIS class names.
- Citation `id`s are unique; every `citation_ids` entry resolves.
- Every citation has non-empty `org`, `title`, `url` (http/https), `retrieved`
  and a verbatim `quote` of at least 20 characters.
- Every doneness/rest rule has a `check` with `temp_f` and `temp_c`.
- Every rule has at least one citation. A rule without a source fails the test
  suite loudly — the file does not ship.

## Provenance of the quotes

Quotes were verified on 2026-10-11 against the live pages by fetching each URL and
reading the rendered text (fsis.usda.gov and foodsafety.gov sit behind an Akamai
bot filter; the verification fetch went through the r.jina.ai text proxy of the same
live URL, which returns the page content verbatim). The FoodSafety.gov and FSIS
tables are reproduced as pipe-separated rows inside `table_quote` so the quoted
cells survive JSON. `SHELF-LIFE.json` quotes the USDA FoodKeeper dataset rows
verbatim and marks all values as quality guidance, never safety certification.
