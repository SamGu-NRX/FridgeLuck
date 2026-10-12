# Contributing to FridgeLuckCore

This package holds the portable logic of the overhauled app: `FLDomain`
(Foundation-only contracts) and `FLPersistence` (GRDB-backed store). It builds
and tests on Linux; iOS/macOS behavior is **UNVERIFIED-NATIVE**.

## Who owns `Package.swift`

**The foundation (branch `overhaul/core-foundation`) owns this manifest.**

The ownership split:

- The foundation owns the manifest's *structure*: the package name, platform
  floors, external dependencies, the products list, and the existing
  `FLDomain`/`FLPersistence` target entries.
- A later part that ships inside this package adds **exactly one `.target`
  and one `.testTarget` — its own — and nothing else**. Never edit another
  part's target entry, never reorder the manifest, never touch the products
  or dependencies blocks. Concurrent parts adding their pairs at the same
  time resolve by re-merge, which is cheap precisely because each edit is
  two appended entries.
- A later part that ships as its own package (`packages/<YourPackage>/`, like
  the canonical `FLIngredientFacts` and `FLFoodSafety`) owns **its own
  manifest entirely** and never edits this manifest or any other part's.
- Nobody edits another part's manifest. Ever. If you believe a change to a
  manifest you do not own is needed, raise it on the owning part's PR instead
  of editing it.

## Adding your target (later part inside this package)

Three edits, all yours:

1. **`Package.swift`** — append your pair to `targets`:

   ```swift
   .target(name: "FLFlow", dependencies: ["FLDomain"]),
   .testTarget(name: "FLFlowTests", dependencies: ["FLFlow"]),
   ```

   Declare a dependency only on targets you actually use. Add a one-line
   comment above your entries saying what your target is, like the existing
   ones do. Do not add an empty placeholder target "for later".

2. **Source + tests** — create `Sources/FLFlow/` and
   `Tests/FLFlowTests/`. The test target directory must be named
   `<Target>Tests` (the named-suite runner and CI proposal assume this).

3. **Import allowlist** — if your target imports anything beyond the
   defaults, add the declaration to `scripts/overhaul-checks/import_rules.py`
   in the same PR. The checker fails closed: an import that is not explicitly
   allowed is a violation, so a missing declaration is caught before merge.
   Standing rules the checker enforces (and `Package.swift`'s header states):
   `FLDomain` imports Foundation only; no target imports UIKit, SwiftUI or
   AppKit; dependency direction is `FLDomain` (rank 0) < `FLPersistence`
   (rank 1) < capability targets (rank 2) — you may import lower-ranked
   layers, never higher ones.

## Verification before you push

From the repository root:

```
python3 scripts/overhaul-checks/check.py --suite imports   # boundaries
python3 scripts/overhaul-checks/check.py --suite all       # every test target
python3 scripts/overhaul-checks/check.py --suite data      # fixture contract
python3 scripts/overhaul-checks/test_import_rules.py       # checker's own tests
python3 scripts/overhaul-checks/test_check.py              # runner's own tests
```

`check.py --list` names every suite. Iterating on your part only? Add one
entry to `SUITES` in `scripts/overhaul-checks/check.py` mapping a suite name
to your test filter — your own line, again one entry, same ownership rule —
and run `check.py --suite <name>`.

Paste the exact commands and output into your PR's Proof section; the runner
prints a header (HEAD SHA, toolchain, platform) that says what produced it.

## Fixtures

The canonical JSON fixtures under `Fixtures/` are frozen contract evidence.
Regenerate only with
`FL_UPDATE_FIXTURES=1 swift test --filter FixtureContractTests`, and treat
any diff as a contract change: flag it in the PR and expect re-review of
everything that consumes the fixture.

## CI

`ci/pending-workflows/core-linux.yml` is **a staged proposal, not installed** —
installing workflows is Sam's call, made by his own hand. Do not move it into
`.github/workflows/` and do not edit installed workflows.
