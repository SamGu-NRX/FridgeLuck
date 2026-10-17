#!/usr/bin/env python3
"""Planted-failure self-test for suite A's scorecard identity and battery.

Covers the two suite-side review defects on PR #88 (defects 5 and 7):

1. identity — a real suite invocation (the runner's exact CLI) must emit
   results.json carrying the PLAN.md identity (letter "A", title "Pantry
   truth"): the runner renders the scorecard heading from the run payload,
   so a payload without them renders `## ?. pantry-truth`.
2. completeness row — the emission must carry a completeness row over every
   metric row PLAN.md line 49 requires of suite A, so a battery that emits
   fewer rows can never pass silently.
3. planted removal — a required battery row removed from the suite's
   emission must come back as not-run with a reason naming it, and the
   completeness row must derive FAIL. On a tree without the enforcement
   the removed row sails through unflagged and the plant goes UNCAUGHT.

Prints one `caught`/`UNCAUGHT` line per behaviour and exits 0 only when all
are caught. Runs the suite through its real CLI on a synthetic mini corpus
(no Swift build: the probe stage fails closed to not-run on the fixture
root, which is exactly the honest not-run path this test exercises).

Usage: python3 test_battery_completeness.py   (from anywhere)
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

SUITE_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SUITE_DIR))

import suite  # noqa: E402  (same directory)
import suite_contract  # noqa: E402

PLANT_ROW = "sufficient_claimed_without_quantity_evidence"
REQUIRED_IDS = [mid for mid, _ in suite.METRIC_DEFS]
# The unfixed tree (26c7004e) declares neither the completeness row nor its
# enforcement; fall back to the fixed tree's names so the plant below
# demonstrates the DEFECT (a removed row sailing through unflagged) instead
# of crashing on a missing symbol.
COMPLETENESS_ID = getattr(suite, "BATTERY_COMPLETENESS_ID", "plan_battery_rows_present")


def _run_real_suite(root: Path, out: Path) -> dict:
    """Invoke suite.py exactly the way evaluation/run.py does."""
    proc = subprocess.run(
        [sys.executable, str(SUITE_DIR / "suite.py"),
         "--out", str(out), "--repo-root", str(root)],
        capture_output=True, text=True, cwd=str(SUITE_DIR), timeout=300,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"suite.py exited {proc.returncode}: {(proc.stderr or proc.stdout)[-400:]}"
        )
    return json.loads((out / "results.json").read_text())


def main() -> int:
    caught = 0
    total = 3

    with tempfile.TemporaryDirectory(prefix="fl-battery-selftest-") as tmp_s:
        tmp = Path(tmp_s)
        suite._mini_manifest(tmp)  # synthetic corpus root (fixture)
        payload = _run_real_suite(tmp, tmp / "out")

        # 1. identity: letter/title present in a real run's results.json.
        ok = payload.get("letter") == "A" and payload.get("title") == "Pantry truth"
        print(f"identity (letter A, title 'Pantry truth') in a real run: "
              f"{'caught' if ok else 'UNCAUGHT'}")
        caught += ok

        # 2. the emission carries a completeness row over the required rows.
        ids = [m.get("id") for m in payload.get("metrics", [])]
        ok = (
            all(mid in ids for mid in REQUIRED_IDS)
            and COMPLETENESS_ID in ids
        )
        print(f"emission carries a completeness row over PLAN.md line 49 rows: "
              f"{'caught' if ok else 'UNCAUGHT'}")
        caught += ok

        # 3. plant: remove one required battery row from the suite's emission.
        produced = {
            m["id"]: m for m in payload["metrics"]
            if m.get("id") != COMPLETENESS_ID
        }
        del produced[PLANT_ROW]
        gate = getattr(suite, "enforce_battery_completeness", None)
        emitted = gate(produced) if gate is not None else list(produced.values())

        scored = {"suite": "pantry-truth", "letter": "A", "title": "Pantry truth",
                  "metrics": emitted}
        suite_contract.validate_results(scored)
        ids = [m.get("id") for m in emitted]
        fail_rows = [m for m in emitted if suite_contract.derive_status(m) == "fail"]
        names_it = any(PLANT_ROW in json.dumps(m) for m in fail_rows)
        emitted_not_run_named = any(
            m.get("id") == PLANT_ROW
            and m.get("status") == "not-run"
            and PLANT_ROW in (m.get("reason") or "")
            for m in emitted
        )
        ok = (
            PLANT_ROW in ids                      # row never vanishes from the card
            and COMPLETENESS_ID in ids
            and bool(fail_rows) and names_it      # the suite FAILS, naming the row
            and emitted_not_run_named             # the row itself is not-run with reason
        )
        print(f"plant: removed battery row '{PLANT_ROW}' fails with the row named: "
              f"{'caught' if ok else 'UNCAUGHT'}")
        caught += ok

    print(f"caught {caught}/{total} planted checks")
    return 0 if caught == total else 1


if __name__ == "__main__":
    sys.exit(main())
