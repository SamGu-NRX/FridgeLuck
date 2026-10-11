"""Bounded, strictly read-only SQLite access. Owned by: READER stream.

Contract (do not change signatures; do not edit model.py / codes.py):
- probe_input(path) -> InputInfo : stat + digest without creating anything.
  Raise model.RefusalError BEFORE any open with codes from codes.py:
  INPUT_MISSING, INPUT_NOT_REGULAR_FILE, INPUT_SYMLINK, INPUT_NOT_SQLITE,
  INPUT_SIDECAR_PRESENT (any sibling <input>-wal / -shm / -journal file).
  Symlinks are never followed. INPUT_NOT_SQLITE covers files whose first 16
  bytes are not b"SQLite format 3\\x00" and files smaller than 32 bytes.
- open_read_only(path, budget) -> (sqlite3.Connection, InputInfo, BudgetHandle):
  open via URI "file:<quoted>?mode=ro" (uri=True) — never a plain path open —
  then PRAGMA query_only=ON and install the progress handler. Never creates the
  file: if sqlite still reports inability to open read-only, re-raise as
  RefusalError("INPUT_NOT_REGULAR_FILE", ...). Catch sqlite3.Error and raise
  RefusalError with a fixed code; never surface exception text.
- class BudgetHandle: .steps_used, .cancelled, .deadline_hit attributes; the
  progress handler counts steps, checks time.monotonic against the deadline and
  raises BudgetExceeded (via aborting return) when caps are hit.
- bounded_fetch(cursor, budget) -> (rows, truncated): fetchmany in chunks,
  stop at budget.max_rows, report truncated=True instead of reading further.

Never write, never create/delete files, never execute arbitrary SQL strings.
"""
from __future__ import annotations


def probe_input(path: str):  # noqa: ANN201 - contract stub
    raise NotImplementedError("reader stream: probe_input")


def open_read_only(path: str, budget):  # noqa: ANN201 - contract stub
    raise NotImplementedError("reader stream: open_read_only")


def bounded_fetch(cursor, budget):  # noqa: ANN201 - contract stub
    raise NotImplementedError("reader stream: bounded_fetch")


class BudgetHandle:  # replaced by reader stream implementation
    steps_used = 0
    cancelled = False
    deadline_hit = False
