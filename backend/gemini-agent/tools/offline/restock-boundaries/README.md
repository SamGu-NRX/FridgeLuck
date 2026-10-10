# Restock boundaries: reproducible offline study

An offline, seeded, byte-reproducible study of the boundary behavior of
`src/automation/restockJob.ts` (the restock automation). It drives the real
production functions under pinned clocks, compares the shipped elapsed-day
interpretation with a UTC calendar-date interpretation, and records where the
two disagree. It deliberately does not pick between them: choosing an
interpretation is a product policy decision this study does not make.

## What is here

| Path | Purpose |
| --- | --- |
| `fixtures/matrix.ts` | Hand-checked boundary fixtures: every epoch literal and expected count is derived in a comment next to it |
| `reference/model.ts` | Reference model: the elapsed-day interpretation (A, mirrored from production) and a UTC reference-date interpretation (B), plus per-item classifiers |
| `pipeline.ts` | Seeded matrix generator (4400 items) and analysis pipeline: buckets, divergence recording, permutation invariance, duplicate accounting, determinism checks |
| `run.ts` | CLI runner; writes `manifest.json`, `records.jsonl`, `summary.json` and prints SHA-256 digests |
| `tests/restock-boundaries.test.ts` | Boundary and parity tests driving the real functions under pinned clocks |

## How to run

From `backend/gemini-agent` (dependencies installed with `bun install`):

```sh
# boundary and parity tests (34 tests)
bun test ./tools/offline/restock-boundaries

# full matrix, seed 20261010, twice to prove byte-reproducibility
bun run tools/offline/restock-boundaries/run.ts --seed=20261010 --out=/tmp/run1
bun run tools/offline/restock-boundaries/run.ts --seed=20261010 --out=/tmp/run2
diff -r /tmp/run1 /tmp/run2   # empty: runs are byte-identical

# typecheck
bun run check
```

Any 8-digit `yyyymmdd` integer works as a seed; it also pins the clock to
`<date>T00:00:00Z` (seed `20261010` pins `2026-10-10T00:00:00Z`). Outputs are
reproducible from the seed and need not be committed; the digests below
identify this run.

## Production semantics under test

As written in `src/automation/restockJob.ts`:

```ts
daysRemaining = Math.ceil((expiryMs - Date.now()) / 86_400_000)  // per item
alert when daysRemaining <= thresholdDays                          // inclusive
display = Math.max(0, daysRemaining)                               // clamped
restock when quantityGrams < restockBelowGrams (strict, default 50)
missing expiresAt: skipped; unparsable expiresAt: silently dropped
generatedAt = new Date().toISOString()                             // wall clock
```

The two interpretations compared:

- **A (shipped): elapsed-day arithmetic.** The boundary flips at the expiry
  *instant*; a whole-day boundary occurs when the elapsed time crosses a full
  24h multiple of the expiry instant.
- **B (comparison): UTC reference-date arithmetic.** Compare the UTC calendar
  date of the expiry with the UTC calendar date of the observation instant. The
  boundary flips at UTC *midnight*.

## Matrix composition (seed 20261010, 4400 items)

| Class | Count |
| --- | --- |
| Date-only expiries (parsable, `YYYY-MM-DD`) | 2640 |
| Timestamped expiries (parsable, ISO instants) | 1319 |
| Missing / empty `expiresAt` | 176 |
| Unparsable `expiresAt` | 265 |
| NaN grams | 11 |
| Exact duplicates of the previous item | 258 |
| Same-name items with different expiry/quantity | 151 |

The four date classes partition the items exactly (2640 + 1319 + 176 + 265 = 4400).

## Findings (all counts from the seed-20261010 run)

**F1. The alert boundary is an instant, not a midnight.** At threshold 1 the
two interpretations disagree on *inclusion* for 231 of 4400 items (2331 items
alert under A, 2562 under B). At threshold 3 inclusion agrees exactly (0
divergences; 3026 alert under both), but 2048 items still show a *different
displayed day count* between the interpretations (1817 at threshold 1). Real
example from the run: item 17, "Pita Bread", expires
`2026-10-11T11:59:58.593Z`, observed at the pinned midnight: elapsed arithmetic
says 2 days out (no alert at threshold 1); reference-date says 1 day out
(alert).

**F2. Expired vs use-soon is not observable in production output.** Display
clamping means every expired item shows `daysRemaining === 0` (956 of 956
expired items under interpretation A). Production output alone cannot separate
"expired" from "expires today"; the distinction exists only in the raw
pre-clamp arithmetic the reference model records. Under interpretation B the
expired bucket is larger (1366 vs 956 at either threshold), so the choice of
interpretation also changes what "expired" means operationally.

**F3. Where the interpretations flip buckets.** 410 items at either threshold
land in `expired` under one interpretation and `use-soon` under the other
(956 vs 1366 in the expired bucket). Real example: item 37, "Kidney Beans",
expires `2026-10-09T11:59:59.160Z`, observed at pinned midnight
`2026-10-10`: elapsed arithmetic says 0 days (use-soon); reference-date says
expired.

**F4. The restock list keeps duplicates and uses a strict cutoff.** 611
below-cutoff items produce exactly 611 restock-list entries; 24 names appear
multiply (up to 30 entries for one name in this run). Items at exactly 50g are
excluded (strict `<`); NaN grams are silently excluded (`NaN < 50` is false).

**F5. Bad data fails silent.** All 265 unparsable dates and 176 missing/empty
dates are dropped without error and never alert, under both interpretations
and both thresholds. Nothing distinguishes them in production output; the
counts here come from the reference classification.

**F6. Ordering: restock list is order-invariant; alerts are order-sensitive
only among ties.** Across 25 seeded permutations of the full matrix, the
restock list was byte-identical every time, and the alert *multiset* was
invariant, but the alert sequence changed in 25 of 25 permutations because
equal-`daysRemaining` ties keep input order (stable sort). Consumers that index
alerts by position are therefore permutation-sensitive.

**F7. `generatedAt` is wall-clock; reproducibility needs a pinned clock.** Two
plans built in the same pinned instant report identical `generatedAt`
(`2026-10-10T00:00:00.000Z`); plans built under different pins differ even when
their alerts are identical. Unpinned runs are not reproducible byte-for-byte.

## Verification evidence

- 34 boundary/parity tests pass (`bun test ./tools/offline/restock-boundaries`).
- 13/13 pipeline checks pass, including the parity check that the reference
  model reproduces the real `computeUseSoon` and `computeRestockList` output
  over every item and both scenarios.
- Two independent runs at seed 20261010 are byte-identical (`diff -r` empty):

```
sha256(manifest.json) = cd2c00b0e311bf825c6d3fe3a5b88ecb5beb39623a9788531694d10a4905fa04
sha256(records.jsonl) = 5711f1f274cff4bf9a9cc9ca5c3f1b500cd3178d46d6992e064aa7cd274ef6cf
sha256(summary.json)  = 691bdda33a7b7235cbff2f8ad28a454f86af8503eb604b76ad72d98061d111a9
```

- `bun run check` (tsc) is clean with this tool added.

## Not decided here

- Which interpretation (A or B) the product should use: recorded, not chosen.
- Whether silent drops of invalid/missing dates and NaN grams are desirable:
  recorded; a future change could surface them.
- A mutation-testing harness: the reference model exists so a harness can
  perturb a copy of interpretation A without touching production source; it is
  scaffolding for that future work, not a completed harness.
