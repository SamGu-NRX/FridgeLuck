#!/usr/bin/env python3
"""Structural gate for the generated corpus (run before every push).

Reuses suite.py's validate_session via load_sessions so the corpus is checked
against exactly the schema the scorer enforces — one schema definition, no
drift between generator and scorer. Exits non-zero below 150 sessions or on
any problem.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import suite  # local scorer module (imports the vendored contract)


def main() -> int:
    sessions, problems = suite.load_sessions(HERE)
    by_job: dict[str, int] = {}
    for s in sessions:
        by_job[s["job"]] = by_job.get(s["job"], 0) + 1
    for job in suite.JOBS:
        print(f"  {job}: {by_job.get(job, 0)} valid sessions")
    print(f"total: {len(sessions)} valid sessions, {len(problems)} problems")
    for p in problems[:20]:
        print(f"  ! {p}")
    if len(problems) > 20:
        print(f"  ... and {len(problems) - 20} more")
    ok = not problems and len(sessions) >= 150
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
