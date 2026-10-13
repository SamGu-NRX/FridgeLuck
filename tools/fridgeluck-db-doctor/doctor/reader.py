"""Bounded, strictly read-only SQLite access. Owned by: READER stream.

This module is the only place fridgeluck-db-doctor touches SQLite or the
input file. It reads; it never writes, creates, deletes or chmods anything,
never follows symlinks, and never surfaces raw SQLite error text (refusals
carry fixed codes from codes.py plus fixed, code-independent detail strings).

probe_input(path) -> model.InputInfo
    Lstat + digest only, before any sqlite call. Refusals are raised in this
    order, each as model.RefusalError with a codes.py constant:
    1. path does not resolve (missing path or non-directory component)
       -> codes.INPUT_MISSING
    2. path itself is a symlink -> codes.INPUT_SYMLINK (never followed)
    3. not S_ISREG (directory, fifo, device, ...) -> codes.INPUT_NOT_REGULAR
    4. size < 32 bytes, or first 16 bytes != b"SQLite format 3\x00"
       -> codes.INPUT_NOT_SQLITE (size checked from the lstat, magic from the
       file content; this check precedes the sidecar check)
    5. a sibling "<input>-wal" / "<input>-shm" / "<input>-journal" exists
       (lstat, symlinks not followed) -> codes.INPUT_SIDECAR_PRESENT with
       detail = comma-joined suffixes only, e.g. "-wal,-shm" (never full paths)
    InputInfo carries path (as given), basename, size_bytes (from the lstat)
    and sha256_16 (first 16 hex chars of the file's SHA-256, read in chunks).
    The content read opens the file with O_NOFOLLOW where the OS supports it
    and re-checks S_ISREG on the opened fd, so a file swapped for a symlink
    mid-probe is refused as INPUT_SYMLINK / INPUT_NOT_REGULAR, not read.

class BudgetHandle(budget)
    Public attrs steps_used, cancelled, deadline_hit; constructor records the
    deadline (time.monotonic() + budget.max_seconds) once, at creation.
    handler() is suitable for sqlite3.Connection.set_progress_handler(h, n):
    it counts one step per invocation, returns 0 normally, returns 1 (abort)
    and sets cancelled once steps_used >= budget.max_steps, or returns 1 and
    sets deadline_hit once time.monotonic() exceeds the deadline. It never
    raises; callers translate the resulting sqlite3.InterruptedError /
    "interrupted" OperationalError into limited status.

open_read_only(path, budget) -> (sqlite3.Connection, model.InputInfo, BudgetHandle)
    Calls probe_input first (refusals happen before any sqlite call), then
    opens via URI "file:" + urllib.parse.quote(os.path.abspath(path),
    safe="/") + "?mode=ro" with uri=True and isolation_level=None — never a
    plain-path open, so SQLite cannot create the file. Immediately executes
    PRAGMA query_only=ON (and drains its cursor), then installs the progress
    handler from a fresh BudgetHandle (one per open; the deadline starts at
    handle creation). On sqlite3.Error at open: "file is not a database"
    maps to codes.INPUT_NOT_SQLITE, every other sqlite3.Error (unable to
    open database file, attempt to write a readonly database, ...) maps to
    codes.INPUT_NOT_REGULAR — detail is a fixed string, exception text is
    never surfaced, and a partially opened connection is closed.

bounded_fetch(cursor, budget) -> (rows, truncated)
    cursor.fetchmany(256) in a loop. Reaching budget.max_rows stops the scan
    and returns (rows[:max_rows], True); an exhausted cursor returns
    (all rows, False). Reaching the cap always reports truncated=True, even
    if the last chunk happened to end exactly at the cap — the reader never
    claims completeness at the cap. sqlite3 errors from the cursor (including
    the progress-handler abort, OperationalError mentioning "interrupted")
    propagate to the caller, which translates them into limited status.

Deterministic and quiet: stdlib only, fixed check order, no prints, no
logging, no environment or locale dependence. Do not edit model.py /
codes.py; their types and codes are the frozen contract.
"""
from __future__ import annotations

import errno
import hashlib
import os
import sqlite3
import stat
import time
import urllib.parse

import codes
import model

_SQLITE_MAGIC = b"SQLite format 3\x00"
_MIN_SQLITE_BYTES = 32
_SIDECAR_SUFFIXES = ("-wal", "-shm", "-journal")
_PROGRESS_OPCODES = 256   # VM opcodes between progress-handler invocations
_FETCH_CHUNK = 256        # rows per fetchmany call
_READ_CHUNK = 1 << 20     # bytes per read while digesting (1 MiB)

_OPEN_FAILURE_DETAIL = "sqlite could not open the file read-only"
_OPEN_FORMAT_DETAIL = "sqlite rejected the file format"


