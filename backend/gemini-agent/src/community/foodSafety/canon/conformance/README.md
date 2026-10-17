# Conformance kit

A self-test of the whole food-safety canon. Every named error class the
linters can emit, every true negative, and a clean replay live here as small
synthetic fixtures; `fl-safety-lint conformance data/food-safety/conformance/`
replays them through the same package linters the app uses and fails unless
reality matches every pinned expectation.

The fixtures are the input shape the linters consume — nothing here is app
data, user data, or scraped from an external source. Fixtures carry no
citations of their own; every rewrite a finding suggests is cited by the
linter from `data/food-safety/rules.json`.

## Running

    swift run --package-path packages/FLFoodSafety fl-safety-lint conformance \
        data/food-safety/conformance/

Exit codes: `0` every case matched and the clean replay produced zero
findings · `1` at least one case mismatched · `2` usage error · `3`
input/output or format error (missing files, undecodable kit content).

The kit must cover every `LintFinding.Kind` case and every CopyLint pattern
id; the runner fails the run if a class or pattern is not pinned by any
`expect.kinds`. Adding a linter behaviour without a fixture here is a canon
failure.

## Case files (`cases-*.json`, name-sorted)

    {
      "schema_version": 1,
      "name": "...",
      "description": "...",
      "cases": [
        {
          "id": "unique-case-id",
          "record": { ... one record, shape below ... },
          "rules": null,              // optional; see fail-closed cases
          "expect": {
            "kinds": ["KindName", ...],          // exact expected sequence
            "rule_id": "rule-id",                // optional; every finding's ruleID when pinned
            "rewrite_contains": ["..."],         // optional; substrings of suggestedRewrite
            "detail_contains": ["..."]           // optional; substrings of detail
          }
        }
      ]
    }

`expect.kinds` pins the full kind sequence in emission order — an extra or
missing finding fails the case, not only a kind mismatch. For recipe records
the kinds are `LintFinding.Kind` raw values (`belowMinimumTemperature`,
`missingThermometer`, `missingInternalTemperature`, `missingRestTime`,
`ovenTemperatureAsDoneness`, `metadataNotInText`, `failClosed`,
`flagForReview`, `appearanceDoneness`, `timeOnlyCooking`, `rawEggNoWarning`,
`ambientThawing`, `leftoversHeldOut`, `reheatingWithoutThermometer`); for
copy records they are CopyLint pattern ids (`salvage-spoiled`,
`leafy-greens-too-far-gone`, `cook-decayed-or-sprouted`,
`fish-curing-rescue`, `smell-safety-test`). Independent of the pins, every
finding must carry a rule id, a citation and a suggested rewrite — the
one-finding format in `data/food-safety/README.md`.

The optional case-level `rules` override replaces the rulebook the tool loads
from the repository default: `null` means no rulebook at all, a string is
deliberately broken inline JSON. Both exist to exercise the fail-closed
paths; when a case goes fail-closed the fail-closed verdict is the only
finding.

## Record shape (shared with `fl-safety-lint lint`)

Recipe records (strict step linter, exactly what `BundledRecipeAudit` feeds
the linter):

    {
      "kind": "recipe",
      "file": "conformance/cases-temperature-errors.json",  // synthetic source path for findings
      "id": "cx-ground-poultry-160",
      "title": "Turkey burgers",
      "ingredients": "500 g ground turkey, salt, pepper",
      "instructions": "1. Form the ground turkey into patties and cook to 160 °F.",
      "safety_fields": { "0": { "class": "meat_poultry", "temp_f": 165,
                                "method": "thermometer", "source": "..." } }
    }

`instructions` are newline-separated; lines beginning `1.` / `1)` start a
step and continuation lines append to it (zero-based step indices). The
optional `safety_fields` maps a zero-based step index to the structured
safety field object `{class, temp_f, method, source}` in the corpus shape.
Unparseable fields, unknown classes and non-thermometer methods are linter
findings (fail closed), not driver errors.

Copy records (copy lint over recipe tips and notes):

    {
      "kind": "copy",
      "file": "conformance/cases-copy-lint.json",
      "id": "cx-copy-salvage",
      "field": "tip",
      "text": "That bag of salad is looking slimy - blend it into a smoothie anyway, don't waste it."
    }

A text can match more than one pattern; the case pins the full sequence in
emission order (see `leafy-greens-too-far-gone` in `cases-copy-lint.json`).

## `true-negatives.json`

Same case format; every `expect.kinds` is empty. Complete thermometer checks,
steps that need no check, and copy that praises none of the unsafe salvage
patterns must all pass clean.

## `replay-clean.json`

The records-file shape `fl-safety-lint lint` consumes
(`{"schema_version": 1, "description": ..., "records": [...]}`): a small
fully conforming recipe set plus a conforming copy record. Run through the
normal lint path it must produce zero findings.
