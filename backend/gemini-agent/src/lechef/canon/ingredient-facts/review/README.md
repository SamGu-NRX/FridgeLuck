# Ingredient-facts review bands

This directory holds sourced reviews of the ingredient facts canon
(`../facts.json`), one file per review packet, applied to the canon by
`../../../run/apply-facts-review.ts`. The reviews are the judgement; the apply
is mechanical.

## File format — `fridgeluck/facts-review/v1`

```json
{
  "schema": "fridgeluck/facts-review/v1",
  "packet": "burst14-fridgeluck-facts-review-a",
  "base_commit": "<facts.json's git commit when the band was reviewed>",
  "band": { "first": "achiote-paste", "last": "chili-peppers", "count": 87 },
  "reviews": [ ... ]
}
```

`band` names a contiguous slice of `facts.json` keys — every key from
`band.first` to `band.last` inclusive in JavaScript default string sort — and
`reviews` must cover exactly that set, each key once. Keys sort as plain
strings, so bands tile the canon without gaps or overlaps.

Each review entry:

- `key` — the reviewed fact key.
- `before_sha256` — the sha256 of the compact `JSON.stringify` of the fact as
  it sat in `facts.json` when the band was written. It pins what the reviewer
  saw: the apply refuses a review whose fact no longer hashes to this value.
- `allergens` — the ten reviewed allergen tokens (`milk`, `egg`, `fish`,
  `crustaceanShellfish`, `molluscanShellfish`, `treeNuts`, `peanuts`, `wheat`,
  `soy`, `sesame`), each with a full state `{ "state": "contains" | "free" |
  "unknown", "evidence": { "kind": "standard" | "reference", "ref", "note" } }`.
  Reference evidence names an https URL and a `retrieved YYYY-MM-DD` date.
- `diets` (optional) — reviewed diet states (`allowed` | `violated` |
  `unknown`) for the same evidence shape. Component-less facts review all five
  diet tokens (`vegan`, `vegetarian`, `pescatarian`, `dairyFree`,
  `glutenFree`); compounds list only deliberate corrections.
- `changes` (optional, documentation only — the apply does not read it) — the
  human-readable list of states this review changed, with reasons.

## Apply rules

`bun run src/run/apply-facts-review.ts` (in `backend/gemini-agent`) applies
every `band-*.json` here to `facts.json`:

- **Applied** — the fact still hashes to `before_sha256`: the reviewed
  `allergens` replace the fact's allergen block and reviewed `diets` merge
  over the fact's diet states. Everything else on the fact is untouched.
- **Unchanged** — the fact already equals the review applied: left byte
  identical. This is what makes a second run of the script a no-op.
- **Refused** — the review is skipped, the fact is left exactly as it was,
  and the reason is listed in the run report:
  - `before_sha256` mismatch (the fact changed since the review pinned it),
    unless the fact already equals the review applied;
  - the same key reviewed in two band files (the script refuses to pick a
    winner — fix the bands, do not edit the fact);
  - a band file that misses a key of its band, carries a key outside it, or
    reviews a key twice — the whole file is refused;
  - a review whose key has no fact in `facts.json`.

The canon's format is preserved on write: two-space JSON indent, no trailing
newline, and every key order kept, so the diff shows exactly the reviewed
states and nothing else.

Band files are reviewed artifacts: never edit one to make the apply pass. When
a band is wrong, fix it in its own packet, or have the apply refuse the
affected review and leave the fact as it was — listed, with the reason, in the
run report.

Run it again after any canon or band change: applying the same bands twice is
always safe and always a no-op the second time.
