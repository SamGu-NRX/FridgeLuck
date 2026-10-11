# Suite G — journeys

Letter G, platform `macos` for the primary arm. The bar is PLAN.md line 52:
**all nine journeys pass with no crash** — first run, scan and review,
Tonight, recipe, cook, complete, share, challenge, taste-profile edit.

## Arms

- **macOS arm (primary, XCUITest).** `xcuitest/FLJourneysUITests.swift` drives
  the installed app through each journey and attaches one JSON payload
  (`fl-journeys-<timestamp>.json`) listing every journey with raw per-step
  results and a status: `passed` | `failed` | `crashed` | `blocked`. A journey
  blocked by a bug or a missing surface is a **real failure for the bar**,
  never not-run and never silently skipped. The host adapter
  (`adapters/journeys_parse.py`) normalizes the xcresult summary, validates
  the payload, cross-checks both channels (payload `passed` with a failed
  test case, or the inverse, is rejected -> not-run, never pass), and derives
  `g_journeys_passed_pct`. A harness test (`test_journey_runner_harness`)
  gates the run: if the app cannot reach the tab bar, per-journey results are
  untrustworthy and the metric fail-closes.
- **static arm (supporting evidence, any host).** `static/entry_points.py`
  searches the committed SwiftUI source for a discoverable entry affordance
  per journey (button labels, navigation titles, ShareLink, accessibility
  labels) and reports `g_static_entry_points_discoverable` — count of
  journeys with at least one affordance, bar == 9. It asserts nothing about
  completing a journey; only the macOS arm can. The value is the conservative
  lower bound; unreadable files widen the interval noted in the detail.

## Files

- `suite.json` — contract manifest (id, letter, platform, owner_task).
- `suite.py` — orchestrator: `--out/--repo-root` run, `--self-test`.
- `journeys.json` — the nine committed journey definitions and step intents.
- `adapters/journeys_parse.py` — payload + xcresult normalization and
  cross-check; the only place metric inputs are derived.
- `static/entry_points.py` — static entry-point discovery.
- `fixtures/sample-journeys/` — SYNTHETIC sample payload + xcresult summary
  shaped like real runner output; the adapter self-tests run on Linux against
  these.
- `xcuitest/FLJourneysUITests.swift` — the XCUITest journeys runner.
- `xcode/project.yml` — XcodeGen spec; includes the repo-root `project.yml`
  and adds the UI test bundle. The driver generates
  `FridgeLuckEvalJourneys.xcodeproj` at run time; nothing generated is
  committed.

## Results

Written to `evaluation/out/journeys/results.json` per SCORECARD.md. On Linux
the macOS-arm metric is `not-run` with the precise reason; committed results
from an approved native CI run are imported by the runner.

## Self-test

`python3 evaluation/run.py --self-test` (or `python3 suite.py --self-test`
from this directory) plants six failure scenarios — a crashed journey in
otherwise-consistent fixtures, a lying emitter (all-passed payload against a
failed test case), flipped labels (a passed run with a journey failure
smuggled in), a missing journey id, a blocked journey with no `blocked_by`
reason, and a missing xcresult channel — and asserts each flips the derived
status. Prints `caught 6/6 planted failures`; exit 0 only when all caught.

## Open question for the programme

The static arm is supporting evidence only. It happens to agree with the
simulator bar's direction on this base (share and challenge have no
discoverable entry point, and the plan requires them runnable), but a
journey can have an entry affordance and still be uncompletable, and a
journey could in principle be completable via an affordance the scanner does
not model. The simulator bar therefore stays; do not replace it with static
discovery.