def _existing_sidecar_suffixes(p: str) -> list:
    """Suffixes of <p>-wal / <p>-shm / <p>-journal that lstat resolves to.

    Any lstat failure is treated as absent: the sidecar probe never follows
    symlinks and never escalates a stat error into a different refusal.
    """
    found = []
    for suffix in _SIDECAR_SUFFIXES:
        try:
            os.lstat(p + suffix)
        except OSError:
            continue
        found.append(suffix)
    return found


def _digest_regular_file(p: str) -> str:
    """Read the file via a no-follow fd: verify regular + magic, return sha256 hex prefix.

    Keeps the NOT_SQLITE-before-SIDECAR refusal order: the magic is checked
    before sidecar siblings are consulted, so a malformed file with sidecars
    refuses as INPUT_NOT_SQLITE.
    """
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(p, os.O_RDONLY | nofollow)
    except FileNotFoundError:
        raise model.RefusalError(codes.INPUT_MISSING) from None
    except NotADirectoryError:
        raise model.RefusalError(codes.INPUT_MISSING) from None
    except OSError as exc:
        if nofollow and exc.errno == errno.ELOOP:
            raise model.RefusalError(codes.INPUT_SYMLINK) from None
        raise
    hasher = hashlib.sha256()
    with os.fdopen(fd, "rb", closefd=True) as f:
        first = f.read(_READ_CHUNK)
        if first[:16] != _SQLITE_MAGIC:
            raise model.RefusalError(codes.INPUT_NOT_SQLITE)
        if _existing_sidecar_suffixes(p):
            raise model.RefusalError(
                codes.INPUT_SIDECAR_PRESENT, ",".join(_existing_sidecar_suffixes(p))
            )
        hasher.update(first)
        for chunk in iter(lambda: f.read(_READ_CHUNK), b""):
            hasher.update(chunk)
    return hasher.hexdigest()[:16]


def probe_input(path) -> model.InputInfo:
    """Stat + digest the input without creating anything; refuse bad inputs."""
    p = os.fspath(path)
    try:
        st = os.lstat(p)
    except (FileNotFoundError, NotADirectoryError):
        raise model.RefusalError(codes.INPUT_MISSING) from None
    if stat.S_ISLNK(st.st_mode):
        raise model.RefusalError(codes.INPUT_SYMLINK)
    if not stat.S_ISREG(st.st_mode):
        raise model.RefusalError(codes.INPUT_NOT_REGULAR)
    if st.st_size < _MIN_SQLITE_BYTES:
        raise model.RefusalError(codes.INPUT_NOT_SQLITE)
    sha256_16 = _digest_regular_file(p)
    return model.InputInfo(
        path=p,
        basename=os.path.basename(p),
        size_bytes=st.st_size,
        sha256_16=sha256_16,
    )


class BudgetHandle:
    """Step/deadline budget for one read-only connection."""

    def __init__(self, budget: model.Budget):
        self.budget = budget
        self._deadline = time.monotonic() + budget.max_seconds
        self.steps_used = 0
        self.cancelled = False
        self.deadline_hit = False

    def handler(self) -> int:
        """Progress handler: 0 to continue, 1 to abort the running statement."""
        self.steps_used += 1
        if self.steps_used >= self.budget.max_steps:
            self.cancelled = True
            return 1
        if time.monotonic() > self._deadline:
            self.deadline_hit = True
            return 1
        return 0


def open_read_only(path, budget: model.Budget):
    """Probe, then open the file strictly read-only with a fresh budget handle."""
    info = probe_input(path)  # refuses before any sqlite call
    p = os.fspath(path)
    uri = "file:" + urllib.parse.quote(os.path.abspath(p), safe="/") + "?mode=ro"
    con = None
    try:
        con = sqlite3.connect(uri, uri=True, isolation_level=None)
        con.execute("PRAGMA query_only=ON").fetchone()
    except sqlite3.Error as exc:
        if con is not None:
            try:
                con.close()
            except sqlite3.Error:
                pass
        if "file is not a database" in str(exc):
            raise model.RefusalError(codes.INPUT_NOT_SQLITE, _OPEN_FORMAT_DETAIL) from None
        raise model.RefusalError(codes.INPUT_NOT_REGULAR, _OPEN_FAILURE_DETAIL) from None
    handle = BudgetHandle(budget)
    con.set_progress_handler(handle.handler, _PROGRESS_OPCODES)
    return con, info, handle


def bounded_fetch(cursor, budget: model.Budget):
    """Fetch up to budget.max_rows rows; report truncation instead of over-reading."""
    rows = []
    while True:
        chunk = cursor.fetchmany(_FETCH_CHUNK)
        if not chunk:
            return rows, False
        rows.extend(chunk)
        if len(rows) >= budget.max_rows:
            return rows[: budget.max_rows], True
