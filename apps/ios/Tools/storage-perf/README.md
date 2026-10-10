# storage-perf — FridgeLuck local-store benchmark harness

Long-lived SwiftPM harness for FridgeLuck's local GRDB/SQLite store. It compiles
the REAL production persistence sources (`apps/ios/Platform/Persistence`) against
GRDB, seeds disposable databases of realistic sizes through the real pinned
migrations, runs the repository reads the app actually ships, and writes a
digest-signed canonical JSON report. Runs on Linux — no Xcode required.

**This package never changes production schema or indexes.** Index/query
alternatives run only in disposable experiment databases that are deleted after
the run.

## Layout

- `Sources/StoragePerfCore/Seeder.swift` — workload profiles (month / year /
  five_year) × household-scale factors (1/2/4/8/16), seeded deterministically
  from one fixed seed. Catalog sizing matches the bundled catalog's order of
  magnitude; no bundled data is copied. Seeding goes through
  `DatabaseMigrations.migrate` (the real migrations), with foreign keys enabled
  to match `AppDatabase.setup()`.
- `Sources/StoragePerfCore/ReadWorkloads.swift` — the timed reads
  (use-soon, active items, recent events, journal page/full, daily/today
  macros, meals by day, point lookups) and the mirrored production SQL used for
  EXPLAIN QUERY PLAN capture.
- `Sources/StoragePerfCore/Experiments.swift` — index/query alternatives
  evaluated against the production queries with two gates: exact output parity
  (doubles compared by raw bit pattern) and bit-sensitive nutrition parity.
  A failed gate is a finding, not a crash.
- `Sources/StoragePerfCore/Runner.swift` — the sweep and the report
  writer/verifier contract.
- `Sources/StoragePerfCore/Canonical.swift` — sorted-key canonical JSON and a
  reference SHA-256 (no platform variance).
- `Sources/StoragePerfCore/Metrics.swift` — wall-clock timings in whole
  microseconds, plan capture, SQLite conditions, memory reading.
- `Tests/StoragePerfTests` — generator invariants, digest contract, and
  mutation controls proving the report verifier rejects tampered input.

## Build and run

Real production sources are not committed to this package — refresh them first
(paths relative to this directory):

```sh
bash Scripts/refresh.sh   # copies real persistence sources into Sources/StoragePerfCore/Real
swift test                # invariants + mutation controls
swift run StoragePerf --out results/summary.json
```

Options: `--profiles month,year,five_year`, `--scales 1,2,4,8,16`,
`--iterations N` (default 15), `--warmup N` (default 3), `--seed N`,
`--no-experiments`. Exit code 0 means the report was written and verified.

## Report contract

`summary.json` is compact single-line JSON with sorted keys; the last field is
`"digest":"<sha256-hex>"` computed over the exact body bytes that precede it.
`ReportVerifier.verify(text:sourceRoot:)` rebuilds that digest and checks
structural invariants; a report that fails verification was tampered with or
truncated.

Beyond the digest, verification recomputes every timing summary from the
frozen per-iteration samples (each read records its own `warmup` and
`iterations` counts plus `warmupUs`/`iterationsUs`; `summary` must regenerate
from those samples exactly), and checks a `sourceManifest`: SHA-256 hashes of
every file the harness compiled — the mirrored production sources under
`Sources/StoragePerfCore/Real/`, `Package.swift`, package-resolution data, and
the refresh script. Pass `sourceRoot:` (or run `swift run StoragePerf --verify
REPORT`) to re-hash the checked-out files and reject any drift: a report is
thus bound to the exact sources that produced it.

Memory readings come from `/proc/self/status` on Linux. The fields are
tab-separated there; rows that are absent, zero, or unparsable are reported as
unavailable (`null`), never as a measured zero.

Timing reproducibility: same machine, same seed, same binary ⇒ identical row
counts and query plans. Timings vary run to run; per-iteration samples are
recorded so distributions can be re-derived. The pinned run date is
2026-10-10 (fixed calendar anchor in `Seeder.swift`), so re-running the pinned
seed reproduces the pinned data regardless of clock.

## Experiment gates

Because nutrition totals feed Apple Health and the nutrition log, an
alternative query is only actionable if every nutrition double is reproduced
exactly (`bitPattern` equality) and every decoded row matches the production
query's rows value-for-value in order. Reports record both gates per
experiment plus baseline/alternative plans and timing samples, so a gate
failure is always distinguishable from a speedup.

## Handoff

State of this work as of 2026-10-10, for whoever picks it up.

**Pinned base.** This work ships on branch `obv/fl-l2-storage-performance`,
based on `origin/obv/fl-next-historical-nutrition-r1` at commit `e01b807`
(schema versions v1–v20). Production persistence sources were mirrored into
`Sources/StoragePerfCore/Real/` at that snapshot (see `Scripts/refresh.sh`);
the mirrors are committed so a fresh checkout compiles and so the report's
source manifest can be re-verified.

**Inherited app-CI failures.** Hosted macOS CI on this branch shows failures
that originate in the base snapshot, not in this PR:

- `MigrationUpgradeTests.testUpgradeAddsTheNewMigrationsInOrder` — the
  assertion still names v16–v18 as the newest migrations; the base now pins
  v18–v20.
- `NutritionReportingTests` (several cases) — fixtures insert cooking history
  directly without nutrition-snapshot capture (pre-v20 fixtures), so reads
  fail with "snapshot missing for history".
- `OnboardingGatePolicyTests` (several cases) — fixtures insert
  `allergen_selected_groups` into a pre-v19 `health_profile` schema.

None of these is caused by the harness; do not "fix" them by touching
production schema, migrations, or queries.

**App CI does not validate the measurements.** The app CI pipeline does not
build this package or run its tests; the committed sweep results are validated
by this package's own Linux suite and the report verifier, not by app CI. To
re-check a report end to end: `swift run StoragePerf --verify
storage-perf-results/summary.json` — it re-verifies the digest, regenerates
every summary from the frozen samples, and re-hashes the checked-out sources
against the embedded manifest.

**Replay after base corrections.** The measured numbers (Linux sandbox,
release build, seed 20261010) are a snapshot of the pinned base. When the
inherited base failures are fixed on the integration line (especially any
migration or nutrition-snapshot change), re-run the sweep and replace
`storage-perf-results/summary.json`:

```sh
bash Scripts/refresh.sh
swift test
swift run StoragePerf --out storage-perf-results/summary.json
```

Timings will differ run to run; row counts, query plans, and experiment gate
verdicts are the reproducible parts.
