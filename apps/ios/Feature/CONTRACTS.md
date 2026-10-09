# Feature-layer contracts

`apps/ios/Feature/` holds the UI features of FridgeLuck. This directory's public
functions and types are contracts: misuse must fail loudly at the boundary, not
deep inside a view model. This file defines the contracts; the checker next to
it makes the mechanical ones self-enforcing.

Run the checker (stdlib Python 3 only, no dependencies):

```bash
python3 apps/ios/Feature/contract_checker.py             # whole Feature tree
python3 apps/ios/Feature/contract_checker.py --path Demo # one submodule
```

## Type contracts

1. No forced casts (`as!`, rule S001). Downcast with `as?` and a `guard` that
   produces a specific, human-readable error or a documented, non-silent skip.
2. No force-try (`try!`, S002). Throwing APIs get typed errors; call sites
   either propagate or convert to a specific failure state.
3. No implicitly unwrapped optionals (`let x: T!`, S003). Storage is `T?` or
   `T`; unwrapping happens once, at a guard, with a specific error message.
4. No `Any`-typed payloads (`[String: Any]`, `: Any`, `as Any`, S004). Public
   inputs and outputs are concrete types. The single allowed exception is the
   `UIImagePickerController.InfoKey: Any` delegate signature required by
   UIKit; convert to concrete types on the first line of the delegate method.
5. Public functions declare precise input and output types: no untyped
   dictionaries in, no optionals out where the value is an invariant. When a
   "missing" result is a real state, model it as a typed enum case or a
   non-optional result type instead of `T?` + silent `nil`.
6. No `fatalError`/`preconditionFailure` in Feature code (S008) and no empty
   catch blocks (S007): every failure path carries a specific message naming
   the value that failed and the constraint it violated.
7. No `unowned` references (S009): closures capture `weak` where a reference
   cycle is possible and handle the nil case explicitly.

## Runtime validation at trust boundaries

Feature code reads external input at these boundaries. Each validates before
use and turns invalid input into a typed error with a specific message:

- Bundled JSON fixtures and catalogs (`Bundle.main`, `JSONDecoder`).
- Info.plist / environment configuration values (`GEMINI_BACKEND_BASE_URL`,
  version strings).
- User-entered text that becomes a number, URL, or identifier (Settings
  editors, search fields).
- Strings parsed into routes, keys, or file names.
- Parsed values must satisfy their documented ranges (e.g. percentages sum to
  100, confidence in `0...1`, normalized rects within `0...1`); out-of-range
  data is a named error case, not a silent clamp or a crash.

Validation lives in small, internal, pure functions in the same file as the
boundary code (e.g. `parseFixtureData(_:) throws -> [Detection]`), so call
sites keep their behavior and tests can hit the validator directly.

## Contract tests

Every submodule has contract tests in `apps/ios/Tests/<Module>ContractTests.swift`
(`import XCTest`, `@testable import FridgeLuck`). Each public function gets at
least:

- a valid-input case asserting the success shape,
- boundary cases (empty, zero, extreme-but-legal values),
- invalid-input cases asserting the exact error case (and, where the message
  is contractual, the exact message or a stable fragment of it).

These tests run in the repo's iOS CI (macos-26, Xcode 26.6, `scripts/run_ios_tests.sh`
via the `FridgeLuckTests` target). The Linux fleet sandbox cannot compile
SwiftUI, so tests are verified by CI, not locally; local verification is the
static checker plus careful cross-reading of referenced types.

## Discipline

- A bug found by tightening types is fixed test-first: failing test committed
  with (or before) the fix in the same change.
- Behavior changes only where a contract was violated. Refactors keep call-site
  behavior identical otherwise.
- No reformatting, no dependency changes, no workflow edits.
