# ScenarioJoin — Part 6 of the 2026-10-11 overhaul (the join)

A Linux-only SwiftPM package that composes the five capability packages of the
overhaul into one tree and proves they behave as one system: a simulated
household's full week, asserted end to end with a deterministic, injectable
clock. No network, no LLM calls, no personal data — synthetic fixtures only.

## Position in the overhaul

Reads `docs/spec/overhaul-20261011/SPEC.md` (§3 contracts) and `PLAN.md`
(suite E "the join") on branch `docs/spec-overhaul-20261011`. The composed
sibling packages, merged merge-only into `overhaul/scenario-join`:

| Order | Branch | PR | Head |
|---|---|---|---|
| 1 | `overhaul/core-foundation` | #90 | `5ec72a6` |
| 2 | `overhaul/flow-core` | #103 | `fe62373` |
| 3 | `overhaul/assistant-core` | #98 | `043702d` |
| 4 | `overhaul/pantry-truth` | #117 | `a556324` |
| 5 | `overhaul/community-core` | #106 | `01333a8` |

`packages/FridgeLuckCore/**` is read-only here (PR #90 awaits re-review);
foundation contract needs discovered during the join are recorded as contract
requests in the join PR's Handoff instead of patched.

## Layout

- `Sources/FLScenarioKit/` — the scenario harness:
  - `HouseholdWorld` — one in-memory GRDB database wiring the five packages'
  durable stores (pantry ledger, cook sessions, meal log, assistant receipts);
  `WeekClock` — an injectable, strictly monotonic clock (relative and absolute
  advances); `Week` — the scenario week (Mon 2026-10-05 .. Sun 2026-10-11, UTC).
  - `WorldStateSource` — the pantry→flow/assistant evidence adapter
  (`AssistantContextBuilder.WorldStateSource`, `FlowPantryLine`).
  - `ScenarioTrace` — a step log with canonical JSON serialization, for
  byte-identical replay evidence.
- `Tests/ScenarioJoinTests/` — the suites:
  - **S1 · Full week household arc** — one test, the whole week: shelf scan
  (observation, no amount guessed), an atomic 8-line grocery command with an
  idempotent retry, a drawer reconcile (one correction, one retraction with
  its own command id), Tonight under a shellfish restriction (filtered before
  ranking), two rejections that hold without new evidence, an accepted
  swap through the allergen gate, an assistant timer proposal approved
  against payload hash + snapshot revision, a cook killed mid-step and
  resumed from its checkpoint, meal-log commit, FIFO consumption and a
  leftover lot, share to a table (day precision), Friday spoilage, and a
  Sunday challenge derived only from committed cook records.
  - **S4 · Assistant authority invariants at the join** — forged payload
  hash refused (terminal, durable receipt), stale snapshot revision
  refused, expired proposals swept with receipts, decline is terminal,
  restart replay is idempotent, read tools never enter the authority path.
  - **S5 · Share export, redaction, and rights at the join** — the
  SharedCook wire shape leaks no pantry/health/taste/exact-time data
  (SPEC 3.4), recipe export → bytes → import round-trips, unknown caching
  rights quarantine, a missing rights declaration is refused, forbidden
  text rights are refused, LeChef drafts never travel, visibility
  transitions never widen as a side effect.
  - **S6 · Determinism and replay** — two fresh runs of the full week
  produce byte-identical canonical traces, the Tonight proposal is a pure
  function of its inputs, and the scenario clock never runs backwards.

## Replay

```sh
cd packages/ScenarioJoin
swift build        # the composed library links all five packages
swift test         # 16 tests in 4 suites, Linux
swift test --filter "S1"   # the full-week arc alone
```

Swift toolchain 6.4 on Linux (x86_64). Deterministic: seeded fixtures, UTC
clock anchored at `Week.start`, no wall-clock reads. Two runs produce
byte-identical traces (asserted in S6).

Native iOS/macOS behavior is **UNVERIFIED-NATIVE**: this package proves the
Linux/SwiftPM join; Apple-platform rendering and interaction are verified by
the existing iOS CI on PRs into `alpha` and by native QA, not here.
